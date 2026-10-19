// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Observation
import ServiceManagement
import MacHopCore

/// Owns every component and decides when input may go to the phone.
@Observable
final class AppModel {
    enum Status: Equatable {
        case needsAccessibility
        case bluetoothOff
        case bluetoothDenied
        case bluetoothUnavailable(String)
        case choosePhone
        case connecting
        case waitingForPhone
        /// Linked and subscribed, but the iPhone has paused input: its screen is off.
        case phoneAsleep
        case ready
        case controlling
        case paused
        case blocked(String)
    }

    private(set) var settings: AppSettings
    private(set) var owner: Owner = .mac
    private(set) var phoneReady = false
    private(set) var accessibilityGranted = EventTap.accessibilityGranted
    private(set) var bluetooth: HIDPeripheral.State = .starting
    private(set) var link: PhoneConnector.LinkState = .off
    private(set) var nearby: [NearbyDevice] = []
    private(set) var isSearching = false
    private(set) var displays: [Display] = SystemMonitor.displays()
    private(set) var notice: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var subscriptions = 0
    private(set) var stats = HIDTransport.Stats()
    /// The latest gesture sent to the phone, for the setup guide.
    private(set) var lastPhoneAction: (action: InputSession.PhoneAction, time: Double)?

    @ObservationIgnored private let scheduler = MainScheduler()
    @ObservationIgnored private(set) var transport: HIDTransport
    @ObservationIgnored private var peripheral: HIDPeripheral
    @ObservationIgnored private(set) var session: InputSession
    @ObservationIgnored let connector = PhoneConnector()
    @ObservationIgnored private let tap = EventTap()
    @ObservationIgnored let cursor = SystemCursor()
    @ObservationIgnored private let monitor = SystemMonitor()
    @ObservationIgnored private var linkCheckPending = false
    @ObservationIgnored private var linkAttempts = 0
    @ObservationIgnored private var noticeToken = 0
    @ObservationIgnored private var pollingAccessibility = false
    @ObservationIgnored private var ownershipPeriod = 0
    @ObservationIgnored private var traceUntil = 0.0
    @ObservationIgnored private var stopping = false
    /// `--dry-run --demo`: show a connected iPhone for screenshots (no Bluetooth or capture runs).
    @ObservationIgnored private(set) var demo = false
    /// `--dry-run`: run the app shell without Bluetooth or input capture (launch checks).
    @ObservationIgnored let dryRun = CommandLine.arguments.contains("--dry-run")

    init() {
        let displays = SystemMonitor.displays()
        let settings = AppSettings.load(mainDisplay: displays.first?.id ?? CGMainDisplayID(), displays: displays)
        self.settings = settings
        let transport = HIDTransport(profile: HIDProfile(settings.profile), scheduler: scheduler)
        self.transport = transport
        peripheral = HIDPeripheral(transport: transport)
        let scheduler = self.scheduler
        session = InputSession(settings: settings.session, displays: SystemMonitor.displays(), link: transport,
                               cursor: cursor, clock: { scheduler.now })
        wireStack()
    }

    // MARK: Lifecycle

    func start() {
        // Dry runs share the real app's saved settings, so they never write them.
        if !dryRun { settings.save() }
        monitor.onChange = { [weak self] in
            self?.syncBluetoothSleep()
            self?.refresh()
        }
        monitor.onDisplaysChanged = { [weak self] in self?.displaysChanged() }
        monitor.onFrontChange = { [weak self] in
            if self?.owner == .phone { self?.cursor.reassertHidden() }
        }
        monitor.start()
        tap.decide = { [weak self] event in
            guard let self else { return .pass }
            let ownerBefore = self.session.owner
            let disposition = self.session.handle(event)
            // For a moment after each crossing, record exactly what macOS reported
            // (positions and movement only; never keys). Diagnoses edge behaviour.
            if case let .pointerMoved(location, delta) = event, ProcessInfo.processInfo.systemUptime < self.traceUntil {
                Log.input.notice("""
                    trace \(ownerBefore == .phone ? "phone" : "mac", privacy: .public)                     at (\(Int(location.x)), \(Int(location.y))) delta (\(delta.x, format: .fixed(precision: 1)),                     \(delta.y, format: .fixed(precision: 1))) → \(self.session.owner == .phone ? "phone" : "mac", privacy: .public)
                    """)
            }
            return disposition
        }
        tap.visibleModifiers = { [weak self] flags in
            guard let self, self.session.hidesModifiers else { return flags }
            return self.session.macVisibleModifiers(flags)
        }
        tap.onInterrupted = { [weak self] reason, revived in self?.captureInterrupted(reason, revived: revived) }
        connector.onChange = { [weak self] in self?.connectorChanged() }
        connector.phoneID = settings.phoneID
        if !dryRun {
            connector.start()
            peripheral.start()
        }
        refresh()
        Log.app.notice("MacHop started\(self.dryRun ? " (dry run: no Bluetooth or input capture)" : "", privacy: .public)")
    }

