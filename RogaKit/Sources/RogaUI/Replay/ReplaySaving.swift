import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// Saves a picture as a video or an image. It draws each frame on its own,
/// which works because a frame depends only on its time, so a saved video has
/// the same frames as the window and takes no longer than drawing them.
enum ReplaySaving {
    /// The size frames are laid out at, whatever size the window is.
    static let pictureSize = CGSize(width: 1280, height: 720)
    /// Drawn this much larger, which makes a video 1920 by 1080.
    static let videoScale = 1.5
    /// An image only has to be drawn once, so it can be sharper.
    static let imageScale = 2.0
    static let framesPerSecond = 60

    private struct Frame<Picture: ReplayPicture>: View {
        let picture: Picture
        let time: Double
        let colorScheme: ColorScheme

        var body: some View {
            Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                picture.draw(in: context, size: size, at: time, colorScheme: colorScheme)
            }
            .frame(width: pictureSize.width, height: pictureSize.height)
        }
    }

    private static func render<Picture: ReplayPicture>(
        _ picture: Picture,
        at time: Double,
        colorScheme: ColorScheme,
        scale: Double
    ) -> CGImage? {
        let renderer = ImageRenderer(content: Frame(picture: picture, time: time, colorScheme: colorScheme))
        renderer.scale = scale
        return renderer.cgImage
    }

    /// Saves the last frame as a PNG.
    static func writeImage<Picture: ReplayPicture>(of picture: Picture, colorScheme: ColorScheme, to url: URL) throws {
        guard let image = render(picture, at: picture.duration, colorScheme: colorScheme, scale: imageScale),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw SavingError.couldNotDraw }
        try data.write(to: url, options: .atomic)
    }

    /// Saves the whole picture as an MP4, at normal speed. A video that's
    /// cancelled or fails leaves no file behind.
    static func writeVideo<Picture: ReplayPicture>(
        of picture: Picture,
        colorScheme: ColorScheme,
        to url: URL,
        progress: (Double) -> Void
    ) async throws {
        let width = Int(pictureSize.width * videoScale)
        let height = Int(pictureSize.height * videoScale)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        writer.metadata = [try artwork(of: picture, colorScheme: colorScheme)]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SavingError.couldNotWrite }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int((picture.duration * Double(framesPerSecond)).rounded(.up)) + 1
        do {
            for frame in 0 ..< frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let time = min(picture.duration, Double(frame) / Double(framesPerSecond))
                guard let image = render(picture, at: time, colorScheme: colorScheme, scale: videoScale),
                      let pool = adaptor.pixelBufferPool,
                      let buffer = pixelBuffer(from: image, pool: pool)
                else { throw SavingError.couldNotDraw }
                let stamp = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond))
                guard adaptor.append(buffer, withPresentationTime: stamp) else {
                    throw writer.error ?? SavingError.couldNotWrite
                }
                progress(Double(frame + 1) / Double(frameCount))
                // Lets the progress bar and Cancel keep up.
                await Task.yield()
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SavingError.couldNotWrite }
    }

    /// The last frame as the video's cover, which is the picture Save Image
    /// writes. Finder and Quick Look show a video's cover in place of its
    /// first frame. Apps that make their own thumbnail from the frames don't
    /// read it, and show the title card the replay opens on.
    private static func artwork<Picture: ReplayPicture>(of picture: Picture, colorScheme: ColorScheme) throws -> AVMetadataItem {
        guard let image = render(picture, at: picture.duration, colorScheme: colorScheme, scale: videoScale),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { throw SavingError.couldNotDraw }
        let item = AVMutableMetadataItem()
        item.identifier = .iTunesMetadataCoverArt
        item.dataType = kCMMetadataBaseDataType_JPEG as String
        item.value = data as NSData
        return item
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return buffer
    }

    enum SavingError: LocalizedError {
        case couldNotDraw
        case couldNotWrite

        var errorDescription: String? {
            switch self {
            case .couldNotDraw: "Roga couldn't draw a frame of the replay."
            case .couldNotWrite: "Roga couldn't write the file."
            }
        }
    }
}
