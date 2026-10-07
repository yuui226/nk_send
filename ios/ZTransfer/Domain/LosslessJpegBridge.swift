import Foundation

enum LosslessJpegBridge {
    static func crop(input: URL, output: URL, source: JpegCropSource, rect: CropRect) -> Bool {
        source.validate(rect)
        return input.path.withCString { inputPath in
            output.path.withCString { outputPath in
                zt_lossless_jpeg_crop(inputPath, outputPath, Int32(source.width), Int32(source.height), Int32(source.mcuWidth), Int32(source.mcuHeight), Int32(rect.left), Int32(rect.top), Int32(rect.width), Int32(rect.height)) != 0
            }
        }
    }
}

@_silgen_name("zt_lossless_jpeg_crop")
private func zt_lossless_jpeg_crop(_ input: UnsafePointer<CChar>, _ output: UnsafePointer<CChar>, _ width: Int32, _ height: Int32, _ mcuWidth: Int32, _ mcuHeight: Int32, _ x: Int32, _ y: Int32, _ cropWidth: Int32, _ cropHeight: Int32) -> Int32
