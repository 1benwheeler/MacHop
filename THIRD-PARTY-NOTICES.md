# MacHop licence and third-party notices

MacHop is distributed under the **GNU Affero General Public License, version 3 only (AGPL-3.0-only)**. See `LICENSE`.

## BT Remote — incorporated (AGPL-3.0-only)

Source: <https://github.com/jqssun/darwin-bt-remote>, author jqssun, inspected revision `ad7a76ce6132254fbd6085af87cea8d10aa8a82d`. Licence: AGPL-3.0-only (a separate commercial licence is offered by the author; none has been obtained).

MacHop incorporates:

- the keyboard, battery, system-control and consumer-control collections of the HID report map, byte for byte, in the `compatibility` profile (`Sources/MacHopCore/HIDProfile.swift`);
- the HID-over-GATT service layout — service and characteristic order, properties and encryption, and publishing the reserved HID service under its expanded 128-bit UUID (`Sources/MacHopApp/Bluetooth/HIDPeripheral.swift`).

All other MacHop source was written for this project. Because the incorporated material is AGPL-3.0-only, the combined work is AGPL-3.0-only: preserve these notices and provide the complete corresponding source to anyone you convey the app to (or let interact with it over a network, as the licence requires).

## Studied, not incorporated

- **btkb** (<https://github.com/jasonjmcghee/btkb>, MIT): its edge-routing approach was studied during MacHop's development. No btkb code is in MacHop, and MacHop does not use its private virtual-display API.
- **Barrier / Deskflow**: the technique of setting the WindowServer property `SetsCursorInBackground` so a background app can hide the cursor is widely documented in these projects. MacHop's implementation (`SystemCursor.swift`) is independent.

## Platform

Swift, AppKit, SwiftUI, CoreBluetooth, CoreGraphics, Carbon, ServiceManagement, AVFoundation and CoreMediaIO are Apple platform components, supplied by macOS and not bundled.
