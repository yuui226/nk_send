import Foundation
import UIKit

/// The thumbnail decode post-processing used by Android's CameraViewModel.
///
/// Android removes camera-baked letterbox bars once, before the decoded image
/// enters the bitmap cache. iOS keeps the same boundary: this helper runs only
/// for GetThumb data, never for FHD/LargeThumb preview data or photo effects.
enum AndroidThumbnailProcessor {
    private static let blackPixelLimit: UInt8 = 32
    private static let maxBarFraction: CGFloat = 0.15
    private static let videoBandAverageLimit: UInt8 = 40

    static func process(_ data: Data, fileExtension: String) -> Data {
        guard let image = UIImage(data: data), let processed = process(image, fileExtension: fileExtension) else {
            return data
        }
        return processed.jpegData(compressionQuality: 0.94) ?? data
    }

    static func process(_ image: UIImage, fileExtension: String) -> UIImage? {
        guard let cgImage = image.cgImage,
              let pixels = RGBAImage(cgImage: cgImage),
              pixels.width >= 16, pixels.height >= 16 else { return nil }

        let fullRect = pixels.rect
        var output = cgImage
        var changed = false
        let letterbox = pixels.cropLetterboxRect()
        if letterbox != fullRect, let cropped = output.cropping(to: letterbox),
           let croppedPixels = RGBAImage(cgImage: cropped) {
            output = cropped
            changed = true
            if [".mov", ".mp4"].contains(fileExtension.lowercased()) {
                let videoRect = croppedPixels.cropVideoBarsRect()
                if videoRect != croppedPixels.rect, let video = output.cropping(to: videoRect) {
                    output = video
                }
            }
        } else if [".mov", ".mp4"].contains(fileExtension.lowercased()) {
            let videoRect = pixels.cropVideoBarsRect()
            if videoRect != fullRect, let cropped = output.cropping(to: videoRect) {
                output = cropped
                changed = true
            }
        }
        guard changed else { return image }
        return UIImage(cgImage: output, scale: image.scale, orientation: image.imageOrientation)
    }

    private struct RGBAImage {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: [UInt8]

        init?(cgImage: CGImage) {
            width = cgImage.width
            height = cgImage.height
            bytesPerRow = width * 4
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
            guard let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            data = bytes
        }

        var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = y * bytesPerRow + x * 4
            return (data[offset], data[offset + 1], data[offset + 2])
        }

        func lineIsBlack(_ index: Int, horizontal: Bool) -> Bool {
            let count = horizontal ? width : height
            var dark = 0
            var total = 0
            var cursor = 0
            while cursor < count {
                let rgb = horizontal ? pixel(cursor, index) : pixel(index, cursor)
                if rgb.0 < AndroidThumbnailProcessor.blackPixelLimit,
                   rgb.1 < AndroidThumbnailProcessor.blackPixelLimit,
                   rgb.2 < AndroidThumbnailProcessor.blackPixelLimit {
                    dark += 1
                }
                total += 1
                cursor += 2
            }
            return dark * 100 >= total * 97
        }

        func scanPair(size: Int, black: (Int) -> Bool) -> (Int, Int) {
            let limit = Int(CGFloat(size) * AndroidThumbnailProcessor.maxBarFraction)
            var leading = 0
            while leading < limit && black(leading) { leading += 1 }
            var trailing = 0
            while trailing < limit && black(size - 1 - trailing) { trailing += 1 }
            guard leading > 0, trailing > 0,
                  leading < limit, trailing < limit,
                  abs(leading - trailing) <= 3 else { return (0, 0) }
            return (leading + 1, trailing + 1)
        }

        func cropLetterboxRect() -> CGRect {
            let vertical = scanPair(size: height) { lineIsBlack($0, horizontal: true) }
            let horizontal = scanPair(size: width) { lineIsBlack($0, horizontal: false) }
            guard vertical.0 > 0 || horizontal.0 > 0 else { return rect }
            let x = horizontal.0
            let y = vertical.0
            let right = horizontal.1
            let bottom = vertical.1
            guard width - x - right > 0, height - y - bottom > 0 else { return rect }
            return CGRect(x: x, y: y, width: width - x - right, height: height - y - bottom)
        }

        func cropVideoBarsRect() -> CGRect {
            let cut = (height - width * 9 / 16) / 2
            guard cut >= 2, height - (cut + 1) * 2 >= 8 else { return rect }
            guard bandIsDark(y0: 0, y1: cut), bandIsDark(y0: height - cut, y1: height) else {
                return rect
            }
            let inset = cut + 1
            return CGRect(x: 0, y: inset, width: width, height: height - inset * 2)
        }

        func bandIsDark(y0: Int, y1: Int) -> Bool {
            var sum: UInt64 = 0
            var count: UInt64 = 0
            var y = y0
            while y < y1 {
                var x = 0
                while x < width {
                    let rgb = pixel(x, y)
                    sum += UInt64(max(rgb.0, max(rgb.1, rgb.2)))
                    count += 1
                    x += 2
                }
                y += 2
            }
            return count > 0 && sum < count * UInt64(AndroidThumbnailProcessor.videoBandAverageLimit)
        }
    }
}
