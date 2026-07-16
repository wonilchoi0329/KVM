# Privacy

HostHop has no analytics, telemetry, crash uploader, updater, network client, server, or subprocess integration. Runtime activity remains on the Mac and failures go to Apple's local unified log under subsystem `com.wonil.hosthop`.

Guided setup reads Logitech HID identity, HID++ device type/host count, and the supported external display's EDID. It stores exact vendor/product identity, product names, transport, optional HID serials, the display manufacturer/product/serial, timing preferences, and the display chip address in `~/Library/Application Support/HostHop/config.plist`. The file is user-only (`0600`) inside a user-only directory (`0700`).

Normal diagnostics redact HID serials, display serials, and registry IDs. Verbose diagnostics reveal identifiers for local troubleshooting; users should redact verbose output before sharing it.

HostHop does not read typed key content. It registers global F1/F2 hotkeys and processes only bounded HID++ reports from exact enrolled device interfaces.

Uninstall instructions in the README remove the app, login item, and stored configuration.
