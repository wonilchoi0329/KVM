import Darwin
import XCTest
@testable import HostHopCore

final class ConfigurationTests: XCTestCase {
    private func sample(monitor: LGDDCConfiguration? = nil) -> HostHopConfiguration {
        HostHopConfiguration(
            keyboard: HIDProductMatch(
                productID: 0xB377,
                productName: "Pebble K380s",
                serialNumber: "keyboard-serial",
                expectedType: .keyboard
            ),
            mouse: HIDProductMatch(
                productID: 0xB042,
                productName: "MX Master 4",
                serialNumber: "mouse-serial",
                expectedType: .mouse
            ),
            lgDDC: monitor
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testV2SupportsOnlyFirstTwoChannels() throws {
        let configuration = try sample().validated()
        XCTAssertTrue(configuration.supports(channel: 0))
        XCTAssertTrue(configuration.supports(channel: 1))
        XCTAssertFalse(configuration.supports(channel: 2))
        XCTAssertFalse(configuration.supports(channel: -1))
    }

    func testExactIdentityRequiresProductTransportAndOptionalSerial() {
        let enrolled = sample().keyboard
        XCTAssertTrue(enrolled.matches(
            vendorID: 0x046D,
            productID: 0xB377,
            serialNumber: "keyboard-serial",
            transport: "Bluetooth Low Energy"
        ))
        XCTAssertFalse(enrolled.matches(
            vendorID: 0x046D,
            productID: 0xB377,
            serialNumber: "spoof",
            transport: "Bluetooth Low Energy"
        ))
        XCTAssertFalse(enrolled.matches(
            vendorID: 0x046D,
            productID: 0xB377,
            serialNumber: "keyboard-serial",
            transport: "USB"
        ))
    }

    func testSecureRoundTripAndPermissions() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("config.plist")
        let store = ConfigurationStore(url: url)
        let expected = sample(monitor: LGDDCConfiguration(serialNumber: 123, chipAddress: 0x37))
        try store.save(expected)
        XCTAssertEqual(try store.load(), expected)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testSavePreservesExistingFileAsBackup() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.plist")
        let store = ConfigurationStore(url: url)
        let first = sample()
        var second = first
        second.debounceMilliseconds = 750
        try store.save(first)
        try store.save(second)

        XCTAssertEqual(try store.load(), second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupURL.path))
        XCTAssertEqual(try ConfigurationStore(url: store.backupURL).load(), first)
    }

    func testMissingConfigurationFailsInsteadOfCreatingDefaults() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.plist")
        XCTAssertThrowsError(try ConfigurationStore(url: url).load()) { error in
            guard case StoreError.missing = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testVersionOneRequiresFreshEnrollment() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.plist")
        var old = sample()
        old.version = 1
        let encoder = PropertyListEncoder()
        try encoder.encode(old).write(to: url)
        XCTAssertThrowsError(try ConfigurationStore(url: url).load()) { error in
            XCTAssertEqual(error as? ConfigurationError, .unsupportedVersion(1))
        }
    }

    func testRefusesSymlinkAndWritableByOthers() throws {
        let directory = try temporaryDirectory()
        let real = directory.appendingPathComponent("real.plist")
        let link = directory.appendingPathComponent("config.plist")
        try PropertyListEncoder().encode(sample()).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try ConfigurationStore(url: link).load())

        unlink(link.path)
        try FileManager.default.moveItem(at: real, to: link)
        XCTAssertEqual(chmod(link.path, 0o666), 0)
        XCTAssertThrowsError(try ConfigurationStore(url: link).load()) { error in
            guard case StoreError.unsafePath = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRefusesOversizedConfigurationBeforeDecode() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.plist")
        try Data(repeating: 0x41, count: ConfigurationStore.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try ConfigurationStore(url: url).load()) { error in
            guard case StoreError.fileTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRejectsInvalidDeviceAndMonitorConfiguration() {
        var invalid = sample()
        invalid.keyboard.transport = ""
        XCTAssertThrowsError(try invalid.validated()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidDevice)
        }

        invalid = sample(monitor: LGDDCConfiguration(serialNumber: 0, chipAddress: 0x51))
        XCTAssertThrowsError(try invalid.validated()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidLGDDC)
        }
    }
}
