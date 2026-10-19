# MacHop licence and third-party notices

MacHop is distributed under the **GNU Affero General Public License, version 3 only (AGPL-3.0-only)**. See `LICENSE`.

## BT Remote — incorporated (AGPL-3.0-only)

Source: <https://github.com/jqssun/darwin-bt-remote>, author jqssun, inspected revision `ad7a76ce6132254fbd6085af87cea8d10aa8a82d`. Licence: AGPL-3.0-only.

MacHop incorporates:

- the keyboard, battery, system-control and consumer-control collections of the HID report map, byte for byte, in the `compatibility` profile (`Sources/MacHopCore/HIDProfile.swift`);
- the HID-over-GATT service layout — service and characteristic order, properties and encryption, and publishing the reserved HID service under its expanded 128-bit UUID (`Sources/MacHopApp/Bluetooth/HIDPeripheral.swift`).

All other MacHop source was written for this project. Because the incorporated material is AGPL-3.0-only, the combined work is AGPL-3.0-only: preserve these notices and provide the complete corresponding source to anyone you convey the app to (or let interact with it over a network, as the licence requires).
