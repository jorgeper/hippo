import Foundation
import Photos
import LocalRepository

/// Adds a saved camera file to the Photos library ("Also save to Photos"). Add-only access; the
/// permission prompt comes with the first save. Never throws and never shows anything: the capture is
/// already saved, so the outcome is only logged.
enum PhotoLibrarySaver {
    static func save(fileURL: URL, isVideo: Bool, captureID: String, log: ActivityLog) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            log.append(LogEvent(event: .cameraLibrarySave, captureID: captureID, outcome: .failed, code: "denied"))
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: fileURL, options: nil)
            }
            log.append(LogEvent(event: .cameraLibrarySave, captureID: captureID, outcome: .ok))
        } catch {
            log.append(LogEvent(event: .cameraLibrarySave, captureID: captureID, outcome: .failed, code: "failed"))
        }
    }
}
