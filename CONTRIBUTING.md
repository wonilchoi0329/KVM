# Contributing

Contributions should preserve HostHop's narrow scope: dependency-free, headless, event-driven, arm64, no network or updater, exact enrolled HID identities, and the fixed supported LG alternate command only. Generic raw HID/DDC interfaces, shell execution, private identifiers, and bundled binaries are out of scope.

Before opening a pull request:

1. Read `SECURITY.md` and report vulnerabilities privately.
2. Do not commit device serials, display UUIDs, registry paths, usernames, local paths, configuration files, app bundles, archives, or traces.
3. Add tests for behavior and bounds changes.
4. Run `./Scripts/verify.sh` on Apple Silicon.
5. Update the supported-scope and hardware-validation documents only for behavior actually tested on hardware.

Pull requests should explain the security/privacy impact and identify any undocumented macOS API newly used. CI intentionally uploads no build artifacts.
