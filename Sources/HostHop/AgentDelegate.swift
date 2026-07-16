import AppKit
import Foundation
import HostHopCore
import OSLog

final class AgentDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.wonil.hosthop", category: "agent")
    private var hotKeys: GlobalHotKeyController?
    private var hid: HIDPPController?
    private var engine: SwitchEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let configuration = try ConfigurationStore().load()
            if HIDInputMonitoring.status == .unknown {
                _ = HIDInputMonitoring.request()
            }
            guard HIDInputMonitoring.status == .granted else {
                logger.error("Input Monitoring is not granted. Enable HostHop in System Settings → Privacy & Security → Input Monitoring, then relaunch.")
                NSApp.terminate(nil)
                return
            }

            let hid = HIDPPController(config: configuration)
            let engine = SwitchEngine(configuration: configuration, hid: hid)
            try hid.start { [weak engine] (channel: Int) in
                guard let engine else { return }
                Task { await engine.handleNotification(channel: channel) }
            }
            let hotKeys = try GlobalHotKeyController { [weak engine] channel in
                guard let engine else { return }
                Task { await engine.handleHotKey(channel: channel) }
            }
            self.hotKeys = hotKeys
            self.hid = hid
            self.engine = engine
            logger.info("HostHop is listening for global F1/F2 hotkeys")
        } catch {
            logger.fault("HostHop could not start: \(error.localizedDescription, privacy: .public)")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys?.stop()
        hotKeys = nil
        hid?.stop()
        hid = nil
        engine = nil
    }
}
