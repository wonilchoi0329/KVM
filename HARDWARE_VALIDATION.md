# Hardware validation

Last updated: 2026-07-15.

The current implementation has been exercised on two Apple-Silicon MacBook Pro generations connected to the same supported LG display through direct HDMI paths. Personal display serials, UUIDs, and IOKit registry IDs are intentionally omitted.

## Proven behavior

- Pebble K380s product `0xB377` and MX Master 4 product `0xB042` were found over direct Bluetooth Low Energy.
- Each device's HID++ `CHANGE_HOST (0x1814)` feature index was resolved at runtime.
- F1 moved keyboard, mouse, and display to destination 1.
- F2 moved keyboard, mouse, and display to destination 2 after applying the M1 Pro HDMI bridge address discovered through a bounded clean-room trace.
- The LG path used alternate VCP `0xF4`, values `0x90`/`0x91`, with full EDID identity checks before each write.
- The monitor path is disabled when no supported display is enrolled.

## Still required before claiming broader compatibility

- Twenty or more round trips on each supported Mac.
- Sleep/wake, reboot, mouse deep sleep, Logi Options+ activity, Bluetooth reconnect, and HDMI reconnect.
- Additional macOS releases and Apple-Silicon generations.
- Measurements of idle RSS, CPU, and wakeups from a release build.

Until those checks are recorded, the README's narrow supported scope is authoritative.
