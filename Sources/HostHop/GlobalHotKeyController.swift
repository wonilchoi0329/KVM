import Carbon.HIToolbox
import Foundation

private let hostHopHotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID(signature: 0, id: 0)
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let controller = Unmanaged<GlobalHotKeyController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return controller.handle(hotKeyID)
}

final class GlobalHotKeyController {
    private static let signature: OSType = 0x48484F50 // "HHOP"

    private let onChannel: (Int) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []

    init(onChannel: @escaping (Int) -> Void) throws {
        self.onChannel = onChannel

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hostHopHotKeyCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            throw GlobalHotKeyError.installHandler(installStatus)
        }

        do {
            try register(keyCode: UInt32(kVK_F1), channel: 0)
            try register(keyCode: UInt32(kVK_F2), channel: 1)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    fileprivate func handle(_ hotKeyID: EventHotKeyID) -> OSStatus {
        guard hotKeyID.signature == Self.signature,
              (1...2).contains(hotKeyID.id),
              let channel = Int(exactly: hotKeyID.id - 1),
              (0...1).contains(channel) else {
            return OSStatus(eventNotHandledErr)
        }
        onChannel(channel)
        return noErr
    }

    private func register(keyCode: UInt32, channel: Int) throws {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: UInt32(channel + 1)
        )
        let status = RegisterEventHotKey(
            keyCode,
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr else {
            throw GlobalHotKeyError.register(channel: channel, status: status)
        }
        guard let reference else {
            throw GlobalHotKeyError.register(channel: channel, status: OSStatus(eventInternalErr))
        }
        hotKeys.append(reference)
    }

    func stop() {
        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        hotKeys.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

private enum GlobalHotKeyError: LocalizedError {
    case installHandler(OSStatus)
    case register(channel: Int, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .installHandler(let status):
            return "Cannot install the global hotkey handler (OSStatus \(status))"
        case .register(let channel, let status):
            return "Cannot register F\(channel + 1) as a global hotkey (OSStatus \(status))"
        }
    }
}