    func stop() {
        // Shutting down: nothing may restart capture (the peripheral stopping triggers a refresh).
        stopping = true
        session.returnToMac(.requested)
        tap.stop()
        peripheral.stop()
    }

    private func wireStack() {
        peripheral.allowedCentral = settings.phoneID
        peripheral.onStateChange = { [weak self] in self?.peripheralChanged() }
        peripheral.onServicesPublished = { [weak self] in self?.connector.servicesReady = true }
        peripheral.onCentralSubscribed = { [weak self] id in self?.phoneSubscribed(id) }
        transport.onReadyChange = { [weak self] ready in
            Log.bluetooth.notice("iPhone input \(ready ? "ready" : "not ready", privacy: .public)")
            self?.refresh()
        }
        transport.onStall = { [weak self] in self?.transportStalled() }
        session.onOwnerChange = { [weak self] owner, reason in self?.ownerChanged(owner, reason: reason) }
        let scheduler = self.scheduler
        session.schedule = { delay, action in scheduler.after(delay, action) }
        session.onPhoneAction = { [weak self] action in
            let sent = action == .home ? "Menu key" : "button \(action.rawValue)"
            Log.input.notice("iPhone gesture: \(String(describing: action), privacy: .public) (\(sent, privacy: .public))")
            self?.lastPhoneAction = (action, ProcessInfo.processInfo.systemUptime)
        }
        session.entryGuard = {
            if SystemMonitor.secureInputActive { return "A password field on your Mac is using Secure Input." }
            if SystemMonitor.missionControlShowing { return "Close Mission Control to move onto your iPhone." }
            return nil
        }
        session.onEntryRefused = { [weak self] reason in self?.show(notice: reason) }
        session.onWakePhone = { [weak self] in
            if self?.transport.wake() == true { Log.bluetooth.notice("Waking the iPhone") }
        }
        session.onJumpUnavailable = { [weak self] in
            guard let self else { return }
            NSSound.beep()
            switch status {
            case .phoneAsleep: show(notice: "\(phoneName) is asleep. Wake it to move onto it.")
            case .blocked(let reason): show(notice: reason)
            default: show(notice: "\(phoneName) isn't connected yet.")
            }
        }
        if AutomationServer.isEnabled {
            // Lab only: scroll amounts and the wheel steps sent, to study how scrolling feels.
            session.onScrollTrace = { input, report in
                Log.input.info("scroll dy \(input.dy, format: .fixed(precision: 1)) phase \(String(describing: input.phase), privacy: .public) momentum \(String(describing: input.momentum), privacy: .public) → wheel \(report.wheel)")
            }
            session.onPhoneTrace = { Log.input.info("phone: \($0, privacy: .public)") }
        }
    }

    // MARK: Sleep

    /// Whether Bluetooth has let go of the iPhone because the Mac is asleep.
    private var bluetoothAsleep = false

