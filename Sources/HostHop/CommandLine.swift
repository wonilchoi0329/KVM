import Darwin
import Foundation
import HostHopCore
import ServiceManagement

enum HostHopCommandLine {
    static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else { return 0 }
        do {
            switch command {
            case "configure":
                guard arguments.count == 1 else { throw CommandError.usage }
                try await configure()
                return 0
            case "diagnose":
                guard arguments.count == 1 || (arguments.count == 2 && arguments[1] == "--verbose") else {
                    throw CommandError.usage
                }
                return await diagnose(verbose: arguments.count == 2)
            case "test":
                guard arguments.count == 2, let humanChannel = Int(arguments[1]), (1...2).contains(humanChannel) else {
                    throw CommandError.usage
                }
                return await test(channel: humanChannel - 1)
            case "login-item":
                guard arguments.count == 2, ["enable", "disable"].contains(arguments[1]) else {
                    throw CommandError.usage
                }
                try await updateLoginItem(enable: arguments[1] == "enable")
                return 0
            case "help", "--help", "-h":
                printUsage()
                return 0
            default:
                throw CommandError.usage
            }
        } catch {
            writeError("HostHop: \(error.localizedDescription)")
            if case CommandError.usage = error { printUsage(toStandardError: true) }
            return 2
        }
    }

    private static func configure() async throws {
        guard isatty(STDIN_FILENO) == 1 else { throw CommandError.interactiveTerminalRequired }
        print("HostHop guided setup")
        print("Keep the Pebble keyboard and MX mouse connected to this Mac. Setup only reads device identity and display EDID; it does not switch anything.\n")

        if HIDInputMonitoring.status != .granted {
            _ = HIDInputMonitoring.request()
            throw CommandError.inputMonitoringRequired
        }

        print("Discovering compatible Logitech HID++ devices for 3 seconds…")
        let controller = HIDPPController(config: .discoveryConfiguration)
        let discovered = try await controller.discoverCandidates()
        let candidates = deduplicated(discovered)
        let keyboard = try choose(
            candidates.filter { $0.deviceType == .keyboard },
            label: "keyboard"
        )
        let mouse = try choose(
            candidates.filter { [.mouse, .trackpad, .trackball].contains($0.deviceType) },
            label: "mouse"
        )

        var monitor: LGDDCConfiguration?
        do {
            let displays = try LGDDCDiscovery.discover()
            if confirm("Enroll the supported LG display found on this Mac?", defaultYes: true) {
                let selected = try chooseDisplay(displays)
                monitor = try selected.configuration.validated()
            }
        } catch {
            print("Monitor: not enrolled — \(error.localizedDescription)")
        }

        let configuration = HostHopConfiguration(
            keyboard: keyboard.enrollmentMatch,
            mouse: mouse.enrollmentMatch,
            lgDDC: monitor
        )
        _ = try configuration.validated()

        print("\nConfiguration summary:")
        print("  Keyboard: \(describe(keyboard))")
        print("  Mouse: \(describe(mouse))")
        print("  Monitor: \(monitor == nil ? "disabled" : "supported LG alternate input switching")")
        guard confirm("Save this configuration?", defaultYes: true) else {
            throw CommandError.cancelled
        }

        let store = ConfigurationStore()
        try store.save(configuration)
        print("Saved \(store.url.path)")
        if FileManager.default.fileExists(atPath: store.backupURL.path) {
            print("Previous configuration preserved at \(store.backupURL.path)")
        }
        print("Next: run `HostHop diagnose`, then `HostHop login-item enable`.")
    }

    private static func diagnose(verbose: Bool) async -> Int32 {
        let store = ConfigurationStore()
        let configuration: HostHopConfiguration
        do {
            configuration = try store.load()
        } catch {
            print("Configuration: ERROR — \(error.localizedDescription)")
            print("Run `HostHop configure` in Terminal.")
            return 1
        }

        print("HostHop diagnostics\(verbose ? " (verbose; may contain device identifiers)" : "")")
        print("Bundle: \(Bundle.main.bundleURL.path)")
        print("Architecture: \(machineArchitecture())")
        print("Input Monitoring: \(HIDInputMonitoring.status.rawValue)")
        print("Accessibility: not required")
        print("Bluetooth privacy permission: not required")
        print("Login item: \(loginItemStatus(SMAppService.mainApp.status))")
        print("Configuration: \(store.url.path) — valid v\(configuration.version)")
        print("Keyboard: vendor=0x\(String(format: "%04X", configuration.keyboard.vendorID)) product=0x\(String(format: "%04X", configuration.keyboard.productID)) \(configuration.keyboard.productName)")
        print("Mouse: vendor=0x\(String(format: "%04X", configuration.mouse.vendorID)) product=0x\(String(format: "%04X", configuration.mouse.productID)) \(configuration.mouse.productName)")
        print("LG DDC: \(await LGDDCController(configuration: configuration.lgDDC).diagnose(verbose: verbose))")

        let hid = HIDPPController(config: configuration)
        for line in await hid.diagnose(verbose: verbose) { print("HID: \(line)") }
        return 0
    }

    private static func test(channel: Int) async -> Int32 {
        do {
            let configuration = try ConfigurationStore().load()
            guard configuration.supports(channel: channel) else {
                throw CommandError.channelNotConfigured(channel + 1)
            }
            let hid = HIDPPController(config: configuration)
            let outcome = await SwitchEngine(configuration: configuration, hid: hid).switchNow(channel: channel)
            print("Keyboard: \(outcome.keyboardError.map { "ERROR — \($0)" } ?? "command accepted")")
            print("Mouse: \(outcome.mouseError.map { "ERROR — \($0)" } ?? "command accepted")")
            let monitorSuccess = outcome.monitorEnabled
                ? "command accepted (\(outcome.monitorAcceptedWrites) write(s))"
                : "disabled"
            print("Monitor: \(outcome.monitorError.map { "ERROR — \($0)" } ?? monitorSuccess)")
            return outcome.succeeded ? 0 : 1
        } catch {
            writeError("HostHop test: \(error.localizedDescription)")
            return 1
        }
    }

    private static func deduplicated(_ candidates: [HIDEnrollmentCandidate]) -> [HIDEnrollmentCandidate] {
        candidates.reduce(into: []) { result, candidate in
            if !result.contains(where: {
                $0.vendorID == candidate.vendorID
                    && $0.productID == candidate.productID
                    && $0.serialNumber == candidate.serialNumber
                    && $0.deviceType == candidate.deviceType
            }) {
                result.append(candidate)
            }
        }
    }

    private static func choose(
        _ candidates: [HIDEnrollmentCandidate],
        label: String
    ) throws -> HIDEnrollmentCandidate {
        guard !candidates.isEmpty else { throw CommandError.deviceNotFound(label) }
        if candidates.count == 1 {
            print("Found \(label): \(describe(candidates[0]))")
            return candidates[0]
        }
        print("Select the \(label):")
        for (index, candidate) in candidates.enumerated() {
            print("  \(index + 1)) \(describe(candidate))")
        }
        guard let line = readLine(), let selection = Int(line), candidates.indices.contains(selection - 1) else {
            throw CommandError.invalidSelection
        }
        return candidates[selection - 1]
    }

    private static func chooseDisplay(_ displays: [LGDDCDisplayCandidate]) throws -> LGDDCDisplayCandidate {
        guard let first = displays.first else { throw CommandError.invalidSelection }
        if displays.count == 1 { return first }
        print("Select the LG display:")
        for (index, display) in displays.enumerated() {
            print(String(format: "  %d) LG product 0x%04X (chip 0x%02X)", index + 1, display.productID, display.chipAddress))
        }
        guard let line = readLine(), let selection = Int(line), displays.indices.contains(selection - 1) else {
            throw CommandError.invalidSelection
        }
        return displays[selection - 1]
    }

    private static func describe(_ candidate: HIDEnrollmentCandidate) -> String {
        String(
            format: "%@ (vendor 0x%04X, product 0x%04X, %@, %d hosts)",
            candidate.productName,
            candidate.vendorID,
            candidate.productID,
            candidate.transport,
            candidate.hostCount
        )
    }

    private static func confirm(_ prompt: String, defaultYes: Bool) -> Bool {
        print("\(prompt) \(defaultYes ? "[Y/n]" : "[y/N]") ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !answer.isEmpty else {
            return defaultYes
        }
        return answer == "y" || answer == "yes"
    }

    private static func updateLoginItem(enable: Bool) async throws {
        try await MainActor.run {
            let service = SMAppService.mainApp
            if enable {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            print("Login item: \(loginItemStatus(service.status))")
            if service.status == .requiresApproval {
                print("Approve HostHop in System Settings → General → Login Items.")
            }
        }
    }

    private static func loginItemStatus(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires user approval"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    private static func printUsage(toStandardError: Bool = false) {
        let usage = """
        Usage:
          HostHop configure
          HostHop diagnose [--verbose]
          HostHop test 1|2
          HostHop login-item enable|disable
          HostHop                         Run the headless agent
        """
        if toStandardError { writeError(usage) } else { print(usage) }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private enum CommandError: LocalizedError {
    case usage
    case channelNotConfigured(Int)
    case interactiveTerminalRequired
    case inputMonitoringRequired
    case deviceNotFound(String)
    case invalidSelection
    case cancelled

    var errorDescription: String? {
        switch self {
        case .usage: return "invalid arguments"
        case .channelNotConfigured(let channel): return "channel \(channel) is not configured"
        case .interactiveTerminalRequired: return "guided setup requires an interactive Terminal"
        case .inputMonitoringRequired:
            return "Input Monitoring is required for discovery. Enable HostHop in System Settings → Privacy & Security → Input Monitoring, then rerun `HostHop configure`. No configuration was saved."
        case .deviceNotFound(let kind): return "No compatible enrolled \(kind) was found; no configuration was saved"
        case .invalidSelection: return "invalid setup selection"
        case .cancelled: return "setup cancelled; no configuration was saved"
        }
    }
}
