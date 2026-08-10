import XCTest
import AVFoundation
@testable import MeetingNoteTaker

final class PermissionManagerTests: XCTestCase {
    func testAuthorizedMapsToGranted() {
        XCTAssertEqual(PermissionManager.mapAuthorizationStatus(.authorized), .granted)
    }

    func testDeniedMapsToDenied() {
        XCTAssertEqual(PermissionManager.mapAuthorizationStatus(.denied), .denied)
    }

    func testRestrictedMapsToDenied() {
        XCTAssertEqual(PermissionManager.mapAuthorizationStatus(.restricted), .denied)
    }

    func testNotDeterminedMapsToNotDetermined() {
        XCTAssertEqual(PermissionManager.mapAuthorizationStatus(.notDetermined), .notDetermined)
    }
}