    /// While the Mac sleeps, MacHop lets go of the iPhone completely: the link drops and
    /// the keyboard-and-pointer service is withdrawn. Otherwise the Mac's background wakes
    /// (Power Nap and the like) reconnect it about once a minute, each time showing the
    /// iPhone's pointer, and the reconnecting itself keeps waking the Mac. A real wake
    /// (macOS never reports the background ones) brings both back. Closing the lid with
    /// an external display attached doesn't sleep the Mac, so it changes nothing.
    private func syncBluetoothSleep() {
        guard !dryRun, !stopping, monitor.asleep != bluetoothAsleep else { return }
        bluetoothAsleep = monitor.asleep
        if bluetoothAsleep {
            Log.bluetooth.notice("Mac going to sleep: letting go of the iPhone")
            session.returnToMac(.unavailable("Your Mac is going to sleep"))
            connector.suspended = true
            peripheral.stop()
            connector.servicesReady = false
        } else {
            Log.bluetooth.notice("Mac awake: connecting to the iPhone again")
            connector.suspended = false
            peripheral.start()
        }
    }

    /// For testing through automation: sleep or wake as the system notices would.
    func simulateSleep(_ asleep: Bool) { monitor.simulate(asleep: asleep) }

    // MARK: Availability

    /// Recomputes everything derived from component state and tells the session
    /// whether the phone may take input.
    func refresh() {
        guard !stopping, !demo else { return }
        accessibilityGranted = EventTap.accessibilityGranted
        if accessibilityGranted && !settings.paused && !dryRun {
            if !tap.isRunning, tap.start() {
                let held = EventTap.physicallyHeld()
                session.reconcile(keysDown: held.keys, buttonsDown: held.buttons)
            }
        } else {
            tap.stop()
        }
        if !accessibilityGranted { pollForAccessibility() }
        phoneReady = transport.isReady
        subscriptions = transport.subscribedReports.count
        stats = transport.stats
        let blocker: String? =
            settings.paused ? "Paused" :
            !accessibilityGranted ? "MacHop needs Accessibility permission" :
            !tap.isRunning ? "Input capture is unavailable" :
            monitor.blockingReason
        let arrangement: String? = session.screenLink == nil ? "Check the arrangement" : nil
        let reason = blocker ?? (transport.isReady ? nil : "iPhone is not connected") ?? arrangement
        // Waking is only offered when the iPhone being asleep is all that's in the way.
        session.mayWakePhone = settings.wakesPhone == true && transport.isSuspended && blocker == nil && arrangement == nil
        session.setEnabled(reason == nil, reason: reason ?? "")
        if transport.isReady { linkAttempts = 0 }
        watchLink()
    }

    var status: Status {
        if owner == .phone { return .controlling }
        if settings.paused { return .paused }
        if !accessibilityGranted { return .needsAccessibility }
        switch bluetooth {
        case .off: return .bluetoothOff
        case .unauthorized: return .bluetoothDenied
        case .unsupported: return .bluetoothUnavailable("This Mac cannot act as a Bluetooth keyboard.")
        case .failed(let message): return .bluetoothUnavailable(message)
        default: break
        }
        if settings.phoneID == nil && !phoneReady { return .choosePhone }
        if let reason = monitor.blockingReason { return .blocked(reason) }
        if phoneReady { return session.screenLink == nil ? .blocked("Check the arrangement in Settings.") : .ready }
        if link == .connected && transport.isSuspended { return .phoneAsleep }
        return link == .connected ? .waitingForPhone : .connecting
    }

    var phoneName: String { settings.phoneName ?? "iPhone" }

    // MARK: Events from components

