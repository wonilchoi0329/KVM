import XCTest
import IOKit
@testable import HostHopCore

final class HIDPPTests: XCTestCase {
    func testRootFeatureLookupIsLongReportAndDoesNotHardcodeIndex() {
        let packet = HIDPPPacketCodec.rootGetFeature(0x1814)

        XCTAssertEqual(packet.count, 20)
        XCTAssertEqual(Array(packet.prefix(7)), [0x11, 0xFF, 0x00, 0x0B, 0x18, 0x14, 0x00])
        XCTAssertEqual(Array(packet.dropFirst(7)), [UInt8](repeating: 0, count: 13))
    }

    func testDecodesFeatureIndexFromRootResponse() {
        var response = [UInt8](repeating: 0, count: 20)
        response.replaceSubrange(0..<7, with: [0x11, 0xFF, 0x00, 0x0B, 0x2A, 0x01, 0x03])

        XCTAssertEqual(
            HIDPPPacketCodec.decodeFeatureResolution(response),
            HIDPPFeatureResolution(index: 0x2A, typeFlags: 0x01, version: 0x03)
        )
    }

    func testBuildsDeviceTypeAndSetCurrentHostRequests() {
        XCTAssertEqual(
            Array(HIDPPPacketCodec.deviceType(featureIndex: 0x07).prefix(6)),
            [0x11, 0xFF, 0x07, 0x2B, 0x00, 0x00]
        )
        XCTAssertEqual(
            Array(HIDPPPacketCodec.setCurrentHost(featureIndex: 0x2A, channel: 1).prefix(7)),
            [0x11, 0xFF, 0x2A, 0x1B, 0x01, 0x00, 0x00]
        )
    }

    func testDecodesKnownDeviceTypes() {
        for (raw, expected) in [
            (UInt8(0), HIDPPDeviceType.keyboard),
            (UInt8(3), HIDPPDeviceType.mouse),
            (UInt8(4), HIDPPDeviceType.trackpad),
            (UInt8(5), HIDPPDeviceType.trackball),
        ] {
            var response = [UInt8](repeating: 0, count: 20)
            response.replaceSubrange(0..<5, with: [0x11, 0xFF, 0x07, 0x2B, raw])
            XCTAssertEqual(HIDPPPacketCodec.decodeDeviceType(response, featureIndex: 0x07), expected)
        }
    }

    func testEasySwitchNotificationUsesByteFiveAndValidatesHostCount() {
        var notification = [UInt8](repeating: 0, count: 20)
        notification.replaceSubrange(0..<7, with: [0x11, 0xFF, 0x2A, 0x00, 0x03, 0x01, 0x00])

        XCTAssertEqual(
            HIDPPPacketCodec.decodeChangeHostNotification(notification, featureIndex: 0x2A),
            1
        )

        notification[5] = 3
        XCTAssertNil(HIDPPPacketCodec.decodeChangeHostNotification(notification, featureIndex: 0x2A))
        notification[5] = 1
        notification[3] = 0x0B
        XCTAssertNil(HIDPPPacketCodec.decodeChangeHostNotification(notification, featureIndex: 0x2A))
    }

    func testRejectsNotificationForDifferentRuntimeFeatureIndex() {
        var notification = [UInt8](repeating: 0, count: 20)
        notification.replaceSubrange(0..<6, with: [0x11, 0xFF, 0x09, 0x00, 0x03, 0x00])

        XCTAssertNil(HIDPPPacketCodec.decodeChangeHostNotification(notification, featureIndex: 0x2A))
    }

    func testMatchesHIDPP20ErrorToOriginalRequest() {
        let request = HIDPPPacketCodec.setCurrentHost(featureIndex: 0x2A, channel: 1)
        var error = [UInt8](repeating: 0, count: 20)
        error.replaceSubrange(0..<7, with: [0x11, 0xFF, 0xFF, 0x2A, 0x1B, 0x08, 0x00])

        XCTAssertTrue(HIDPPPacketCodec.isResponse(error, to: request))
        XCTAssertEqual(HIDPPPacketCodec.errorCode(error, matching: request), 0x08)
    }

    func testPacketDecoderRejectsTruncatedLongReport() {
        XCTAssertThrowsError(try HIDPPPacketCodec.decode([0x11, 0xFF, 0x00])) { error in
            XCTAssertEqual(error as? HIDPPCodecError, .invalidLength(expected: 20, actual: 3))
        }
    }

    func testKeyboardWriteRetriesFailuresAndStopsAfterFirstAcceptedWrite() {
        var results: [IOReturn] = [kIOReturnNotReady, kIOReturnSuccess, kIOReturnNoDevice]
        let summary = HIDPPWriteRetry.run(
            attempts: 3,
            spacingMilliseconds: 0,
            stopAfterFirstSuccess: true
        ) {
            results.removeFirst()
        }

        XCTAssertEqual(
            summary,
            HIDPPWriteSummary(successes: 1, lastResult: kIOReturnSuccess, attemptsMade: 2)
        )
        XCTAssertEqual(results, [kIOReturnNoDevice])
    }

    func testMouseWriteContinuesAfterSuccessAndAcceptsExpectedDisconnects() {
        var results: [IOReturn] = [kIOReturnSuccess, kIOReturnNoDevice, kIOReturnNoDevice]
        let summary = HIDPPWriteRetry.run(
            attempts: 3,
            spacingMilliseconds: 0,
            stopAfterFirstSuccess: false
        ) {
            results.removeFirst()
        }

        XCTAssertEqual(summary.successes, 1)
        XCTAssertEqual(summary.lastResult, kIOReturnNoDevice)
        XCTAssertEqual(summary.attemptsMade, 3)
    }

    func testWriteRetryReportsLastFailureWhenNoWriteIsAccepted() {
        var results: [IOReturn] = [kIOReturnNotReady, kIOReturnNoDevice]
        let summary = HIDPPWriteRetry.run(
            attempts: 2,
            spacingMilliseconds: 0,
            stopAfterFirstSuccess: true
        ) {
            results.removeFirst()
        }

        XCTAssertEqual(summary.successes, 0)
        XCTAssertEqual(summary.lastResult, kIOReturnNoDevice)
        XCTAssertEqual(summary.attemptsMade, 2)
    }

    func testCombinedSwitchOutcomeRequiresBothPeripherals() {
        XCTAssertTrue(HIDPPSwitchOutcome().succeeded)
        XCTAssertFalse(HIDPPSwitchOutcome(keyboardError: "missing").succeeded)
        XCTAssertFalse(HIDPPSwitchOutcome(mouseError: "missing").succeeded)
    }

    func testHostSwitchPolicySkipsNoOpAndWritesUnknownOrDifferentHost() {
        let hostInfo = HIDPPHostInfo(hostCount: 3, currentHost: 0, capabilities: 0)

        XCTAssertFalse(HIDPPHostSwitchPolicy.requiresWrite(hostInfo: hostInfo, targetChannel: 0))
        XCTAssertTrue(HIDPPHostSwitchPolicy.requiresWrite(hostInfo: hostInfo, targetChannel: 1))
        XCTAssertTrue(HIDPPHostSwitchPolicy.requiresWrite(hostInfo: nil, targetChannel: 0))
    }
}
