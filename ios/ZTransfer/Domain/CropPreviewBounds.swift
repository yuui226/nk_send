import CoreGraphics

func cropPreviewBounds(width: Int, height: Int, pixel: (Int, Int) -> CGColor) -> CropRect {
    func blackLine(_ index: Int, horizontal: Bool) -> Bool {
        let length = horizontal ? width : height; var dark = 0; var total = 0
        for i in stride(from: 0, to: length, by: max(1, length / 96)) {
            let c = pixel(horizontal ? i : index, horizontal ? index : i)
            let comps = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [1,1,1]
            if comps.prefix(3).allSatisfy({ $0 * 255 <= 12 }) { dark += 1 }; total += 1
        }
        return dark * 100 >= total * 98
    }
    func padding(_ length: Int, horizontal: Bool) -> Int {
        let limit = Int(Double(length) * 0.4); var a = 0; var b = 0
        while a < limit && blackLine(a, horizontal: horizontal) { a += 1 }
        while b < limit && blackLine(length - 1 - b, horizontal: horizontal) { b += 1 }
        return a >= 2 && b >= 2 && a < limit && b < limit && abs(a-b) <= 2 ? min(a,b) : 0
    }
    let x = padding(width, horizontal: false), y = padding(height, horizontal: true)
    return CropRect(left: x, top: y, right: width-x, bottom: height-y)
}
