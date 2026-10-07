import Foundation

struct CropRect: Codable, Equatable, Sendable {
    let left: Int; let top: Int; let right: Int; let bottom: Int
    var width: Int { right - left }; var height: Int { bottom - top }
}
struct CropPoint: Codable, Equatable, Sendable { let x: Double; let y: Double }
struct CropBounds: Codable, Equatable, Sendable { let left: Double; let top: Double; let right: Double; let bottom: Double }

struct JpegCropSource: Codable, Equatable, Sendable {
    let width: Int; let height: Int; let mcuWidth: Int; let mcuHeight: Int; let orientation: Int
    init(width: Int, height: Int, mcuWidth: Int, mcuHeight: Int, orientation: Int) {
        precondition(width > 0 && height > 0 && mcuWidth > 0 && mcuHeight > 0 && (1...8).contains(orientation))
        self.width = width; self.height = height; self.mcuWidth = mcuWidth; self.mcuHeight = mcuHeight; self.orientation = orientation
    }
    var swapsAxes: Bool { orientation >= 5 }
    var displayWidth: Int { swapsAxes ? height : width }
    var displayHeight: Int { swapsAxes ? width : height }
    func toDisplay(_ x: Double, _ y: Double) -> CropPoint {
        switch orientation { case 2: return .init(x: 1-x,y:y); case 3: return .init(x: 1-x,y: 1-y); case 4: return .init(x:x,y:1-y); case 5: return .init(x:y,y:x); case 6: return .init(x:1-y,y:x); case 7: return .init(x:1-y,y:1-x); case 8: return .init(x:y,y:1-x); default: return .init(x:x,y:y) }
    }
    func toSource(_ x: Double, _ y: Double) -> CropPoint {
        switch orientation { case 6: return .init(x:y,y:1-x); case 8: return .init(x:1-y,y:x); default: return toDisplay(x,y) }
    }
    func displayBounds(_ rect: CropRect) -> CropBounds {
        let a = toDisplay(Double(rect.left)/Double(width), Double(rect.top)/Double(height)); let b = toDisplay(Double(rect.right)/Double(width), Double(rect.bottom)/Double(height))
        return .init(left:min(a.x,b.x), top:min(a.y,b.y), right:max(a.x,b.x), bottom:max(a.y,b.y))
    }
    func align(_ bounds: CropBounds, ratioWidth: Int = 0, ratioHeight: Int = 0) -> CropRect {
        precondition([bounds.left,bounds.top,bounds.right,bounds.bottom].allSatisfy { $0.isFinite && (0...1).contains($0) } && bounds.right > bounds.left && bounds.bottom > bounds.top)
        precondition((ratioWidth == 0 && ratioHeight == 0) || (ratioWidth > 0 && ratioHeight > 0))
        let a=toSource(bounds.left,bounds.top), b=toSource(bounds.right,bounds.bottom), left=min(a.x,b.x)*Double(width), top=min(a.y,b.y)*Double(height)
        let requestedWidth=max(abs(a.x-b.x)*Double(width),1), requestedHeight=max(abs(a.y-b.y)*Double(height),1)
        var w=min(max(Int(requestedWidth.rounded()),1),width), h=min(max(Int(requestedHeight.rounded()),1),height)
        if ratioWidth > 0 {
            let rw = swapsAxes ? ratioHeight : ratioWidth, rh = swapsAxes ? ratioWidth : ratioHeight, divisor = gcd(rw,rh), unitW=rw/divisor, unitH=rh/divisor
            if unitW > 64 || unitH > 64 { let scale=min(requestedWidth/Double(rw), requestedHeight/Double(rh)); w=min(max(Int((Double(rw)*scale).rounded()),1),width); h=min(max(Int((Double(rh)*scale).rounded()),1),height) }
            else { let count=Int(floor(min(requestedWidth/Double(unitW),requestedHeight/Double(unitH))+0.0001)); precondition(count > 0); w=unitW*count; h=unitH*count }
        }
        let x=min(max(Int(((left+(requestedWidth-Double(w))/2)/Double(mcuWidth)).rounded())*mcuWidth,0),((width-w)/mcuWidth)*mcuWidth)
        let y=min(max(Int(((top+(requestedHeight-Double(h))/2)/Double(mcuHeight)).rounded())*mcuHeight,0),((height-h)/mcuHeight)*mcuHeight)
        return .init(left:x,top:y,right:x+w,bottom:y+h)
    }
    func validate(_ rect: CropRect) { precondition(rect.left>=0 && rect.top>=0 && rect.right<=width && rect.bottom<=height && rect.width>0 && rect.height>0 && rect.left % mcuWidth == 0 && rect.top % mcuHeight == 0) }
}
struct JpegCropRecipe: Equatable, Sendable { let source: JpegCropSource; let rect: CropRect; init(source:JpegCropSource,rect:CropRect){source.validate(rect);self.source=source;self.rect=rect} }
enum JpegCropError: Error { case orientationChanged }
struct JpegCropSelection: Equatable, Sendable { let bounds: CropBounds; let orientation:Int; let ratioWidth:Int; let ratioHeight:Int; init(bounds:CropBounds,orientation:Int,ratioWidth:Int=0,ratioHeight:Int=0){precondition((1...8).contains(orientation));self.bounds=bounds;self.orientation=orientation;self.ratioWidth=ratioWidth;self.ratioHeight=ratioHeight}; func resolve(_ source:JpegCropSource)throws->JpegCropRecipe{guard source.orientation==orientation else{throw JpegCropError.orientationChanged};return .init(source:source,rect:source.align(bounds,ratioWidth:ratioWidth,ratioHeight:ratioHeight))} }
private func gcd(_ a:Int,_ b:Int)->Int { b == 0 ? a : gcd(b,a%b) }
