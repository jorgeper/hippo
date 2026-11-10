import Foundation
import HippoTestSupport
@testable import HippoPresentation

@MainActor
final class FakeRecorder: AudioRecording {
    var startedURL: URL?
    var startCount = 0
    var stopCount = 0
    var currentTime: TimeInterval = 7.4
    var startError: Error?
    func start(writingTo url: URL) throws {
        if let startError { throw startError }
        startCount += 1
        startedURL = url
        try MediaMaker.writeAudio(to: url)
    }
    func stop() { stopCount += 1 }
}
