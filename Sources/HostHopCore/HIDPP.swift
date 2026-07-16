import Foundation
import IOKit.hid

public enum HIDPPDeviceType: UInt8, Codable, Sendable, CustomStringConvertible {
    case keyboard = 0
    case mouse = 3
    case trackpad = 4
    case trackball = 5

    public var description: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "mouse"
        case .trackpad: return "trackpad"
        case .trackball: return "trackball"
        }
    }
}

public struct HIDPPPacket: Equatable, Sendable {
    public var reportID: UInt8
    public var deviceIndex: UInt8
    public var featureIndex: UInt8
    public var function: UInt8
    public var softwareID: UInt8
    public var payload: [UInt8]
}

public struct HIDPPFeatureResolution: Equatable, Sendable {
    public var index: UInt8
    public var typeFlags: UInt8
    public var version: UInt8
}

public struct HIDPPHostInfo: Equatable, Sendable {
    public var hostCount: Int
    public var currentHost: Int
    public var capabilities: UInt8
}

enum HIDPPHostSwitchPolicy {
    static func requiresWrite(hostInfo: HIDPPHostInfo?, targetChannel: Int) -> Bool {
        guard let hostInfo else { return true }
        return hostInfo.currentHost != targetChannel
    }
}

public struct HIDPPSwitchOutcome: Equatable, Sendable {
    public var keyboardError: String?
    public var mouseError: String?

    public init(keyboardError: String? = nil, mouseError: String? = nil) {
        self.keyboardError = keyboardError
        self.mouseError = mouseError
    }

    public var succeeded: Bool {
        keyboardError == nil && mouseError == nil
    }
}

public enum HIDPPPacketCodec {
    public static let reportShort: UInt8 = 0x10
    public static let reportLong: UInt8 = 0x11
    public static let directDeviceIndex: UInt8 = 0xFF
    public static let softwareID: UInt8 = 0x0B
    public static let featureRoot: UInt16 = 0x0000
    public static let featureDeviceTypeAndName: UInt16 = 0x0005
    public static let featureChangeHost: UInt16 = 0x1814

    public static func rootGetFeature(
        _ featureID: UInt16,
        deviceIndex: UInt8 = directDeviceIndex,
        softwareID: UInt8 = softwareID
    ) -> [UInt8] {
        longPacket(
            deviceIndex: deviceIndex,
            featureIndex: 0,
            functionByte: softwareID & 0x0F,
            payload: [UInt8(featureID >> 8), UInt8(featureID & 0xFF), 0]
        )
    }

    public static func deviceType(
        featureIndex: UInt8,
        deviceIndex: UInt8 = directDeviceIndex,
        softwareID: UInt8 = softwareID
    ) -> [UInt8] {
        longPacket(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionByte: 0x20 | (softwareID & 0x0F),
            payload: []
        )
    }

    public static func getHostInfo(
        featureIndex: UInt8,
        deviceIndex: UInt8 = directDeviceIndex,
        softwareID: UInt8 = softwareID
    ) -> [UInt8] {
        longPacket(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionByte: softwareID & 0x0F,
            payload: []
        )
    }

    public static func setCurrentHost(
        featureIndex: UInt8,
        channel: UInt8,
        deviceIndex: UInt8 = directDeviceIndex,
        softwareID: UInt8 = softwareID
    ) -> [UInt8] {
        longPacket(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionByte: 0x10 | (softwareID & 0x0F),
            payload: [channel]
        )
    }

    public static func decode(_ bytes: [UInt8]) throws -> HIDPPPacket {
        guard let reportID = bytes.first else { throw HIDPPCodecError.emptyPacket }
        let requiredLength: Int
        switch reportID {
        case reportShort: requiredLength = 7
        case reportLong: requiredLength = 20
        default: throw HIDPPCodecError.unsupportedReportID(reportID)
        }
        guard bytes.count == requiredLength else {
            throw HIDPPCodecError.invalidLength(expected: requiredLength, actual: bytes.count)
        }
        return HIDPPPacket(
            reportID: reportID,
            deviceIndex: bytes[1],
            featureIndex: bytes[2],
            function: bytes[3] >> 4,
            softwareID: bytes[3] & 0x0F,
            payload: Array(bytes[4...])
        )
    }

    public static func decodeFeatureResolution(
        _ bytes: [UInt8],
        softwareID: UInt8 = softwareID
    ) -> HIDPPFeatureResolution? {
        guard let packet = try? decode(bytes),
              packet.featureIndex == 0,
              packet.function == 0,
              packet.softwareID == (softwareID & 0x0F),
              packet.payload.count >= 3 else { return nil }
        return HIDPPFeatureResolution(
            index: packet.payload[0],
            typeFlags: packet.payload[1],
            version: packet.payload[2]
        )
    }

    public static func decodeDeviceType(
        _ bytes: [UInt8],
        featureIndex: UInt8,
        softwareID: UInt8 = softwareID
    ) -> HIDPPDeviceType? {
        guard let packet = try? decode(bytes),
              packet.featureIndex == featureIndex,
              packet.function == 2,
              packet.softwareID == (softwareID & 0x0F),
              let raw = packet.payload.first else { return nil }
        return HIDPPDeviceType(rawValue: raw)
    }

