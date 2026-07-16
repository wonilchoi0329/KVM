import Foundation
import HostHopDDC

public struct LGDDCSwitchOutcome: Equatable, Sendable {
    public var enabled: Bool
    public var acceptedWrites: Int
    public var error: String?
    public var chipAddress: Int

    public init(enabled: Bool, acceptedWrites: Int = 0, error: String? = nil, chipAddress: Int = 0) {
        self.enabled = enabled
        self.acceptedWrites = acceptedWrites
        self.error = error
        self.chipAddress = chipAddress
    }
}

public struct LGDDCDisplayCandidate: Equatable, Sendable {
    public var manufacturerID: Int
    public var productID: Int
    public var serialNumber: Int
    public var chipAddress: Int

    public var configuration: LGDDCConfiguration {
        LGDDCConfiguration(
            manufacturerID: manufacturerID,
            productID: productID,
            serialNumber: serialNumber,
            chipAddress: chipAddress
        )
    }
}

public enum LGDDCPacket {
    public static func bytes(inputValue: UInt8) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 6)
        packet.withUnsafeMutableBufferPointer { buffer in
            HostHopDDCBuildLGPacket(inputValue, buffer.baseAddress)
        }
        return packet
    }
}

public enum LGDDCDiscovery {
    public static func discover() throws -> [LGDDCDisplayCandidate] {
        var buffer = [HostHopDDCDisplayInfo](repeating: HostHopDDCDisplayInfo(), count: 8)
        var ioReturn: Int32 = 0
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            HostHopDDCDiscoverDisplays(
                UInt16(LGDDCConfiguration.supportedManufacturerID),
                UInt16(LGDDCConfiguration.supportedProductID),
                pointer.baseAddress,
                UInt32(pointer.count),
                &ioReturn
            )
        }
        guard count > 0 else {
            throw LGDDCError.noSupportedDisplay(ioReturn)
        }
        return buffer.prefix(min(Int(count), buffer.count)).map {
            LGDDCDisplayCandidate(
                manufacturerID: Int($0.manufacturerID),
                productID: Int($0.productID),
                serialNumber: Int($0.serialNumber),
                chipAddress: Int($0.chipAddress)
            )
        }
    }
}

public struct LGDDCController: Sendable {
    private static let inputValues: [UInt8] = [0x90, 0x91]
    private let configuration: LGDDCConfiguration?

    public init(configuration: LGDDCConfiguration?) {
        self.configuration = try? configuration?.validated()
    }

    public func switchInput(channel: Int) async -> LGDDCSwitchOutcome {
        guard let configuration else { return LGDDCSwitchOutcome(enabled: false) }
        guard Self.inputValues.indices.contains(channel) else {
            return LGDDCSwitchOutcome(enabled: true, error: "No LG input mapping for channel \(channel + 1)")
        }

        return await Task.detached(priority: .userInitiated) {
            let result = HostHopDDCSwitchLGInput(
                UInt16(configuration.manufacturerID),
                UInt16(configuration.productID),
                UInt32(configuration.serialNumber),
                Self.inputValues[channel],
                UInt8(configuration.chipAddress),
                2,
                20
            )
            return LGDDCSwitchOutcome(
                enabled: true,
                acceptedWrites: Int(result.acceptedWrites),
                error: Self.errorMessage(for: result),
                chipAddress: Int(result.chipAddress)
            )
        }.value
    }

    public func diagnose(verbose: Bool = false) async -> String {
        guard let configuration else { return "disabled (run `HostHop configure` to enroll a supported display)" }
        return await Task.detached(priority: .userInitiated) {
            let result = HostHopDDCProbeDisplay(
                UInt16(configuration.manufacturerID),
                UInt16(configuration.productID),
                UInt32(configuration.serialNumber),
                UInt8(configuration.chipAddress)
            )
            if let error = Self.errorMessage(for: result) { return "ERROR — \(error)" }
            let serial = verbose ? "; serial=\(configuration.serialNumber)" : ""
            return String(
                format: "ready — LG 0x%04X/0x%04X%@; alternate VCP 0xF4; I2C chip=0x%02X",
                configuration.manufacturerID,
                configuration.productID,
                serial,
                result.chipAddress
            )
        }.value
    }

    private static func errorMessage(for result: HostHopDDCResult) -> String? {
        let ioResult = String(format: "0x%08X", UInt32(bitPattern: result.ioReturn))
        switch Int(result.status) {
        case HostHopDDCStatusOK: return nil
        case HostHopDDCStatusNoProxy: return "No external display service (IOKit \(ioResult))"
        case HostHopDDCStatusDisplayNotFound: return "Enrolled LG EDID was not found or failed validation (IOKit \(ioResult))"
        case HostHopDDCStatusWriteFailed: return "LG alternate DDC write failed (IOKit \(ioResult))"
        case HostHopDDCStatusInvalidArgument: return "DDC request was outside the fixed supported command set"
        case HostHopDDCStatusUnavailable: return "Required macOS display API is unavailable (IOKit \(ioResult))"
        default: return "Unknown LG DDC error \(result.status) (IOKit \(ioResult))"
        }
    }
}

public enum LGDDCError: LocalizedError {
    case noSupportedDisplay(Int32)

    public var errorDescription: String? {
        switch self {
        case .noSupportedDisplay(let result):
            return String(format: "No supported LG display with a valid EDID was found (IOKit 0x%08X)", UInt32(bitPattern: result))
        }
    }
}
