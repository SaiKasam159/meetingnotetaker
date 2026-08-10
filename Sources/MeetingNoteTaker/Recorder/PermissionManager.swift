import Foundation
import ScreenCaptureKit
import AVFoundation

enum RecordingPermissionStatus {
    case granted
    case denied
    case notDetermined
}

/// Wraps the TCC-gated "Screen & System Audio Recording" permission that
/// ScreenCaptureKit requires, plus the separate microphone permission.
/// There is no code-signing entitlement for screen/system-audio capture —
/// it is granted purely through System Settings, so this must be checked
/// before every recording attempt rather than assumed from a prior grant.
struct PermissionManager {

    /// Checks system-audio/screen-recording permission by attempting to fetch
    /// shareable content. SCShareableContent.current throws if permission is
    /// not granted, which is the only reliable way to probe this TCC gate.
    static func checkSystemAudioPermission() async -> RecordingPermissionStatus {
        do {
            _ = try await SCShareableContent.current
            return .granted
        } catch {
            return .denied
        }
    }

    static func checkMicrophonePermission() -> RecordingPermissionStatus {
        mapAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Pure mapping, split out from checkMicrophonePermission() so the
    /// branching is directly unit-testable without a real TCC prompt.
    static func mapAuthorizationStatus(_ status: AVAuthorizationStatus) -> RecordingPermissionStatus {
        switch status {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Opens the exact System Settings pane the user needs for system-audio
    /// recording permission. Screen recording permission cannot be requested
    /// programmatically (unlike microphone) — the user must grant it manually
    /// in System Settings, then relaunch the app.
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
