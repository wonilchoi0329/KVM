import Darwin
import Foundation

public struct HIDProductMatch: Codable, Equatable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var productName: String
    public var serialNumber: String?
    public var transport: String
    public var expectedType: HIDPPDeviceType

    public init(
        vendorID: Int = 0x046D,
        productID: Int,
        productName: String,
        serialNumber: String? = nil,
        transport: String = "Bluetooth Low Energy",
        expectedType: HIDPPDeviceType
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.serialNumber = serialNumber?.nilIfEmpty
        self.transport = transport
        self.expectedType = expectedType
    }

    public func matches(
        vendorID candidateVendorID: Int,
        productID candidateProductID: Int,
        serialNumber candidateSerialNumber: String,
        transport candidateTransport: String
    ) -> Bool {
        guard vendorID == candidateVendorID,
              productID == candidateProductID,
              !transport.isEmpty,
              transport.caseInsensitiveCompare(candidateTransport) == .orderedSame else {
            return false
        }
        if let serialNumber {
            return serialNumber == candidateSerialNumber
        }
        return true
    }
}

public struct LGDDCConfiguration: Codable, Equatable, Sendable {
    public static let supportedManufacturerID = 0x1E6D
    public static let supportedProductID = 0x774F

    public var manufacturerID: Int
    public var productID: Int
    public var serialNumber: Int
    public var chipAddress: Int

    public init(
        manufacturerID: Int = supportedManufacturerID,
        productID: Int = supportedProductID,
        serialNumber: Int,
        chipAddress: Int
    ) {
        self.manufacturerID = manufacturerID
        self.productID = productID
        self.serialNumber = serialNumber
        self.chipAddress = chipAddress
    }

    public func validated() throws -> LGDDCConfiguration {
        guard manufacturerID == Self.supportedManufacturerID,
              productID == Self.supportedProductID,
              (1...Int(UInt32.max)).contains(serialNumber),
              [0x37, 0xB7].contains(chipAddress) else {
            throw ConfigurationError.invalidLGDDC
        }
        return self
    }
}

public struct HostHopConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var keyboard: HIDProductMatch
    public var mouse: HIDProductMatch
    public var debounceMilliseconds: Int
    public var mouseSendCount: Int
    public var mouseSendSpacingMilliseconds: Int
    public var seizeMouseForSwitch: Bool
    public var lgDDC: LGDDCConfiguration?

    public init(
        version: Int = currentVersion,
        keyboard: HIDProductMatch,
        mouse: HIDProductMatch,
        debounceMilliseconds: Int = 1_000,
        mouseSendCount: Int = 3,
        mouseSendSpacingMilliseconds: Int = 150,
        seizeMouseForSwitch: Bool = true,
        lgDDC: LGDDCConfiguration? = nil
    ) {
        self.version = version
        self.keyboard = keyboard
        self.mouse = mouse
        self.debounceMilliseconds = debounceMilliseconds
        self.mouseSendCount = mouseSendCount
        self.mouseSendSpacingMilliseconds = mouseSendSpacingMilliseconds
        self.seizeMouseForSwitch = seizeMouseForSwitch
        self.lgDDC = lgDDC
    }

    /// Used only by the explicit, bounded configuration discovery session.
    public static let discoveryConfiguration = HostHopConfiguration(
        keyboard: HIDProductMatch(
            productID: 0xB377,
            productName: "Pebble K380s",
            transport: "Bluetooth Low Energy",
            expectedType: .keyboard
        ),
        mouse: HIDProductMatch(
            productID: 0xB042,
            productName: "MX Master 4",
            transport: "Bluetooth Low Energy",
            expectedType: .mouse
        )
    )

    public func supports(channel: Int) -> Bool {
        (0...1).contains(channel)
    }

    public func validated() throws -> HostHopConfiguration {
        guard version == Self.currentVersion else {
            throw ConfigurationError.unsupportedVersion(version)
        }
        try Self.validateDevice(keyboard, expectedType: .keyboard)
        try Self.validateDevice(mouse, expectedType: .mouse)
        guard keyboard != mouse else { throw ConfigurationError.duplicateDevice }
        guard (100...60_000).contains(debounceMilliseconds),
              (1...5).contains(mouseSendCount),
              (0...1_000).contains(mouseSendSpacingMilliseconds) else {
            throw ConfigurationError.invalidTiming
        }
        if let lgDDC { _ = try lgDDC.validated() }
        return self
    }

    private static func validateDevice(
        _ device: HIDProductMatch,
        expectedType: HIDPPDeviceType
    ) throws {
        guard device.expectedType == expectedType,
              (1...0xFFFF).contains(device.vendorID),
              (1...0xFFFF).contains(device.productID),
              !device.productName.isEmpty,
              device.productName.utf8.count <= 256,
              !device.transport.isEmpty,
              device.transport.utf8.count <= 128,
              device.transport.localizedCaseInsensitiveContains("bluetooth"),
              (device.serialNumber?.utf8.count ?? 0) <= 256 else {
            throw ConfigurationError.invalidDevice
        }
    }
}

