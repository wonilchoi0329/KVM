import Foundation
import HostHopCore
import OSLog

struct SwitchOutcome: Sendable {
    var keyboardError: String?
    var mouseError: String?
    var monitorError: String?
    var monitorAcceptedWrites: Int = 0
    var monitorEnabled: Bool = true

    var succeeded: Bool {
        keyboardError == nil && mouseError == nil && monitorError == nil
    }
}

actor SwitchEngine {
    private let configuration: HostHopConfiguration
    private let hid: HIDPPController
    private let ddc: LGDDCController
    private let logger: Logger
    private var lastEventNanoseconds: [Int: UInt64] = [:]
    private var triggerInFlight = false
    private var activeChannel: Int?
    private var pendingTrigger: (channel: Int, source: String)?

    init(
        configuration: HostHopConfiguration,
        hid: HIDPPController,
        logger: Logger = Logger(subsystem: "com.wonil.hosthop", category: "switch")
    ) {
        self.configuration = configuration
        self.hid = hid
        self.ddc = LGDDCController(configuration: configuration.lgDDC)
        self.logger = logger
    }

    func handleNotification(channel: Int) async {
        await handleTrigger(channel: channel, source: "Easy-Switch")
    }

    func handleHotKey(channel: Int) async {
        await handleTrigger(channel: channel, source: "F\(channel + 1)")
    }

    private func handleTrigger(channel: Int, source: String) async {
        // Destination 3 is intentionally a no-op.
        guard (0...1).contains(channel), configuration.supports(channel: channel) else {
            logger.debug("Ignoring unmapped Logitech channel \(channel + 1, privacy: .public)")
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let debounce = UInt64(configuration.debounceMilliseconds) * 1_000_000
        if let last = lastEventNanoseconds[channel], now >= last, now - last < debounce {
            logger.debug("Debounced duplicate channel \(channel + 1, privacy: .public) report")
            return
        }
        lastEventNanoseconds[channel] = now

        guard !triggerInFlight else {
            if activeChannel == channel {
                pendingTrigger = nil
                logger.debug("Current channel \(channel + 1, privacy: .public) remains the latest request")
            } else {
                pendingTrigger = (channel, source)
                logger.debug("Queued overlapping \(source, privacy: .public) request for channel \(channel + 1, privacy: .public)")
            }
            return
        }
        triggerInFlight = true
        activeChannel = channel
        defer {
            pendingTrigger = nil
            activeChannel = nil
            triggerInFlight = false
        }

        var next = (channel: channel, source: source)
        while true {
            _ = await perform(channel: next.channel)
            guard let pending = pendingTrigger else { break }
            pendingTrigger = nil
            activeChannel = pending.channel
            next = pending
        }
    }

    func switchNow(channel: Int) async -> SwitchOutcome {
        await perform(channel: channel)
    }

    private func perform(channel: Int) async -> SwitchOutcome {
        guard (0...1).contains(channel), configuration.supports(channel: channel) else {
            return SwitchOutcome(
                keyboardError: "Channel \(channel + 1) is not configured",
                mouseError: "Channel \(channel + 1) is not configured",
                monitorError: "Channel \(channel + 1) is not configured"
            )
        }

        let transactionLock: SwitchTransactionLock
        do {
            transactionLock = try .acquire()
        } catch {
            let message = error.localizedDescription
            logger.error("Switch transaction rejected: \(message, privacy: .public)")
            return SwitchOutcome(keyboardError: message, mouseError: message, monitorError: message)
        }
        _ = transactionLock

        logger.info("Switching Logitech devices and LG input to channel \(channel + 1, privacy: .public)")
        async let hidOutcome = hid.switchKeyboardAndMouse(toChannel: channel)
        async let monitorOutcome = ddc.switchInput(channel: channel)
        let (hidResult, monitorResult) = await (hidOutcome, monitorOutcome)

        if let keyboardError = hidResult.keyboardError {
            logger.error("Keyboard switch failed: \(keyboardError, privacy: .public)")
        }
        if let mouseError = hidResult.mouseError {
            logger.error("Mouse switch failed: \(mouseError, privacy: .public)")
        }
        if let monitorError = monitorResult.error {
            logger.error("LG input switch failed: \(monitorError, privacy: .public)")
        } else if monitorResult.enabled {
            logger.info("LG alternate DDC accepted \(monitorResult.acceptedWrites, privacy: .public) write(s) via chip 0x\(String(monitorResult.chipAddress, radix: 16, uppercase: true), privacy: .public)")
        }
        if hidResult.succeeded && monitorResult.error == nil {
            logger.info("Channel \(channel + 1, privacy: .public) switch dispatched successfully")
        }
        return SwitchOutcome(
            keyboardError: hidResult.keyboardError,
            mouseError: hidResult.mouseError,
            monitorError: monitorResult.error,
            monitorAcceptedWrites: monitorResult.acceptedWrites,
            monitorEnabled: monitorResult.enabled
        )
    }
}
