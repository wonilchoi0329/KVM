import HostHopDDC
import XCTest
@testable import HostHopCore

final class LGDDCTests: XCTestCase {
    func testBuildsOnlyCalibratedLGAlternatePackets() {
        XCTAssertEqual(LGDDCPacket.bytes(inputValue: 0x90), [0x84, 0x03, 0xF4, 0x00, 0x90, 0xDD])
        XCTAssertEqual(LGDDCPacket.bytes(inputValue: 0x91), [0x84, 0x03, 0xF4, 0x00, 0x91, 0xDC])
    }

    func testSelectsMCDPChipAddressForM1ProPath() {
        let m1Path = "IOService:/AppleARMPE/arm-io/AppleT600xIO/dcpext0@89C00000/DCPAVServiceProxy"
        XCTAssertEqual(HostHopDDCResolveChipAddress(m1Path, 0), 0xB7)
        XCTAssertEqual(HostHopDDCResolveChipAddress("IOService:/modern/DCPAVServiceProxy", 0), 0x37)
        XCTAssertEqual(HostHopDDCResolveChipAddress(m1Path, 0x37), 0x37)
    }

    func testEDIDValidationRequiresHeaderChecksumAndExactIdentity() {
        var edid = [UInt8](repeating: 0, count: 128)
        edid.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        edid[8] = 0x1E
        edid[9] = 0x6D
        edid[10] = 0x4F
        edid[11] = 0x77
        edid[12] = 0x7B
        edid[127] = UInt8(0 &- edid.dropLast().reduce(0, &+))

        XCTAssertEqual(edid.withUnsafeBufferPointer {
            HostHopDDCValidateEDID($0.baseAddress, UInt32($0.count), 0x1E6D, 0x774F, 123)
        }, 1)
        edid[20] ^= 0x01
        XCTAssertEqual(edid.withUnsafeBufferPointer {
            HostHopDDCValidateEDID($0.baseAddress, UInt32($0.count), 0x1E6D, 0x774F, 123)
        }, 0)
        edid[20] ^= 0x01
        edid[0] = 0x01
        edid[127] &-= 0x01
        XCTAssertEqual(edid.withUnsafeBufferPointer {
            HostHopDDCValidateEDID($0.baseAddress, UInt32($0.count), 0x1E6D, 0x774F, 123)
        }, 0)
    }

    func testAcceptsOnlySupportedLGIdentityAndKnownChipAddresses() throws {
        XCTAssertNoThrow(try LGDDCConfiguration(serialNumber: 123, chipAddress: 0x37).validated())
        XCTAssertNoThrow(try LGDDCConfiguration(serialNumber: 123, chipAddress: 0xB7).validated())
        XCTAssertThrowsError(try LGDDCConfiguration(serialNumber: 0, chipAddress: 0x37).validated())
        XCTAssertThrowsError(try LGDDCConfiguration(serialNumber: 123, chipAddress: 0x51).validated())
        XCTAssertThrowsError(try LGDDCConfiguration(manufacturerID: 1, productID: 2, serialNumber: 123, chipAddress: 0x37).validated())
    }

    func testDisabledControllerDoesNotAttemptDDC() async {
        let outcome = await LGDDCController(configuration: nil).switchInput(channel: 0)
        XCTAssertFalse(outcome.enabled)
        XCTAssertEqual(outcome.acceptedWrites, 0)
        XCTAssertNil(outcome.error)
    }

    func testInvalidChannelFailsWithoutCallingDDC() async {
        let configuration = LGDDCConfiguration(serialNumber: 123, chipAddress: 0x37)
        let outcome = await LGDDCController(configuration: configuration).switchInput(channel: 2)
        XCTAssertTrue(outcome.enabled)
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.acceptedWrites, 0)
    }
}
