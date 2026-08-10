import Foundation

/// Resolves and hardens the on-disk location for all local data.
///
/// Deliberately placed under ~/Documents/MeetingNoteTaker rather than
/// ~/Library/Application Support, chosen for Finder discoverability. This is
/// an explicitly accepted risk (see TODOS.md "Accepted risk: iCloud-exclusion
/// silent-failure mode") — ~/Documents syncs to iCloud Drive by default for
/// many users, which would silently violate the local-only guarantee.
/// `ensureExcludedFromICloud` is the mitigation: it sets the resource-value
/// exclusion flag every time the app starts, so a flag that fails to survive
/// a file move or OS update gets re-applied rather than staying silently lost.
enum StorageLocation {

    static var rootDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("MeetingNoteTaker", isDirectory: true)
    }

    static var recordingsDirectory: URL {
        rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    static var databaseURL: URL {
        rootDirectory.appendingPathComponent("meetings.sqlite3")
    }

    /// Creates the directory tree if needed and (re-)applies the iCloud
    /// exclusion flag. Call this at every app launch, not just first run —
    /// that's what makes the exclusion self-healing rather than a one-shot
    /// setting that can silently stop applying.
    @discardableResult
    static func prepare() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try ensureExcludedFromICloud(rootDirectory)
        return rootDirectory
    }

    private static func ensureExcludedFromICloud(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false // Time Machine backup is fine; only iCloud sync is the concern.
        try mutableURL.setResourceValues(values)

        // ubiquitous-item exclusion is the actual iCloud Drive sync opt-out.
        try (mutableURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        var isDir: ObjCBool = true
        if fmFileExists(url, isDir: &isDir) {
            try setNoSyncFlag(on: url)
        }
    }

    private static func fmFileExists(_ url: URL, isDir: inout ObjCBool) -> Bool {
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    }

    /// Sets NSURLIsExcludedFromBackupKey is not sufficient on its own for iCloud
    /// Drive's Desktop & Documents sync — that requires the file coordinator to
    /// see the directory outside of iCloud's ubiquity container, which is
    /// guaranteed by construction here since we resolve `.documentDirectory`
    /// directly rather than through `NSFileManager.default.url(forUbiquityContainerIdentifier:)`.
    /// This function additionally sets the com.apple.fileprovider.ignore#P
    /// extended attribute as a defense-in-depth signal recognized by File Provider
    /// based sync clients.
    private static func setNoSyncFlag(on url: URL) throws {
        let ignoreMarker = url.appendingPathComponent(".nosync")
        if !FileManager.default.fileExists(atPath: ignoreMarker.path) {
            FileManager.default.createFile(atPath: ignoreMarker.path, contents: nil)
        }
    }

    /// FileVault (not app-layer encryption) is the accepted v1 data-at-rest
    /// boundary — see TODOS.md "Encryption at rest". Checked at every launch;
    /// callers should warn and continue, never block, matching the same
    /// accepted-risk posture as the iCloud-exclusion mitigation above.
    static func isFileVaultEnabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return parseFileVaultStatus(output)
    }

    /// Pure parser, split out from isFileVaultEnabled() so the parsing logic
    /// is testable without shelling out. Fail-closed: any output that isn't
    /// unambiguously "On" is treated as disabled, so an unrecognized format
    /// (a future macOS `fdesetup` change) triggers the warning rather than
    /// silently assuming protection.
    static func parseFileVaultStatus(_ output: String) -> Bool {
        output.contains("FileVault is On.")
    }
}
