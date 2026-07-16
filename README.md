# HostHop

HostHop is a small, headless macOS software KVM for one specific hardware family: a Logitech Pebble K380s keyboard, Logitech MX Master 4 mouse, and an optional LG display that accepts the tested LG alternate input command. Press F1 for destination 1 or F2 for destination 2; the connected Mac sends Logitech HID++ `CHANGE_HOST` commands and, when enrolled, the LG input command concurrently.

This repository distributes source only. It does not publish or endorse unsigned downloadable app bundles. Review the source and build it locally.

## Supported scope

- Apple-Silicon Macs running macOS 13 or later.
- Direct Bluetooth Low Energy connections to Logitech vendor `0x046D`, Pebble K380s product `0xB377`, and MX Master 4 product `0xB042`.
- HID++ feature `0x1814`, resolved dynamically per interface. Feature indices are never hardcoded.
- Destinations 1 and 2. Destination 3 is intentionally ignored.
- Optional LG manufacturer `0x1E6D`, product `0x774F`, using only alternate VCP `0xF4` values `0x90`/`0x91` over the enrolled display's validated EDID route.

Other Logitech models, Intel Macs, USB receivers, generic DDC monitors, docks, and adapters are not claimed to work. The display transport uses undocumented macOS APIs and may break in a future macOS version. It validates the complete base EDID block and exact enrolled identity before every write, and it exposes no generic DDC-write command.

The app is event-driven: no Dock icon, menu-bar item, polling, updater, network listener, subprocess, SSH route, BetterDisplay dependency, or bundled helper.

## Before installation

You need two Apple-Silicon Macs, Xcode Command Line Tools, and direct Bluetooth—not a Logitech receiver.

1. Pair the Pebble keyboard's Easy-Switch slot 1 and the MX mouse's host slot 1 with Mac 1.
2. Pair slot 2 on both devices with Mac 2.
3. If using monitor switching, connect Mac 1 to the supported LG's HDMI 1 and Mac 2 to HDMI 2. Keep both cables connected.
4. Press Fn+Esc once on the Pebble so the top row sends standard F1–F12 keys. F1 and F2 become HostHop's destination keys while the agent runs.

The keyboard and mouse must be connected to the Mac being configured so HostHop can inspect their HID++ interfaces.

## Install Mac 1 step by step

Open Terminal on Mac 1 and install Apple's build tools if they are not already present:

```sh
xcode-select --install
```

Clone, verify, and build HostHop from source:

```sh
git clone https://github.com/wonilchoi0329/KVM.git
cd KVM
./Scripts/verify.sh
```

`verify.sh` runs the tests and security checks, then creates the ignored local build at `dist/HostHop.app`. It does not download dependencies.

If an older HostHop is installed, stop its login item and process before replacing it:

```sh
/Applications/HostHop.app/Contents/MacOS/HostHop login-item disable 2>/dev/null || true
pkill -x HostHop 2>/dev/null || true
```

Install the locally built app:

```sh
sudo ditto dist/HostHop.app /Applications/HostHop.app
```

Run guided enrollment:

```sh
/Applications/HostHop.app/Contents/MacOS/HostHop configure
```

On the first attempt, macOS may ask for Input Monitoring. If setup says permission is required:

1. Open System Settings → Privacy & Security → Input Monitoring.
2. Enable HostHop. Authenticate if macOS asks.
3. Return to Terminal and run the `configure` command again.
4. Confirm the discovered Pebble and MX devices.
5. If the supported LG is found, answer yes to enroll it.
6. Review the summary and answer yes to save.

Setup only reads device identity and EDID; it does not switch anything. An old version-1 config is preserved as `config.plist.backup` and replaced only after confirmation.

Check the configuration, enable startup, and launch the agent now:

```sh
/Applications/HostHop.app/Contents/MacOS/HostHop diagnose
/Applications/HostHop.app/Contents/MacOS/HostHop login-item enable
open /Applications/HostHop.app
```

Mac 1 is ready. Do not test F2 until Mac 2 is installed, because F2 will move the keyboard and mouse to their second host slot.

## Install Mac 2 step by step

1. Use the devices' Easy-Switch controls to connect both the Pebble and MX mouse to Mac 2 manually.
2. Repeat every Mac 1 installation command on Mac 2: install the build tools, clone this repository, run `./Scripts/verify.sh`, install the app, and run `HostHop configure`.
3. Grant Input Monitoring on Mac 2. Permission is per Mac and per local build.
4. During setup, enroll the same keyboard and mouse while they are connected to Mac 2. Enroll the LG if it is discovered; its I²C route may differ from Mac 1.
5. Run `diagnose`, enable the login item, and open the app using the commands above.

Building independently on each Mac avoids bypassing Gatekeeper for a copied ad-hoc app. Do not download or redistribute an unnotarized `HostHop.app` from another source.

## Verify the complete KVM

Start with the keyboard, mouse, and monitor on Mac 1:

1. Press physical F2. The keyboard and mouse should move to host slot 2 and the LG should move to HDMI 2.
2. Now on Mac 2, press physical F1. All three should return to host slot 1/HDMI 1.
3. Repeat several times, then repeat after sleep/wake.

You can also exercise a destination from Terminal on the currently active Mac:

```sh
/Applications/HostHop.app/Contents/MacOS/HostHop test 1
/Applications/HostHop.app/Contents/MacOS/HostHop test 2
```

If a switch fails, run normal diagnostics on the Mac from which the switch was initiated:

```sh
/Applications/HostHop.app/Contents/MacOS/HostHop diagnose
log show --last 5m --predicate 'subsystem == "com.wonil.hosthop"'
```

Normal diagnostics are suitable for an issue report. `diagnose --verbose` contains hardware identifiers and must be redacted before posting.

Ad-hoc signing is appropriate only for a local source build. Local rebuilds can require granting Input Monitoring again. A future binary distribution must use Developer ID signing and Apple notarization; those are deliberately not represented here.

## Commands

```text
HostHop configure
HostHop diagnose [--verbose]
HostHop test 1|2
HostHop login-item enable|disable
HostHop                         # run the background agent
```

Normal diagnostics redact HID serials, display serials, and IOKit registry IDs. `--verbose` intentionally prints identifiers for local troubleshooting; redact that output before posting it.

Configuration is stored at `~/Library/Application Support/HostHop/config.plist` with mode `0600` in a `0700` directory. HostHop refuses symlinks, non-user-owned files, group/world-writable files, files larger than 64 KiB, unknown schema versions, and incomplete device identities. Version 1 configurations are not migrated; rerun `HostHop configure`. An existing file is preserved as `config.plist.backup` when setup saves a replacement.

## Uninstall

```sh
/Applications/HostHop.app/Contents/MacOS/HostHop login-item disable
pkill -x HostHop || true
sudo rm -rf /Applications/HostHop.app
rm -rf "$HOME/Library/Application Support/HostHop"
```

Also remove HostHop from System Settings → Privacy & Security → Input Monitoring if it remains listed.

## Security and privacy

Read [SECURITY.md](SECURITY.md) before reporting a vulnerability and [PRIVACY.md](PRIVACY.md) for the local data model. Implementation provenance and third-party notices are in [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

HostHop is MIT licensed. It is not affiliated with Logitech, LG, Lunar, BetterDisplay, or Apple.
