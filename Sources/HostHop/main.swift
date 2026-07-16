import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AgentDelegate()
    application.delegate = delegate
    application.run()
} else {
    Task {
        let status = await HostHopCommandLine.run(arguments)
        exit(status)
    }
    dispatchMain()
}