    public static func decodeHostInfo(
        _ bytes: [UInt8],
        featureIndex: UInt8,
        softwareID: UInt8 = softwareID
    ) -> HIDPPHostInfo? {
        guard let packet = try? decode(bytes),
              packet.featureIndex == featureIndex,
              packet.function == 0,
              packet.softwareID == (softwareID & 0x0F),
              packet.payload.count >= 2 else { return nil }
        let hostCount = Int(packet.payload[0])
        let currentHost = Int(packet.payload[1])
        guard hostCount > 0, currentHost < hostCount else { return nil }
        return HIDPPHostInfo(
            hostCount: hostCount,
            currentHost: currentHost,
            capabilities: packet.payload.count > 2 ? packet.payload[2] : 0
        )
    }

    public static func decodeChangeHostNotification(
        _ bytes: [UInt8],
        featureIndex: UInt8
    ) -> Int? {
        guard let packet = try? decode(bytes),
              packet.featureIndex == featureIndex,
              packet.function == 0,
              packet.softwareID == 0,
              packet.payload.count >= 2 else { return nil }
        let hostCount = Int(packet.payload[0])
        let currentHost = Int(packet.payload[1])
        guard hostCount > 0, currentHost < hostCount else { return nil }
        return currentHost
    }

    public static func errorCode(
        _ bytes: [UInt8],
        matching request: [UInt8]
    ) -> UInt8? {
        guard bytes.count >= 6, request.count >= 4,
              bytes[0] == reportLong,
              bytes[2] == 0xFF,
              bytes[3] == request[2],
              bytes[4] == request[3] else { return nil }
        return bytes[5]
    }

    public static func isResponse(_ bytes: [UInt8], to request: [UInt8]) -> Bool {
        guard bytes.count >= 4, request.count >= 4,
              bytes[0] == request[0],
              bytes[1] == request[1] || bytes[1] == (request[1] ^ 0xFF) else { return false }
        return (bytes[2] == request[2] && bytes[3] == request[3])
            || errorCode(bytes, matching: request) != nil
    }

    private static func longPacket(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionByte: UInt8,
        payload: [UInt8]
    ) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 20)
        packet[0] = reportLong
        packet[1] = deviceIndex
        packet[2] = featureIndex
        packet[3] = functionByte
        for (offset, byte) in payload.prefix(16).enumerated() {
            packet[offset + 4] = byte
        }
        return packet
    }
}

public enum HIDPPCodecError: LocalizedError, Equatable {
    case emptyPacket
    case unsupportedReportID(UInt8)
    case invalidLength(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyPacket: return "Empty HID++ packet"
        case .unsupportedReportID(let id): return String(format: "Unsupported HID++ report ID 0x%02X", id)
        case .invalidLength(let expected, let actual): return "Invalid HID++ packet length: expected \(expected), got \(actual)"
        }
    }
}

public enum HIDInputMonitoringStatus: String, Sendable {
    case granted
    case denied
    case unknown
}

public enum HIDInputMonitoring {
    public static var status: HIDInputMonitoringStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    @discardableResult
    public static func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

public struct HIDEnrollmentCandidate: Equatable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var productName: String
    public var serialNumber: String?
    public var transport: String
    public var deviceType: HIDPPDeviceType
    public var hostCount: Int

    public var enrollmentMatch: HIDProductMatch {
        HIDProductMatch(
            vendorID: vendorID,
            productID: productID,
            productName: productName,
            serialNumber: serialNumber,
            transport: transport,
            expectedType: deviceType
        )
    }
}

private struct HIDDescriptor: Sendable {
    var registryID: UInt64
    var vendorID: Int
    var productID: Int
    var productName: String
    var serialNumber: String
    var transport: String
    var usagePage: Int
    var usage: Int
}

private final class ManagedHIDDevice: @unchecked Sendable {
    let device: IOHIDDevice
    let descriptor: HIDDescriptor
    let changeHostIndex: UInt8
    let deviceType: HIDPPDeviceType?
    let hostInfo: HIDPPHostInfo?

    init(
        device: IOHIDDevice,
        descriptor: HIDDescriptor,
        changeHostIndex: UInt8,
        deviceType: HIDPPDeviceType?,
        hostInfo: HIDPPHostInfo?
    ) {
        self.device = device
        self.descriptor = descriptor
        self.changeHostIndex = changeHostIndex
        self.deviceType = deviceType
        self.hostInfo = hostInfo
    }
}

private struct ManagedHIDLookup: @unchecked Sendable {
    var device: ManagedHIDDevice?
    var error: String?
}

private struct ProbeDiagnostic: Sendable {
    var descriptor: HIDDescriptor
    var selector: String
    var deviceTypeFeatureIndex: UInt8?
    var deviceType: HIDPPDeviceType?
    var changeHostFeatureIndex: UInt8?
    var hostInfo: HIDPPHostInfo?
    var error: String?
    var seizeResult: String?
}