    private func ownerChanged(_ owner: Owner, reason: ReturnReason?) {
        self.owner = owner
        traceUntil = ProcessInfo.processInfo.systemUptime + 0.4
        tap.traceGestures = owner == .phone && AutomationServer.isEnabled
        if owner == .phone {
            if settings.hasCrossed != true { update { $0.hasCrossed = true } }
            watchWhilePhoneOwnsInput()
            // A Space switch that was still animating when you crossed can show the
            // cursor again just after: hide it once more.
            let period = ownershipPeriod
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.owner == .phone, self.ownershipPeriod == period else { return }
                    self.cursor.reassertHidden()
                }
            }
        } else {
            // Anything still physically held on return stays swallowed until released.
            let held = EventTap.physicallyHeld()
            session.reconcile(keysDown: held.keys, buttonsDown: held.buttons)
            if case .unavailable(let message)? = reason, !message.isEmpty, message != "Paused" {
                show(notice: "Input returned to your Mac: \(message).")
            }
        }
        let why: String = switch reason {
        case nil: ""
        case .edge?: " (edge)"
        case .shortcut?: " (shortcut)"
        case .requested?: " (requested)"
        case .reconfigured?: " (settings changed)"
        case .unavailable(let message)?: " (\(message))"
        }
        Log.input.notice("Input now with \(owner == .phone ? "iPhone" : "Mac", privacy: .public)\(why, privacy: .public)")
    }

    private func peripheralChanged() {
        bluetooth = peripheral.state
        if !peripheral.servicesPublished { connector.servicesReady = false }
        refresh()
    }

    private func connectorChanged() {
        link = connector.linkState
        nearby = connector.nearby
        isSearching = connector.isSearching
        if link == .notFound { show(notice: "Your Mac no longer recognises \(phoneName). Choose it again in Settings.") }
        // The iPhone says which model it is: size it to match, unless a size was chosen by hand.
        if let model = connector.modelIdentifier, model != settings.phoneModel {
            update { saved in
                saved.phoneModel = model
                if (saved.screen ?? .automatic) == .automatic {
                    saved.session.layout = saved.session.layout.sized(for: Self.screenPoints(.automatic, model: model))
                }
            }
        }
        // A phone chosen from its own Bluetooth settings has no saved name.
        if settings.phoneName == nil || settings.phoneName == "iPhone",
           let name = connector.linkedName, !name.isEmpty, name != settings.phoneName {
            update { $0.phoneName = name }
        }
        refresh()
    }

    private func phoneSubscribed(_ id: UUID) {
        guard settings.phoneID == nil else { return }
        // The phone connected from its own Bluetooth settings: remember it.
        update { $0.phoneID = id }
    }

    /// Events during a tap outage went straight to macOS: hand input back to the Mac
    /// and repair key/button ownership from the physical state, so a release the
    /// session never saw cannot leave a key held on the phone.
    private func captureInterrupted(_ reason: String, revived: Bool = false) {
        session.returnToMac(.unavailable(reason))
        let held = EventTap.physicallyHeld()
        session.reconcile(keysDown: held.keys, buttonsDown: held.buttons)
        guard !revived else { return }
        tap.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let held = EventTap.physicallyHeld()
                self.session.reconcile(keysDown: held.keys, buttonsDown: held.buttons)
                self.refresh()
            }
        }
    }

    private func transportStalled() {
        Log.bluetooth.notice("Bluetooth stopped accepting input; reconnecting")
        session.returnToMac(.unavailable("Bluetooth stopped responding"))
        connector.reconnect()
        refresh()
    }

    private func displaysChanged() {
        displays = SystemMonitor.displays()
        session.configure(settings: settings.session, displays: displays)
        refresh()
    }

    /// If the link is up but the phone never subscribes, restart the link a few
    /// times, then tell the user. One check at a time, so reconnects can't keep
    /// postponing it.
    private func watchLink() {
        // A locked iPhone pauses input on purpose; reconnecting would only wake it up
        // every few seconds. The watchdog is for links that never start accepting input.
        guard !linkCheckPending, link == .connected, !transport.isReady, !transport.isSuspended else { return }
        linkCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.linkCheckPending = false
                guard !self.transport.isSuspended else { return }
                guard !self.transport.isReady, self.settings.phoneID != nil, !self.dryRun else { return }
                self.linkAttempts += 1
                if self.linkAttempts <= 3 {
                    self.connector.reconnect()
                } else if self.linkAttempts == 4 {
                    self.show(notice: "\(self.phoneName) is in range but has not accepted MacHop as a keyboard. " +
                              "Check that Bluetooth and AssistiveTouch are on, then try Reconnect.")
                }
                self.watchLink()
            }
        }
    }

    /// While the phone has input, Secure Input or a dead tap must hand input back quickly.
    /// One check chain per ownership period: a newer period supersedes older chains.
    private func watchWhilePhoneOwnsInput(period: Int? = nil) {
        if period == nil { ownershipPeriod += 1 }
        let current = period ?? ownershipPeriod
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.owner == .phone, self.ownershipPeriod == current else { return }
                if SystemMonitor.secureInputActive {
                    self.session.returnToMac(.unavailable("Secure Input became active on your Mac"))
                } else if !self.tap.isHealthy {
                    self.captureInterrupted("Input capture stopped")
                } else {
                    self.watchWhilePhoneOwnsInput(period: current)
                }
            }
        }
    }

    /// Polls only while permission is missing; one chain at a time.
    private func pollForAccessibility() {
        guard !pollingAccessibility else { return }
        pollingAccessibility = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pollingAccessibility = false
                if EventTap.accessibilityGranted { self.refresh() } else { self.pollForAccessibility() }
            }
        }
    }

    func show(notice message: String) {
        notice = message
        noticeToken += 1
        let token = noticeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noticeToken == token else { return }
                self.notice = nil
            }
        }
    }

    // MARK: User actions

    func update(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        next.session = next.session.sanitized()
        guard next != settings else { return }
        let previous = settings
        settings = next
        if !dryRun { settings.save() }
        if next.profile != previous.profile { rebuildStack() }
        if next.session != previous.session { session.configure(settings: next.session, displays: displays) }
        if next.phoneID != previous.phoneID {
            peripheral.allowedCentral = next.phoneID
            connector.phoneID = next.phoneID
        }
        refresh()
    }

    func togglePause() { update { $0.paused.toggle() } }

    /// Dry runs only: a connected iPhone 15 Pro, for screenshots. Nothing is saved.
    func enterDemoMode() {
        guard dryRun else { return }
        demo = true
        accessibilityGranted = true
        bluetooth = .connected(subscriptions: 5)
        link = .connected
        phoneReady = true
        settings.phoneID = UUID()
        settings.phoneName = "iPhone"
        settings.phoneModel = "iPhone16,1"
        settings.hasCrossed = true
        settings.paused = false
        settings.gestureSetup = nil
        // The standard arrangement, so screenshots don't depend on this Mac's settings:
        // portrait on the right, or with `--demo-top`, landscape above the screen.
        let top = CommandLine.arguments.contains("--demo-top")
        settings.session.layout.side = top ? .top : .right
        settings.session.layout.edgePosition = top ? 0.7 : 0.5
        settings.session.layout.orientation = top ? .landscape : .portrait
        settings.session.layout.flipped = false
    }

    /// Chooses the iPhone's screen (or automatic, from the model it reports) and sizes the layout to it.
    func setScreen(_ choice: IPhoneScreen) {
        update { saved in
            saved.screen = choice
            saved.session.layout = saved.session.layout.sized(for: Self.screenPoints(choice, model: saved.phoneModel))
        }
    }

    /// The detected model's name, e.g. "iPhone 15 Pro", once the iPhone has reported it.
    var detectedModelName: String? {
        settings.phoneModel.map { IPhoneModels.model(for: $0)?.name ?? $0 }
    }

    static func screenPoints(_ choice: IPhoneScreen, model: String?) -> (width: Double, height: Double) {
        if choice == .automatic, let model, let known = IPhoneModels.model(for: model) { return (known.width, known.height) }
        return choice.points
    }

    func returnToMac() { session.returnToMac(.requested) }

    /// The menu's Move to iPhone: what ⌃⌥⌘I does.
    func jumpToPhone() { session.jumpOrWake() }

    func choose(_ device: NearbyDevice) {
        connector.stopSearch()
        update {
            $0.phoneID = device.id
            $0.phoneName = device.name
        }
    }

    func searchForPhones() { connector.startSearch() }

    func stopSearching() { connector.stopSearch() }

    func reconnect() {
        linkAttempts = 0
        connector.reconnect()
    }

    func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        pollForAccessibility()
    }

    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show(notice: "Could not change the login item: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Switches the HID report layout. The phone re-reads the services; no new pairing is needed.
    private func rebuildStack() {
        session.returnToMac(.reconfigured)
        peripheral.stop()
        connector.servicesReady = false
        transport = HIDTransport(profile: HIDProfile(settings.profile), scheduler: scheduler)
        peripheral = HIDPeripheral(transport: transport)
        let scheduler = self.scheduler
        session = InputSession(settings: settings.session, displays: displays, link: transport,
                               cursor: cursor, clock: { scheduler.now })
        wireStack()
        peripheral.start()
        Log.bluetooth.notice("HID profile changed to \(self.settings.profile.rawValue, privacy: .public)")
    }
}