public enum ConfigurationError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidDevice
    case duplicateDevice
    case invalidTiming
    case invalidLGDDC

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Configuration version \(version) requires fresh enrollment with `HostHop configure`"
        case .invalidDevice: return "Invalid or incomplete enrolled HID device"
        case .duplicateDevice: return "Keyboard and mouse identities must be different"
        case .invalidTiming: return "Invalid debounce or mouse retry timing"
        case .invalidLGDDC: return "Monitor is not a supported, safely calibrated LG display"
        }
    }
}

public struct ConfigurationStore: Sendable {
    public static let maximumBytes = 64 * 1_024

    public let url: URL

    public init() {
        self.url = Self.defaultURL
    }

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HostHop", isDirectory: true)
            .appendingPathComponent("config.plist", isDirectory: false)
    }

    public var backupURL: URL {
        url.deletingPathExtension().appendingPathExtension("plist.backup")
    }

    public func load() throws -> HostHopConfiguration {
        let data = try readSecureFile(at: url)
        do {
            return try PropertyListDecoder()
                .decode(HostHopConfiguration.self, from: data)
                .validated()
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw StoreError.cannotLoad(url, error.localizedDescription)
        }
    }

    public func save(_ configuration: HostHopConfiguration, preserveExisting: Bool = true) throws {
        let validated = try configuration.validated()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data: Data
        do {
            data = try encoder.encode(validated)
        } catch {
            throw StoreError.cannotSave(url, error.localizedDescription)
        }
        guard data.count <= Self.maximumBytes else { throw StoreError.fileTooLarge(url) }

        let directory = url.deletingLastPathComponent()
        try secureDirectory(directory)
        if preserveExisting, FileManager.default.fileExists(atPath: url.path) {
            let existing = try readSecureFile(at: url)
            try writeSecureFile(existing, to: backupURL)
        }
        try writeSecureFile(data, to: url)
    }

    private func secureDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StoreError.cannotSave(url, error.localizedDescription)
        }

        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw StoreError.unsafePath(directory)
        }
        guard chmod(directory.path, 0o700) == 0 else {
            throw StoreError.cannotSave(url, String(cString: strerror(errno)))
        }
    }

    private func readSecureFile(at sourceURL: URL) throws -> Data {
        let descriptor = open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw StoreError.missing(sourceURL) }
            throw StoreError.cannotLoad(sourceURL, String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw StoreError.cannotLoad(sourceURL, String(cString: strerror(errno)))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & 0o022) == 0 else {
            throw StoreError.unsafePath(sourceURL)
        }
        guard info.st_size >= 0, info.st_size <= Self.maximumBytes else {
            throw StoreError.fileTooLarge(sourceURL)
        }

        var data = Data(count: Int(info.st_size))
        let bytesRead = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.cannotLoad(sourceURL, String(cString: strerror(errno)))
                }
                if count == 0 { break }
                offset += count
            }
            return offset
        }
        guard bytesRead == data.count else {
            throw StoreError.cannotLoad(sourceURL, "File changed while it was being read")
        }
        return data
    }

    private func writeSecureFile(_ data: Data, to destinationURL: URL) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw StoreError.cannotSave(destinationURL, String(cString: strerror(errno)))
        }
        var shouldUnlink = true
        defer {
            close(descriptor)
            if shouldUnlink { unlink(temporaryURL.path) }
        }

        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw StoreError.cannotSave(destinationURL, String(cString: strerror(errno)))
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw StoreError.cannotSave(destinationURL, String(cString: strerror(errno)))
            }
            guard rename(temporaryURL.path, destinationURL.path) == 0 else {
                throw StoreError.cannotSave(destinationURL, String(cString: strerror(errno)))
            }
            shouldUnlink = false
        } catch {
            throw error
        }
    }
}

public enum StoreError: LocalizedError {
    case missing(URL)
    case unsafePath(URL)
    case fileTooLarge(URL)
    case cannotLoad(URL, String)
    case cannotSave(URL, String)

    public var errorDescription: String? {
        switch self {
        case .missing(let url): return "No configuration at \(url.path); run `HostHop configure`"
        case .unsafePath(let url): return "Refusing unsafe configuration path: \(url.path)"
        case .fileTooLarge(let url): return "Configuration exceeds the 64 KiB limit: \(url.path)"
        case .cannotLoad(let url, let reason): return "Cannot load \(url.path): \(reason)"
        case .cannotSave(let url, let reason): return "Cannot save \(url.path): \(reason)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
