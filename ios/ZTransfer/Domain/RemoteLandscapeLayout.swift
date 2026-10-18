import Foundation

/// Android LandscapeMonitorLayout.kt: the viewport has already had its safe
/// insets applied. Keep the Float arithmetic and choose the larger image, not a
/// fixed-width control rail. Desqueeze participates in the image aspect.
struct RemoteLandscapeLayout: Equatable {
    let image: CGRect
    let controls: CGRect
    let columns: Int
    let shutterSize: CGFloat
    let bottomControls: Bool
    let photoReview: Bool

    var footerHeight: CGFloat { max(36, shutterSize) + (photoReview ? 52 : 40) }
    var captureLift: CGFloat {
        !bottomControls && columns == 2
            ? min(48, max(0, (controls.height - 36 - 8 - footerHeight - 98) / 3)) : 0
    }
    var parameterHeight: CGFloat {
        bottomControls || columns == 2 ? 46
            : min(46, max(42, (controls.height - 36 - 8 - footerHeight - 6) / 4))
    }

    init(width: CGFloat, height: CGFloat, imageAspect: CGFloat, photoReview: Bool = false) {
        self.photoReview = photoReview
        precondition(width.isFinite && height.isFinite && width >= 0 && height >= 0)
        precondition(imageAspect.isFinite && imageAspect > 0)
        let w = Float(width), h = Float(height), aspect = Float(imageAspect)
        let shutter = min(64, max(48, h * 0.18))
        let fullWidth = min(max(0, w - 8), max(0, h - 8) * aspect)
        let sideWidth = min(fullWidth, max(0, w - (photoReview ? 128 : 116) - 16))
        let bottomHeight = 40 + max(46 * 2 + 4, max(36, shutter) + (photoReview ? 52 : 40))
        let bottomWidth = w >= 360 && h >= bottomHeight + 16
            ? min(fullWidth, (h - bottomHeight - 16) * aspect) : -1
        bottomControls = bottomWidth > sideWidth + 0.01
        let iw = bottomControls ? bottomWidth : sideWidth
        let ih = iw / aspect
        let iy = bottomControls ? max(4, min((h - ih) / 2, h - bottomHeight - 12 - ih)) : (h - ih) / 2
        image = CGRect(x: CGFloat(min(4, w)), y: CGFloat(iy), width: CGFloat(iw), height: CGFloat(ih))
        let cw: Float
        if bottomControls {
            cw = max(0, w - 8)
            controls = CGRect(x: 4, y: CGFloat(iy + ih + 8), width: CGFloat(cw), height: CGFloat(max(0, h - iy - ih - 12)))
        } else {
            let x = min(w, min(4, w) + iw + 8)
            cw = max(0, w - x - 4)
            controls = CGRect(x: CGFloat(x), y: CGFloat(min(8, h)), width: CGFloat(cw), height: CGFloat(max(0, h - 12)))
        }
        columns = bottomControls || cw >= 176 ? 2 : 1
        shutterSize = CGFloat(bottomControls ? shutter : min(74, max(48, cw - 56)))
    }
}

/// LandscapeMonitorLayout.landscapePhotoCaptureSizes: the capture pair uses
/// the full row, independently of the DISP/rotation controls below it.
struct RemotePhotoCaptureSizes {
    let shutter: CGFloat
    let reviewScale: CGFloat
    let gap: CGFloat
    var reviewWidth: CGFloat { 40 * reviewScale }
    var reviewHeight: CGFloat { 48 * reviewScale }
    var width: CGFloat { reviewWidth + gap + shutter }
    init(availableWidth: CGFloat, preferredShutter: CGFloat) {
        let preferred = Float(preferredShutter)
        let scale = min(1, max(0, Float(availableWidth) / (preferred + 40 + 8)))
        shutter = CGFloat(preferred * scale); reviewScale = CGFloat(scale); gap = CGFloat(8 * scale)
    }
}

/// The signed Animatable in LandscapeMonitorControls.kt never shows both
/// surfaces together. A reversal retains the displayed value; it is still a
/// 280ms FastOutSlowIn tween, not Compose Transition's interruption spring.
struct RemoteDockMotion {
    private(set) var open = false
    private(set) var animation = ZTransferScalarAnimation(value: -1)
    var progress: Float { animation.value }
    mutating func setOpen(_ open: Bool) {
        self.open = open
        animation.retarget(open ? 1 : -1, using: .tween(milliseconds: 280))
    }
    mutating func advance(_ nanos: Int64) { animation.advance(frameNanos: nanos) }
    func visibility(dock: Bool) -> Float { min(1, max(0, dock ? progress : -progress)) }
    func acceptsInput(dock: Bool) -> Bool { open == dock && visibility(dock: dock) > 0 }
}

/// RemoteScreen's meter stack and ViewfinderSoundMeterOverlay height policy.
struct RemoteMonitorMeterLayout: Equatable {
    let exposureTop: CGFloat
    let audio: CGRect
    let scopeStartInset: CGFloat

    init(size: CGSize, landscape: Bool, movie: Bool, showExposure: Bool, audioEnabled: Bool) {
        exposureTop = movie ? 34 : 10
        scopeStartInset = audioEnabled && !landscape ? 48 : 8
        let containerTop = landscape ? exposureTop + (showExposure ? 126 : 0) : 0
        let containerHeight = landscape ? min(88, max(0, size.height - containerTop - 8)) : size.height
        let meterHeight = min(min(72, max(56, containerHeight * 0.24)), max(0, containerHeight - 16))
        audio = CGRect(x: landscape ? max(0, size.width - 30) : 8,
                       y: landscape ? min(containerTop, size.height) + containerHeight - meterHeight
                           : max(0, size.height - 8 - meterHeight),
                       width: 22, height: audioEnabled ? meterHeight : 0)
    }
}
