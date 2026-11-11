import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreVideo
import CoreGraphics
import CoreImage

/// Generates small media files for tests and fixtures. Self-contained: no test-framework imports.
public enum MediaMaker {
    public struct ImageOptions {
        public var exifDateTimeOriginal: String? = nil      // "2026:11:07 09:11:00"
        public var exifOffsetTimeOriginal: String? = nil    // "-08:00"
        public var gpsLatitude: Double? = nil               // signed
        public var gpsLongitude: Double? = nil              // signed
        public var gpsAltitude: Double? = nil               // signed; negative = below sea level
        public var make: String? = nil
        public var model: String? = nil
        public init() {}
    }

    public struct MakerError: Error { public let message: String }

    public static func imageData(width: Int, height: Int, type: UTType = .jpeg, options: ImageOptions = .init()) throws -> Data {
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
    public static func writeAudio(to url: URL) throws {
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
    public static func writeVideo(to url: URL, width: Int = 64, height: Int = 48) async throws {
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

    /// A one-page blank PDF.
    public static func pdfData() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw MakerError(message: "pdf context")
        }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// A PNG of a QR code for `payload`, black on white, centred on a white canvas. No metadata, so the same
    /// inputs give the same bytes.
    public static func qrCodePNG(payload: String, canvasWidth: Int, canvasHeight: Int, module: Int = 8) throws -> Data {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw MakerError(message: "qr filter") }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { throw MakerError(message: "qr output") }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let code = context.createCGImage(output, from: output.extent) else { throw MakerError(message: "qr image") }
        let side = code.width * module
        guard let ctx = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw MakerError(message: "qr context")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        ctx.interpolationQuality = .none
        ctx.draw(code, in: CGRect(x: (canvasWidth - side) / 2, y: (canvasHeight - side) / 2, width: side, height: side))
        guard let image = ctx.makeImage() else { throw MakerError(message: "qr canvas") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw MakerError(message: "qr destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw MakerError(message: "qr finalize") }
        return data as Data
    }
}
