import Foundation
import AVFoundation
import CoreMedia
import Speech
import os
import CaptureCore
import Enrichment

/// On-device transcription with `SpeechAnalyzer` + `SpeechTranscriber` (design §5.5). `SpeechTranscriber`
/// runs only on device, so nothing is ever sent to a server, and it needs no speech-recognition
/// authorization (that applies to `SFSpeechRecognizer` only). Returns only a complete transcript: no
/// volatile results are requested, and partial work is discarded on any error or cancellation.
/// Errors are `EnrichmentError` with fixed codes; text and file names are never logged.
struct SpeechTranscriberService: Transcribing {
    /// Matches `TranscriptEnricher.maxSeconds`. Checked here too, from the file itself, because the
    /// enricher only skips when the metadata carries a duration. Longer audio is skipped (design §5.5):
    /// it gets an empty transcript, which the enricher drops, so other attachments still transcribe.
    static let maxSeconds = 3600.0
    /// How long to wait before trying again while the model downloads.
    static let modelRetryAfter: TimeInterval = 900

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "enrichment")
    /// One model download request per process at a time.
    private static let installing = OSAllocatedUnfairLock(initialState: false)

    func transcribe(fileURL: URL, locale: Locale) async throws -> (text: String, segments: [TranscriptSegment]) {
        guard SpeechTranscriber.isAvailable else { throw EnrichmentError.permanent(code: "transcriber_unavailable") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw EnrichmentError.permanent(code: "unsupported_locale")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        try await ensureModel(for: transcriber, locale: supported)
        try Task.checkCancellation()

        let probe: AVAudioFile
        do { probe = try AVAudioFile(forReading: fileURL) } catch {
            throw EnrichmentError.permanent(code: "unreadable_audio")
        }
        let sampleRate = probe.fileFormat.sampleRate
        guard sampleRate > 0, probe.length > 0 else { throw EnrichmentError.permanent(code: "unreadable_audio") }
        if Double(probe.length) / sampleRate > Self.maxSeconds { return ("", []) }

        do {
            return try await analyze(fileURL, transcriber)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let speech = error as? SFSpeechError, speech.code == .assetLocaleNotAllocated {
                // Installed but not reserved for this app: reserve it so the retry can run.
                _ = try? await AssetInventory.reserve(locale: supported)
            }
            throw Self.map(error)
        }
    }

    // MARK: Model

    /// Throws `deferred(model_missing)` unless the model for `locale` is installed, after asking the
    /// system to download it.
    private func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let modules: [any SpeechModule] = [transcriber]
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .unsupported:
            throw EnrichmentError.permanent(code: "unsupported_locale")
        case .supported, .downloading:
            await Self.requestInstall(modules: modules, locale: locale)
            throw EnrichmentError.deferred(code: "model_missing", retryAfter: Self.modelRetryAfter)
        @unknown default:
            throw EnrichmentError.deferred(code: "model_missing", retryAfter: Self.modelRetryAfter)
        }
    }

    /// Starts the download in the background; the task retries after `modelRetryAfter`.
    private static func requestInstall(modules: [any SpeechModule], locale: Locale) async {
        let first = installing.withLock { busy -> Bool in
            defer { busy = true }
            return !busy
        }
        guard first else { return }
        do {
            _ = try? await AssetInventory.reserve(locale: locale)
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                installing.withLock { $0 = false }
                return
            }
            Task.detached(priority: .utility) {
                do { try await request.downloadAndInstall() } catch {
                    log.error("\("speech_model_install_failed", privacy: .public)")
                }
                installing.withLock { $0 = false }
            }
        } catch {
            log.error("\("speech_model_request_failed", privacy: .public)")
            installing.withLock { $0 = false }
        }
    }

    // MARK: Analysis

    /// Runs the whole file through the analyzer and collects the final results in order.
    private func analyze(_ fileURL: URL, _ transcriber: SpeechTranscriber) async throws
        -> (text: String, segments: [TranscriptSegment]) {
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse))
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [TranscriptSegment]?.self) { group in
                group.addTask {
                    var segments: [TranscriptSegment] = []
                    do {
                        for try await result in transcriber.results where result.isFinal {
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            segments.append(TranscriptSegment(start: Self.seconds(result.range.start),
                                                              end: Self.seconds(result.range.end), text: text))
                        }
                    } catch {
                        await analyzer.cancelAndFinishNow()   // stop the analysis child too
                        throw error
                    }
                    return segments
                }
                group.addTask {
                    do {
                        // Opened here so the (non-Sendable) file never leaves this task.
                        let file: AVAudioFile
                        do { file = try AVAudioFile(forReading: fileURL) } catch {
                            throw EnrichmentError.permanent(code: "unreadable_audio")
                        }
                        if let end = try await analyzer.analyzeSequence(from: file) {
                            try await analyzer.finalizeAndFinish(through: end)
                        } else {
                            await analyzer.cancelAndFinishNow()
                        }
                    } catch {
                        await analyzer.cancelAndFinishNow()   // ends the results sequence
                        throw error
                    }
                    return nil
                }
                var segments: [TranscriptSegment] = []
                for try await value in group {
                    if let value { segments = value }
                }
                try Task.checkCancellation()
                segments.sort { $0.start < $1.start }
                return (segments.map(\.text).joined(separator: " "), segments)
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func seconds(_ time: CMTime) -> Double {
        let s = time.seconds
        return s.isFinite && s >= 0 ? (s * 1000).rounded() / 1000 : 0
    }

    // MARK: Errors

    private static func map(_ error: Error) -> Error {
        if let e = error as? EnrichmentError { return e }
        if let speech = error as? SFSpeechError {
            switch speech.code {
            case .noModel, .assetLocaleNotAllocated:
                return EnrichmentError.deferred(code: "model_missing", retryAfter: modelRetryAfter)
            case .cannotAllocateUnsupportedLocale:
                return EnrichmentError.permanent(code: "unsupported_locale")
            case .incompatibleAudioFormats, .unexpectedAudioFormat, .audioDisordered:
                return EnrichmentError.permanent(code: "unsupported_audio")
            case .insufficientResources, .tooManyAssetLocalesAllocated:
                return EnrichmentError.transient(code: "speech_busy")
            default:
                break
            }
        }
        log.error("\("transcription_failed", privacy: .public)")
        return EnrichmentError.transient(code: "transcription_failed")
    }
}
