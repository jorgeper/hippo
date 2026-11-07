import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreVideo

/// Generates small media files for tests and fixtures. Self-contained: no test-framework imports.
enum MediaMaker {
    struct ImageOptions {
        var exifDateTimeOriginal: String? = nil      // "2026:11:07 09:11:00"
        var exifOffsetTimeOriginal: String? = nil    // "-08:00"
        var gpsLatitude: Double? = nil               // signed
        var gpsLongitude: Double? = nil              // signed
        var gpsAltitude: Double? = nil               // signed; negative = below sea level
        var make: String? = nil
        var model: String? = nil
    }

    struct MakerError: Error { let message: String }

    static func imageData(width: Int, height: Int, type: UTType = .jpeg, options: ImageOptions = .init()) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MakerError(message: "context")
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw MakerError(message: "image") }

        var props: [CFString: Any] = [:]
        var exif: [CFString: Any] = [:]
        if let v = options.exifDateTimeOriginal { exif[kCGImagePropertyExifDateTimeOriginal] = v }
        if let v = options.exifOffsetTimeOriginal { exif[kCGImagePropertyExifOffsetTimeOriginal] = v }
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
        var tiff: [CFString: Any] = [:]
        if let v = options.make { tiff[kCGImagePropertyTIFFMake] = v }
        if let v = options.model { tiff[kCGImagePropertyTIFFModel] = v }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary] = tiff }
        var gps: [CFString: Any] = [:]
        if let lat = options.gpsLatitude {
            gps[kCGImagePropertyGPSLatitude] = abs(lat)
            gps[kCGImagePropertyGPSLatitudeRef] = lat < 0 ? "S" : "N"
        }
        if let lon = options.gpsLongitude {
            gps[kCGImagePropertyGPSLongitude] = abs(lon)
            gps[kCGImagePropertyGPSLongitudeRef] = lon < 0 ? "W" : "E"
        }
        if let alt = options.gpsAltitude {
            gps[kCGImagePropertyGPSAltitude] = abs(alt)
            gps[kCGImagePropertyGPSAltitudeRef] = alt < 0 ? 1 : 0
        }
        if !gps.isEmpty { props[kCGImagePropertyGPSDictionary] = gps }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw MakerError(message: "destination")
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MakerError(message: "finalize") }
        return data as Data
    }

    /// 1 s of silence, AAC, 44.1 kHz mono, in an .m4a container.
    static func writeAudio(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) else {
            throw MakerError(message: "audio buffer")
        }
        buffer.frameLength = 44100
        if let p = buffer.floatChannelData?[0] { p.update(repeating: 0, count: 44100) }
        try file.write(from: buffer)
    }

    /// 1 s H.264 .mov (30 frames at 30 fps), solid color. Uses the macOS 27 input-receiver API
    /// (the AVAssetWriterInputPixelBufferAdaptor path is deprecated there).
    static func writeVideo(to url: URL, width: Int = 64, height: Int = 48) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: width, height: height))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<30 {
            var buffer = try CVMutablePixelBuffer(attributes)
            buffer.accessUnsafeMutableRawPlaneBytes { planes in
                for plane in planes { memset(plane.bytes.baseAddress!, Int32(0x80 + frame), plane.bytes.count) }
            }
            try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        receiver.finish()
        await writer.finishWriting()
        guard writer.status == .completed else { throw MakerError(message: "finish: \(String(describing: writer.error))") }
    }
}
