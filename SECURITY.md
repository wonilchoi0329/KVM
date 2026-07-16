# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's **Security → Report a vulnerability** private reporting flow. Include the affected commit, macOS/hardware context, reproduction steps, impact, and whether reproduction requires Input Monitoring.

Please redact configuration files, HID serial numbers, display serial numbers, display UUIDs, registry paths, usernames, and home-directory paths. `HostHop diagnose --verbose` intentionally contains some of these identifiers.

No response-time or embargo guarantee is offered. A report will be acknowledged when capacity permits; coordinated disclosure is preferred.

## Security model

HostHop runs as the logged-in user and requires Input Monitoring to observe global F1/F2 and Logitech HID reports. It does not request Accessibility, Bluetooth privacy access, root, a privileged helper, incoming network access, or an app-sandbox exception. The app itself is not sandboxed because direct IOHID and the display transport are outside the supported sandbox design.

The primary trust boundary is local: another process running as the same user may be able to influence HID availability or files in the user's home directory. HostHop narrows that boundary with exact enrolled device IDs, optional serial matching, HID++ device-type verification, bounded report sizes/rates, a cross-process switch lock, secure configuration I/O, exact EDID matching, and a fixed DDC command set.

The LG transport dynamically resolves undocumented macOS display functions. Missing functions, invalid EDID headers/checksums, identity mismatches, unknown chip addresses, and unrecognized configuration values all fail closed.

## Supported builds

Security fixes target the latest source on the default branch. This repository publishes source only. Locally built ad-hoc apps use Hardened Runtime with explicit Library Validation; no binary is represented as Developer ID signed or notarized.
