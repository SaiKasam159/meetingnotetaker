import XCTest
@testable import MeetingNoteTaker

final class StorageLocationTests: XCTestCase {
    func testParsesFileVaultOn() {
        XCTAssertTrue(StorageLocation.parseFileVaultStatus("FileVault is On.\n"))
    }

    func testParsesFileVaultOff() {
        XCTAssertFalse(StorageLocation.parseFileVaultStatus("FileVault is Off.\n"))
    }

    func testUnexpectedOutputFailsClosed() {
        XCTAssertFalse(StorageLocation.parseFileVaultStatus(""))
        XCTAssertFalse(StorageLocation.parseFileVaultStatus("some unexpected future macOS output"))
    }
}