private final class PendingHIDResponse: @unchecked Sendable {
    let request: [UInt8]
    let semaphore = DispatchSemaphore(value: 0)
    var response: [UInt8]?
    var cancellationError: Error?

    init(request: [UInt8]) {
        self.request = request
    }
}

private final class HIDCallbackContext {
    weak var controller: HIDPPController?
    let generation: UInt64

    init(controller: HIDPPController, generation: UInt64) {
        self.controller = controller
        self.generation = generation
    }
}

private final class HIDSession {
    let manager: IOHIDManager
    let generation: UInt64
    let contextPointer: UnsafeMutableRawPointer
    let cancelled = DispatchSemaphore(value: 0)

    init(manager: IOHIDManager, generation: UInt64, contextPointer: UnsafeMutableRawPointer) {
        self.manager = manager
        self.generation = generation
        self.contextPointer = contextPointer
    }
}

public final class HIDPPController: @unchecked Sendable {
    private let config: HostHopConfiguration
    private let hidQueue = DispatchQueue(label: "com.wonil.hosthop.hid")
    private let probeQueue = DispatchQueue(label: "com.wonil.hosthop.hid.probe", attributes: .concurrent)
    private let lifecycleLock = NSLock()
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var nextGeneration: UInt64 = 1
    private var session: HIDSession?

    // Accessed only on hidQueue.
    private var activeGeneration: UInt64?
    private var notificationHandler: ((Int) -> Void)?
    private var knownDevices: [UInt64: IOHIDDevice] = [:]
    private var diagnostics: [UInt64: ProbeDiagnostic] = [:]
    private var pendingResponses: [UInt64: PendingHIDResponse] = [:]
    private var keyboards: [UInt64: ManagedHIDDevice] = [:]
    private var mice: [UInt64: ManagedHIDDevice] = [:]
    private var keyboardWaiters: [UUID: CheckedContinuation<ManagedHIDDevice, Error>] = [:]
    private var mouseWaiters: [UUID: CheckedContinuation<ManagedHIDDevice, Error>] = [:]
    private var lastNotificationDelivery: [Int: UInt64] = [:]

