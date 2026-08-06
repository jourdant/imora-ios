import Foundation

/// Interprets the server's response independently of URLSession teardown. Once
/// Immich returned 2xx, the asset was accepted even if the background session
/// also reports a transport error while disconnecting the task.
nonisolated enum ShareUploadOutcome {
    static func succeeded(statusCode: Int) -> Bool {
        (200..<300).contains(statusCode)
    }
}
