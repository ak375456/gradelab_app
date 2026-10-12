import AVFoundation
import XCTest
@testable import GradeLab

final class ExportStorageTests: XCTestCase {
    func testNearlyFullDeviceIsBlockedBeforeRenderingEvenForSmallExports() {
        XCTAssertNotNil(ExportStorage.issue(availableBytes: 13_299_712, estimatedBytes: 8_000_000))
        XCTAssertNotNil(ExportStorage.issue(availableBytes: 0, estimatedBytes: nil))
    }

    func testCapacityIncludesOutputAndWorkingHeadroom() {
        let required = ExportStorage.requiredBytes(estimatedBytes: 1_000_000_000)
        XCTAssertEqual(required, 1_264_000_000)
        XCTAssertNotNil(ExportStorage.issue(availableBytes: required - 1, estimatedBytes: 1_000_000_000))
        XCTAssertNil(ExportStorage.issue(availableBytes: required, estimatedBytes: 1_000_000_000))
        XCTAssertEqual(ExportStorage.requiredBytes(estimatedBytes: Int64.max), Int64.max)
    }

    func testUnknownCapacityDoesNotInventAStorageFailure() {
        XCTAssertNil(ExportStorage.issue(availableBytes: nil, estimatedBytes: 1_000_000_000))
    }

    func testWriterDiskFullErrorsAreRecognizedAcrossDomainsAndWrappers() {
        let diskErrors = [
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue),
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue))
        ]
        for error in diskErrors {
            XCTAssertTrue(ExportStorage.isOutOfSpace(error))
            let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
                                  userInfo: [NSUnderlyingErrorKey: error])
            XCTAssertTrue(ExportStorage.isOutOfSpace(wrapped))
        }
        XCTAssertFalse(ExportStorage.isOutOfSpace(nil))
        XCTAssertFalse(ExportStorage.isOutOfSpace(
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.encodeFailed.rawValue)))
    }
}