    public init(config: HostHopConfiguration) {
        self.config = config
        hidQueue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    public func start(onChannel: @escaping (Int) -> Void) throws {
        lifecycleLock.lock()
        if let existing = session {
            lifecycleLock.unlock()
            hidQueue.async { [weak self] in
                guard self?.activeGeneration == existing.generation else { return }
                self?.notificationHandler = onChannel
            }
            return
        }

        let generation = nextGeneration
        nextGeneration &+= 1
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let context = HIDCallbackContext(controller: self, generation: generation)
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        let newSession = HIDSession(manager: manager, generation: generation, contextPointer: contextPointer)

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDictionaries as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatchedCallback, contextPointer)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemovedCallback, contextPointer)
        IOHIDManagerRegisterInputReportCallback(manager, Self.inputReportCallback, contextPointer)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            Unmanaged<HIDCallbackContext>.fromOpaque(contextPointer).release()
            lifecycleLock.unlock()
            throw HIDPPError.managerOpenFailed(openResult)
        }

        // Once a dispatch queue is assigned, IOHID requires the manager to be
        // activated and later cancelled before release. Open first so a denied
        // Input Monitoring request can unwind without releasing a dispatch-
        // associated manager in an invalid state.
        IOHIDManagerSetDispatchQueue(manager, hidQueue)
        let cancelled = newSession.cancelled
        IOHIDManagerSetCancelHandler(manager) {
            // Capturing the manager keeps it alive until all queued callbacks
            // have drained, as required by the dispatch-queue IOHID contract.
            _ = manager
            Unmanaged<HIDCallbackContext>.fromOpaque(contextPointer).release()
            cancelled.signal()
        }

        session = newSession
        hidQueue.sync {
            activeGeneration = generation
            notificationHandler = onChannel
        }
        IOHIDManagerActivate(manager)
        lifecycleLock.unlock()

        hidQueue.async { [weak self] in
            guard let self, self.activeGeneration == generation,
                  let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
            for device in devices {
                self.handleMatched(device, generation: generation)
            }
        }
    }

    public func stop() {
        lifecycleLock.lock()
        guard let current = session else {
            lifecycleLock.unlock()
            return
        }

        let cleanup = { [self] in
            activeGeneration = nil
            let cancellation = HIDPPError.sessionStopped
            for pending in pendingResponses.values {
                pending.cancellationError = cancellation
                pending.semaphore.signal()
            }
            pendingResponses.removeAll()
            for waiter in mouseWaiters.values {
                waiter.resume(throwing: cancellation)
            }
            mouseWaiters.removeAll()
            for waiter in keyboardWaiters.values {
                waiter.resume(throwing: cancellation)
            }
            keyboardWaiters.removeAll()
            notificationHandler = nil
            knownDevices.removeAll()
            diagnostics.removeAll()
            keyboards.removeAll()
            mice.removeAll()
            lastNotificationDelivery.removeAll()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            cleanup()
        } else {
            hidQueue.sync(execute: cleanup)
        }

        _ = IOHIDManagerClose(current.manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerCancel(current.manager)
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            _ = current.cancelled.wait(timeout: .now() + 1)
        }
        session = nil
        lifecycleLock.unlock()
    }

    public func switchMouse(toChannel channel: Int) async throws {
        guard (0...1).contains(channel) else { throw HIDPPError.invalidChannel(channel) }
        let startedHere = !isRunning
        if startedHere {
            try start { _ in }
        }
        defer {
            if startedHere { stop() }
        }

        let managed = try await waitForMouse(timeoutSeconds: 2)
        if let hostInfo = managed.hostInfo, channel >= hostInfo.hostCount {
            throw HIDPPError.invalidHost(channel, hostInfo.hostCount)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            probeQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: HIDPPError.sessionStopped)
                    return
                }
                do {
                    try self.sendHostSwitch(
                        managed,
                        channel: channel,
                        seize: self.config.seizeMouseForSwitch,
                        stopAfterFirstSuccess: false
                    )
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func switchKeyboardAndMouse(toChannel channel: Int) async -> HIDPPSwitchOutcome {
        guard (0...1).contains(channel) else {
            let message = HIDPPError.invalidChannel(channel).localizedDescription
            return HIDPPSwitchOutcome(keyboardError: message, mouseError: message)
        }

        let startedHere = !isRunning
        if startedHere {
            do {
                try start { _ in }
            } catch {
                let message = error.localizedDescription
                return HIDPPSwitchOutcome(keyboardError: message, mouseError: message)
            }
        }
        defer {
            if startedHere { stop() }
        }

        // Resolve both interfaces before either CHANGE_HOST write. A successful
        // write can disconnect its IOHIDDevice immediately; keeping strong
        // references to both prevents the first switch from racing the second
        // lookup.
        async let keyboardLookup = locateKeyboard(timeoutSeconds: 2)
        async let mouseLookup = locateMouse(timeoutSeconds: 2)
        let (keyboard, mouse) = await (keyboardLookup, mouseLookup)

        async let keyboardError = switchError(
            lookup: keyboard,
            channel: channel,
            seize: false,
            stopAfterFirstSuccess: false
        )
        async let mouseError = switchError(
            lookup: mouse,
            channel: channel,
            seize: config.seizeMouseForSwitch,
            stopAfterFirstSuccess: false
        )
        return await HIDPPSwitchOutcome(
            keyboardError: keyboardError,
            mouseError: mouseError
        )
    }

    public func diagnose(verbose: Bool = false) async -> [String] {
        let startedHere = !isRunning
        if startedHere {
            do {
                try start { _ in }
            } catch {
                return ["HID manager: ERROR — \(error.localizedDescription)"]
            }
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let lines: [String] = hidQueue.sync {
            guard !diagnostics.isEmpty else {
                return ["HID interfaces: none matched Logitech direct-Bluetooth usage pairs"]
            }
            return diagnostics.values.sorted { $0.descriptor.registryID < $1.descriptor.registryID }.map {
                Self.describe($0, verbose: verbose)
            }
        }
        if startedHere { stop() }
        return lines
    }

    public func discoverCandidates(timeoutSeconds: Double = 3) async throws -> [HIDEnrollmentCandidate] {
        guard (0.5...10).contains(timeoutSeconds) else { throw HIDPPError.invalidDiscoveryTimeout }
        let startedHere = !isRunning
        if startedHere { try start { _ in } }
        defer { if startedHere { stop() } }
        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
        return hidQueue.sync {
            diagnostics.values.compactMap { diagnostic in
                guard diagnostic.changeHostFeatureIndex != nil,
                      let type = diagnostic.deviceType,
                      let hostInfo = diagnostic.hostInfo else { return nil }
                let descriptor = diagnostic.descriptor
                return HIDEnrollmentCandidate(
                    vendorID: descriptor.vendorID,
                    productID: descriptor.productID,
                    productName: descriptor.productName,
                    serialNumber: descriptor.serialNumber.isEmpty ? nil : descriptor.serialNumber,
                    transport: descriptor.transport,
                    deviceType: type,
                    hostCount: hostInfo.hostCount
                )
            }.sorted {
                if $0.deviceType.rawValue != $1.deviceType.rawValue {
                    return $0.deviceType.rawValue < $1.deviceType.rawValue
                }
                return $0.productID < $1.productID
            }
        }
    }

    private var isRunning: Bool {
        lifecycleLock.withLock { session != nil }
    }

    private var matchingDictionaries: [[String: Any]] {
        let usages = [(0xFF43, 0x0202), (0xFF00, 0x0002), (0xFF0C, 0x0001), (0x0001, 0x0006), (0x0001, 0x0002)]
        let products = [(config.keyboard.vendorID, config.keyboard.productID), (config.mouse.vendorID, config.mouse.productID)]
        return products.flatMap { vendorID, productID in
            usages.map { usagePage, usage in
                [
                    kIOHIDVendorIDKey: vendorID,
                    kIOHIDProductIDKey: productID,
                    kIOHIDDeviceUsagePageKey: usagePage,
                    kIOHIDDeviceUsageKey: usage,
                ]
            }
        }
    }

    private static let deviceMatchedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let box = Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue()
        box.controller?.handleMatched(device, generation: box.generation)
    }

    private static let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let box = Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue()
        box.controller?.handleRemoved(device, generation: box.generation)
    }

    private static let inputReportCallback: IOHIDReportCallback = {
        context, result, sender, _, reportID, report, reportLength in
        guard result == kIOReturnSuccess, let context, let sender else { return }
        let box = Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue()
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        box.controller?.handleRawInput(
            report,
            reportLength: reportLength,
            reportID: UInt8(truncatingIfNeeded: reportID),
            from: device,
            generation: box.generation
        )
    }

    private func handleMatched(_ device: IOHIDDevice, generation: UInt64) {
        guard activeGeneration == generation else { return }
        let descriptor = Self.descriptor(for: device)
        guard descriptor.vendorID == 0x046D, knownDevices[descriptor.registryID] == nil else { return }
        knownDevices[descriptor.registryID] = device

        let keyboardMatch = config.keyboard.matches(
            vendorID: descriptor.vendorID,
            productID: descriptor.productID,
            serialNumber: descriptor.serialNumber,
            transport: descriptor.transport
        )
        let mouseMatch = config.mouse.matches(
            vendorID: descriptor.vendorID,
            productID: descriptor.productID,
            serialNumber: descriptor.serialNumber,
            transport: descriptor.transport
        )
        let selector = keyboardMatch && mouseMatch ? "keyboard+mouse" : keyboardMatch ? "keyboard" : mouseMatch ? "mouse" : "none"
        diagnostics[descriptor.registryID] = ProbeDiagnostic(descriptor: descriptor, selector: selector)
        guard keyboardMatch || mouseMatch else { return }
        guard !descriptor.transport.isEmpty,
              descriptor.transport.localizedCaseInsensitiveContains("bluetooth") else {
            diagnostics[descriptor.registryID]?.error = "not direct Bluetooth"
            return
        }

        probeQueue.async { [weak self] in
            self?.probe(
                device,
                descriptor: descriptor,
                keyboardMatch: keyboardMatch,
                mouseMatch: mouseMatch,
                generation: generation
            )
        }
    }

    private func handleRemoved(_ device: IOHIDDevice, generation: UInt64) {
        guard activeGeneration == generation else { return }
        let id = Self.registryID(for: device)
        knownDevices[id] = nil
        diagnostics[id] = nil
        keyboards[id] = nil
        mice[id] = nil
        if let pending = pendingResponses.removeValue(forKey: id) {
            pending.cancellationError = HIDPPError.deviceRemoved
            pending.semaphore.signal()
        }
    }

    private func handleInput(_ bytes: [UInt8], from device: IOHIDDevice, generation: UInt64) {
        guard activeGeneration == generation else { return }
        let id = Self.registryID(for: device)
        if let pending = pendingResponses[id], HIDPPPacketCodec.isResponse(bytes, to: pending.request) {
            pendingResponses[id] = nil
            pending.response = bytes
            pending.semaphore.signal()
            return
        }
        guard let keyboard = keyboards[id],
              let channel = HIDPPPacketCodec.decodeChangeHostNotification(
                bytes,
                featureIndex: keyboard.changeHostIndex
              ),
              let handler = notificationHandler else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let interval = UInt64(config.debounceMilliseconds) * 1_000_000
        if let previous = lastNotificationDelivery[channel], now &- previous < interval { return }
        lastNotificationDelivery[channel] = now
        handler(channel)
    }

    private func handleRawInput(
        _ report: UnsafeMutablePointer<UInt8>,
        reportLength: Int,
        reportID: UInt8,
        from device: IOHIDDevice,
        generation: UInt64
    ) {
        guard activeGeneration == generation else { return }
        let id = Self.registryID(for: device)
        guard knownDevices[id] != nil,
              pendingResponses[id] != nil || keyboards[id] != nil,
              [6, 7, 19, 20].contains(reportLength) else { return }
        var bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
        if reportLength == 19, reportID == HIDPPPacketCodec.reportLong {
            bytes.insert(reportID, at: 0)
        } else if reportLength == 6, reportID == HIDPPPacketCodec.reportShort {
            bytes.insert(reportID, at: 0)
        }
        guard bytes.count == 7 || bytes.count == 20 else { return }
        handleInput(bytes, from: device, generation: generation)
    }

    private func probe(
        _ device: IOHIDDevice,
        descriptor: HIDDescriptor,
        keyboardMatch: Bool,
        mouseMatch: Bool,
        generation: UInt64
    ) {
        var typeIndex: UInt8?
        var deviceType: HIDPPDeviceType?
        var changeIndex: UInt8?
        var hostInfo: HIDPPHostInfo?
        var errors: [String] = []

        do {
            typeIndex = try resolveFeature(HIDPPPacketCodec.featureDeviceTypeAndName, on: device, generation: generation)
            if let typeIndex {
                let response = try performRequest(
                    HIDPPPacketCodec.deviceType(featureIndex: typeIndex),
                    on: device,
                    generation: generation
                )
                deviceType = HIDPPPacketCodec.decodeDeviceType(response, featureIndex: typeIndex)
            }
        } catch {
            errors.append("0x0005: \(error.localizedDescription)")
        }

        do {
            changeIndex = try resolveFeature(HIDPPPacketCodec.featureChangeHost, on: device, generation: generation)
            if let changeIndex {
                do {
                    let response = try performRequest(
                        HIDPPPacketCodec.getHostInfo(featureIndex: changeIndex),
                        on: device,
                        generation: generation
                    )
                    hostInfo = HIDPPPacketCodec.decodeHostInfo(response, featureIndex: changeIndex)
                } catch {
                    errors.append("host info: \(error.localizedDescription)")
                }
            } else {
                errors.append("0x1814 unsupported")
            }
        } catch {
            errors.append("0x1814: \(error.localizedDescription)")
        }

        hidQueue.async { [weak self] in
            guard let self, self.activeGeneration == generation, self.knownDevices[descriptor.registryID] != nil else { return }
            self.diagnostics[descriptor.registryID]?.deviceTypeFeatureIndex = typeIndex
            self.diagnostics[descriptor.registryID]?.deviceType = deviceType
            self.diagnostics[descriptor.registryID]?.changeHostFeatureIndex = changeIndex
            self.diagnostics[descriptor.registryID]?.hostInfo = hostInfo
            self.diagnostics[descriptor.registryID]?.error = errors.isEmpty ? nil : errors.joined(separator: "; ")
            guard let changeIndex else { return }

            let managed = ManagedHIDDevice(
                device: device,
                descriptor: descriptor,
                changeHostIndex: changeIndex,
                deviceType: deviceType,
                hostInfo: hostInfo
            )
            if keyboardMatch && deviceType == config.keyboard.expectedType {
                self.keyboards[descriptor.registryID] = managed
                let waiters = self.keyboardWaiters.values
                self.keyboardWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: managed) }
            }
            if mouseMatch && deviceType == config.mouse.expectedType {
                self.mice[descriptor.registryID] = managed
                let waiters = self.mouseWaiters.values
                self.mouseWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: managed) }
            }
        }
    }

    private func resolveFeature(
        _ featureID: UInt16,
        on device: IOHIDDevice,
        generation: UInt64
    ) throws -> UInt8? {
        // Root responses do not echo the requested feature ID. Use a distinct
        // software ID for CHANGE_HOST so a late 0x0005 response cannot satisfy
        // the next lookup on the same physical interface.
        let softwareID: UInt8 = featureID == HIDPPPacketCodec.featureChangeHost ? 0x0C : HIDPPPacketCodec.softwareID
        let response = try performRequest(
            HIDPPPacketCodec.rootGetFeature(featureID, softwareID: softwareID),
            on: device,
            generation: generation
        )
        guard let resolution = HIDPPPacketCodec.decodeFeatureResolution(response, softwareID: softwareID) else {
            throw HIDPPError.malformedResponse
        }
        return resolution.index == 0 ? nil : resolution.index
    }

    private func performRequest(
        _ request: [UInt8],
        on device: IOHIDDevice,
        generation: UInt64,
        timeoutSeconds: Double = 0.5
    ) throws -> [UInt8] {
        let id = Self.registryID(for: device)
        let pending = PendingHIDResponse(request: request)
        try hidQueue.sync {
            guard activeGeneration == generation, knownDevices[id] != nil else {
                throw HIDPPError.sessionStopped
            }
            guard pendingResponses[id] == nil else { throw HIDPPError.deviceBusy }
            pendingResponses[id] = pending
        }

        let result = request.withUnsafeBytes { buffer -> IOReturn in
            guard let baseAddress = buffer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(request[0]),
                baseAddress,
                request.count
            )
        }
        guard result == kIOReturnSuccess else {
            hidQueue.sync {
                if pendingResponses[id] === pending { pendingResponses[id] = nil }
            }
            throw HIDPPError.writeFailed(result)
        }

        guard pending.semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            hidQueue.sync {
                if pendingResponses[id] === pending { pendingResponses[id] = nil }
            }
            throw HIDPPError.responseTimedOut
        }
        if let error = pending.cancellationError { throw error }
        guard let response = pending.response else { throw HIDPPError.malformedResponse }
        if let code = HIDPPPacketCodec.errorCode(response, matching: request) {
            throw HIDPPError.protocolError(code)
        }
        return response
    }

    private func waitForMouse(timeoutSeconds: Double) async throws -> ManagedHIDDevice {
        try await withCheckedThrowingContinuation { continuation in
            hidQueue.async { [weak self] in
                guard let self, self.activeGeneration != nil else {
                    continuation.resume(throwing: HIDPPError.sessionStopped)
                    return
                }
                if let mouse = self.mice.values.sorted(by: {
                    $0.descriptor.registryID < $1.descriptor.registryID
                }).first {
                    continuation.resume(returning: mouse)
                    return
                }
                let id = UUID()
                self.mouseWaiters[id] = continuation
                self.hidQueue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    guard let self, let waiter = self.mouseWaiters.removeValue(forKey: id) else { return }
                    waiter.resume(throwing: HIDPPError.mouseNotFound)
                }
            }
        }
    }

    private func waitForKeyboard(timeoutSeconds: Double) async throws -> ManagedHIDDevice {
        try await withCheckedThrowingContinuation { continuation in
            hidQueue.async { [weak self] in
                guard let self, self.activeGeneration != nil else {
                    continuation.resume(throwing: HIDPPError.sessionStopped)
                    return
                }
                if let keyboard = self.keyboards.values.sorted(by: {
                    $0.descriptor.registryID < $1.descriptor.registryID
                }).first {
                    continuation.resume(returning: keyboard)
                    return
                }
                let id = UUID()
                self.keyboardWaiters[id] = continuation
                self.hidQueue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    guard let self, let waiter = self.keyboardWaiters.removeValue(forKey: id) else { return }
                    waiter.resume(throwing: HIDPPError.keyboardNotFound)
                }
            }
        }
    }

    private func locateKeyboard(timeoutSeconds: Double) async -> ManagedHIDLookup {
        do {
            return ManagedHIDLookup(
                device: try await waitForKeyboard(timeoutSeconds: timeoutSeconds),
                error: nil
            )
        } catch {
            return ManagedHIDLookup(device: nil, error: error.localizedDescription)
        }
    }

    private func locateMouse(timeoutSeconds: Double) async -> ManagedHIDLookup {
        do {
            return ManagedHIDLookup(
                device: try await waitForMouse(timeoutSeconds: timeoutSeconds),
                error: nil
            )
        } catch {
            return ManagedHIDLookup(device: nil, error: error.localizedDescription)
        }
    }

    private func switchError(
        lookup: ManagedHIDLookup,
        channel: Int,
        seize: Bool,
        stopAfterFirstSuccess: Bool
    ) async -> String? {
        guard let device = lookup.device else {
            return lookup.error ?? HIDPPError.sessionStopped.localizedDescription
        }
        if let hostInfo = device.hostInfo, channel >= hostInfo.hostCount {
            return HIDPPError.invalidHost(channel, hostInfo.hostCount).localizedDescription
        }
        guard HIDPPHostSwitchPolicy.requiresWrite(
            hostInfo: device.hostInfo,
            targetChannel: channel
        ) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            probeQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: HIDPPError.sessionStopped.localizedDescription)
                    return
                }
                do {
                    try self.sendHostSwitch(
                        device,
                        channel: channel,
                        seize: seize,
                        stopAfterFirstSuccess: stopAfterFirstSuccess
                    )
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    private func sendHostSwitch(
        _ managed: ManagedHIDDevice,
        channel: Int,
        seize: Bool,
        stopAfterFirstSuccess: Bool
    ) throws {
        let packet = HIDPPPacketCodec.setCurrentHost(
            featureIndex: managed.changeHostIndex,
            channel: UInt8(channel)
        )
        var seized = false
        var seizeResult = "disabled"
        if seize {
            let result = IOHIDDeviceOpen(managed.device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            seized = result == kIOReturnSuccess
            seizeResult = seized ? "success" : String(format: "best-effort failed 0x%08X", result)
        }
        defer {
            if seized {
                IOHIDDeviceClose(managed.device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            }
        }

        let summary = HIDPPWriteRetry.run(
            attempts: config.mouseSendCount,
            spacingMilliseconds: config.mouseSendSpacingMilliseconds,
            stopAfterFirstSuccess: stopAfterFirstSuccess
        ) {
            packet.withUnsafeBytes { buffer -> IOReturn in
                guard let baseAddress = buffer.baseAddress else { return kIOReturnBadArgument }
                return IOHIDDeviceSetReport(
                    managed.device,
                    kIOHIDReportTypeOutput,
                    CFIndex(packet[0]),
                    baseAddress,
                    packet.count
                )
            }
        }

        hidQueue.async { [weak self] in
            self?.diagnostics[managed.descriptor.registryID]?.seizeResult = seizeResult
        }
        guard summary.successes > 0 else {
            throw HIDPPError.writeFailed(summary.lastResult)
        }
    }

    private static func descriptor(for device: IOHIDDevice) -> HIDDescriptor {
        HIDDescriptor(
            registryID: registryID(for: device),
            vendorID: integerProperty(device, key: kIOHIDVendorIDKey as CFString),
            productID: integerProperty(device, key: kIOHIDProductIDKey as CFString),
            productName: stringProperty(device, key: kIOHIDProductKey as CFString),
            serialNumber: stringProperty(device, key: kIOHIDSerialNumberKey as CFString),
            transport: stringProperty(device, key: kIOHIDTransportKey as CFString),
            usagePage: integerProperty(device, key: kIOHIDPrimaryUsagePageKey as CFString),
            usage: integerProperty(device, key: kIOHIDPrimaryUsageKey as CFString)
        )
    }

    private static func registryID(for device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != MACH_PORT_NULL, IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS {
            return id
        }
        return UInt64(CFHash(device))
    }

    private static func integerProperty(_ device: IOHIDDevice, key: CFString) -> Int {
        (IOHIDDeviceGetProperty(device, key) as? NSNumber)?.intValue ?? 0
    }

    private static func stringProperty(_ device: IOHIDDevice, key: CFString) -> String {
        IOHIDDeviceGetProperty(device, key) as? String ?? ""
    }

    private static func describe(_ diagnostic: ProbeDiagnostic, verbose: Bool) -> String {
        let descriptor = diagnostic.descriptor
        let typeIndex = diagnostic.deviceTypeFeatureIndex.map { String(format: "0x%02X", $0) } ?? "—"
        let type = diagnostic.deviceType?.description ?? "unknown"
        let changeIndex = diagnostic.changeHostFeatureIndex.map { String(format: "0x%02X", $0) } ?? "—"
        let hosts = diagnostic.hostInfo.map { "\($0.currentHost + 1)/\($0.hostCount)" } ?? "—"
        let error = diagnostic.error.map { ", error=\($0)" } ?? ""
        let seize = diagnostic.seizeResult.map { ", seize=\($0)" } ?? ""
        let privateDetails = verbose
            ? String(format: " serial=%@ registry=0x%llX", descriptor.serialNumber.isEmpty ? "—" : descriptor.serialNumber, descriptor.registryID)
            : ""
        return String(
            format: "%@ pid=0x%04X transport=%@ usage=0x%04X/0x%04X selector=%@ 0x0005=%@ type=%@ 0x1814=%@ host=%@%@%@%@",
            descriptor.productName.isEmpty ? "(unnamed Logitech interface)" : descriptor.productName,
            descriptor.productID,
            descriptor.transport.isEmpty ? "unknown" : descriptor.transport,
            descriptor.usagePage,
            descriptor.usage,
            diagnostic.selector,
            typeIndex,
            type,
            changeIndex,
            hosts,
            seize,
            error,
            privateDetails
        )
    }
}

public enum HIDPPError: LocalizedError {
    case invalidChannel(Int)
    case invalidHost(Int, Int)
    case managerOpenFailed(IOReturn)
    case writeFailed(IOReturn)
    case responseTimedOut
    case malformedResponse
    case protocolError(UInt8)
    case deviceBusy
    case deviceRemoved
    case keyboardNotFound
    case mouseNotFound
    case sessionStopped
    case invalidDiscoveryTimeout

    public var errorDescription: String? {
        switch self {
        case .invalidChannel(let channel): return "Invalid Logitech channel \(channel)"
        case .invalidHost(let channel, let count): return "Host channel \(channel + 1) is outside the device's \(count) hosts"
        case .managerOpenFailed(let code): return String(format: "Cannot open IOHIDManager (0x%08X)", code)
        case .writeFailed(let code): return String(format: "HID++ write failed (0x%08X)", code)
        case .responseTimedOut: return "HID++ response timed out"
        case .malformedResponse: return "Malformed HID++ response"
        case .protocolError(let code): return String(format: "HID++ device returned error 0x%02X", code)
        case .deviceBusy: return "Another HID++ request is already pending for this interface"
        case .deviceRemoved: return "HID device disconnected"
        case .keyboardNotFound: return "Configured Pebble keyboard with dynamically resolved CHANGE_HOST was not found"
        case .mouseNotFound: return "Configured MX mouse with dynamically resolved CHANGE_HOST was not found"
        case .sessionStopped: return "HID session stopped"
        case .invalidDiscoveryTimeout: return "HID discovery must run for 0.5 to 10 seconds"
        }
    }
}

struct HIDPPWriteSummary: Equatable {
    var successes: Int
    var lastResult: IOReturn
    var attemptsMade: Int
}

enum HIDPPWriteRetry {
    static func run(
        attempts: Int,
        spacingMilliseconds: Int,
        stopAfterFirstSuccess: Bool,
        writer: () -> IOReturn
    ) -> HIDPPWriteSummary {
        let attemptCount = max(1, attempts)
        var successes = 0
        var lastResult: IOReturn = kIOReturnBadArgument
        var attemptsMade = 0

        for attempt in 0..<attemptCount {
            lastResult = writer()
            attemptsMade += 1
            if lastResult == kIOReturnSuccess {
                successes += 1
                if stopAfterFirstSuccess { break }
            }
            if attempt + 1 < attemptCount, spacingMilliseconds > 0 {
                Thread.sleep(forTimeInterval: Double(spacingMilliseconds) / 1_000)
            }
        }
        return HIDPPWriteSummary(
            successes: successes,
            lastResult: lastResult,
            attemptsMade: attemptsMade
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
