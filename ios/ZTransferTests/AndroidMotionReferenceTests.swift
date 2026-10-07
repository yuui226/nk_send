import XCTest
@testable import ZTransfer

final class AndroidMotionReferenceTests: XCTestCase {
    private struct Fixture: Decodable {
        struct AnimationCase: Decodable {
            struct Sample: Decodable {
                let nanos: Int64
                let value: String
                let velocity: String
            }
            let spec: String
            let start: String
            let target: String
            let velocity: String
            let durationNanos: Int64
            let samples: [Sample]
        }
        struct Easing: Decodable {
            let fraction: String
            let value: String
        }
        let cases: [AnimationCase]
        let easing: [Easing]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AndroidMotion", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func float(_ hex: String) throws -> Float {
        Float(bitPattern: try XCTUnwrap(UInt32(hex, radix: 16)))
    }

    private func spec(_ name: String) throws -> ZTransferAndroidMotion {
        let parts = name.split(separator: "-")
        if parts[0] == "tween" { return .tween(milliseconds: try XCTUnwrap(Int64(parts[1]))) }
        if parts[2] == "1" { return .criticallyDampedSpring(stiffness: try XCTUnwrap(Float(parts[1]))) }
        return .underdampedSpring(stiffness: try XCTUnwrap(Float(parts[1])),
                                  dampingRatio: try XCTUnwrap(Float(parts[2])))
    }

    func testFastOutSlowInMatchesAll1001ComposeSamples() throws {
        let samples = try fixture().easing
        XCTAssertEqual(samples.count, 1001)
        for sample in samples {
            let fraction = try float(sample.fraction)
            XCTAssertEqual(ZTransferAndroidMotion.fastOutSlowIn(fraction).bitPattern,
                           try float(sample.value).bitPattern, "fraction=\(fraction)")
        }
    }

    func testAll90SpecsMatchComposeValuesVelocitiesAndDurations() throws {
        let cases = try fixture().cases
        XCTAssertEqual(cases.count, 100)
        for item in cases {
            let spec = try spec(item.spec)
            let start = try float(item.start), target = try float(item.target), velocity = try float(item.velocity)
            let context = "\(item.spec), \(start) -> \(target), v=\(velocity)"
            XCTAssertEqual(spec.durationNanos(from: start, to: target, velocity: velocity), item.durationNanos, context)
            for sample in item.samples {
                let actual = spec.sample(at: sample.nanos, from: start, to: target, velocity: velocity)
                let expectedValue = try float(sample.value), expectedVelocity = try float(sample.velocity)
                // libm's transcendental operations differ across JVM/macOS
                // implementations. Permit at most one Float32 ULP per sample;
                // easing and duration remain bit/integer exact above.
                XCTAssertEqual(actual.value, expectedValue, accuracy: expectedValue.ulp,
                               "\(context), t=\(sample.nanos), value")
                XCTAssertEqual(actual.velocity, expectedVelocity, accuracy: expectedVelocity.ulp,
                               "\(context), t=\(sample.nanos), velocity")
            }
        }
    }

    func testSpringSnapsAtComposeEstimatedDurationAndTweenReportsEndVelocity() throws {
        for item in try fixture().cases {
            let spec = try spec(item.spec)
            let start = try float(item.start), target = try float(item.target), velocity = try float(item.velocity)
            let result = spec.animationSample(at: max(item.durationNanos, 0), from: start, to: target, velocity: velocity)
            XCTAssertEqual(result.value, target, item.spec)
            if item.spec.hasPrefix("spring") {
                XCTAssertEqual(result.velocity, 0, item.spec)
            } else {
                XCTAssertEqual(result.velocity, spec.sample(at: item.durationNanos,
                    from: start, to: target, velocity: velocity).velocity, item.spec)
            }
        }
    }
}
