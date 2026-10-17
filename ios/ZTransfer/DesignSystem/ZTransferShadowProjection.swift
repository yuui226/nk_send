// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Foundation

/// GetSpotShadowTransform's light projection, including tilted height planes
/// and perspective CTMs. The caller supplies the light in device coordinates.
enum ZTransferShadowProjection {
    struct Spot {
        let transform: ZTransferShadowTransform
        let outset: Float
    }
    static func spot(boundsMinimum: SIMD2<Float>, boundsMaximum: SIMD2<Float>,
                     transform: ZTransferShadowTransform, heightPlane: SIMD3<Float>,
                     light: SIMD3<Float>, lightRadius: Float, directional: Bool = false) -> Spot? {
        let values = [boundsMinimum.x, boundsMinimum.y, boundsMaximum.x, boundsMaximum.y,
                      heightPlane.x, heightPlane.y, heightPlane.z, light.x, light.y, light.z, lightRadius]
        guard values.allSatisfy(\.isFinite), transform.isFinite else { return nil }
        func height(_ point: SIMD2<Float>) -> Float { (heightPlane.x * point.x + heightPlane.y * point.y) + heightPlane.z }
        // SkRect uses sk_float_midpoint's Double sum to avoid overflow.
        let center = SIMD2<Float>(Float(0.5 * (Double(boundsMinimum.x) + Double(boundsMaximum.x))),
                                  Float(0.5 * (Double(boundsMinimum.y) + Double(boundsMaximum.y))))
        let occluderHeight = height(center)
        let metrics = ZTransferAndroidShadowMetrics.projection(height: occluderHeight,
            lightX: light.x, lightY: light.y, lightZ: light.z, lightRadius: lightRadius)
        if !transform.hasPerspective || directional {
            let scale: Float, translation: SIMD2<Float>, outset: Float
            if directional {
                scale = 1
                outset = lightRadius * occluderHeight
                let ratio = min(max(occluderHeight / light.z, 0), 64 * 4096)
                translation = .init(-ratio * light.x, -ratio * light.y)
            } else {
                scale = metrics.spotScale
                outset = metrics.spotOutset
                translation = .init(metrics.spotTranslationX, metrics.spotTranslationY)
            }
            let projected = ZTransferShadowTransform(x: .init(scale, 0, translation.x),
                y: .init(0, scale, translation.y), perspective: .init(0, 0, 1)).concatenating(transform)
            guard projected.isFinite, outset.isFinite else { return nil }
            return Spot(transform: projected, outset: outset)
        }
        let size = boundsMaximum - boundsMinimum
        guard abs(size.x) > 1 / 4096, abs(size.y) > 1 / 4096 else { return nil }
        let corners = [boundsMinimum, .init(boundsMaximum.x, boundsMinimum.y), boundsMaximum,
                       .init(boundsMinimum.x, boundsMaximum.y)]
        var projected: [SIMD3<Float>] = []
        for corner in corners {
            let mapped = transform.map(corner)
            let z = height(corner), dz = light.z - z
            guard dz > 1 / 4096 else { return nil }
            let ratio = z / dz
            projected.append(.init(mapped.x - (light.x - mapped.x) * ratio,
                                   mapped.y - (light.y - mapped.y) * ratio, 1))
        }
        func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            .init(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        var h0 = cross(cross(projected[1], projected[0]), cross(projected[2], projected[3]))
        var h1 = cross(cross(projected[0], projected[3]), cross(projected[1], projected[2]))
        let h2 = cross(cross(projected[0], projected[2]), cross(projected[1], projected[3]))
        guard abs(h2.z) > 1 / 4096 else { return nil }
        var v = projected[3] - projected[0]
        let w = h0 - projected[0]
        if v.x * w.y - v.y * w.x > 0 { h0 = -h0 }
        v = projected[1] - projected[0]
        // The source deliberately reuses w from the h0 check for h1.
        if v.x * w.y - v.y * w.x < 0 { h1 = -h1 }
        let projection = ZTransferShadowTransform(x: .init(h0.x / h2.z, h1.x / h2.z, h2.x / h2.z),
            y: .init(h0.y / h2.z, h1.y / h2.z, h2.y / h2.z), perspective: .init(h0.z / h2.z, h1.z / h2.z, 1))
        let sx = 2 / size.x, sy = 2 / size.y
        let normalized = ZTransferShadowTransform(x: .init(sx, 0, -sx * boundsMinimum.x - 1),
            y: .init(0, sy, -sy * boundsMinimum.y - 1), perspective: .init(0, 0, 1))
        let result = projection.concatenating(normalized)
        guard result.isFinite, metrics.spotOutset.isFinite else { return nil }
        return Spot(transform: result, outset: metrics.spotOutset)
    }
}
