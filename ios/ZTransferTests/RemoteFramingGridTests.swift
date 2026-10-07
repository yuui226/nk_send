import XCTest
@testable import ZTransfer

// Migrated from Android FramingGridTest, including its complete geometry matrix.
final class RemoteFramingGridTests: XCTestCase {
    func testCycle() {
        var grid = RemoteGridMode.off
        var visited: [RemoteGridMode] = []
        for _ in 0..<11 { visited.append(grid); grid = grid.next }
        XCTAssertEqual(visited, [.off, .thirds, .thirdsDiagonals, .fourths, .fourthsDiagonals,
                                 .center, .golden, .wide235, .wide169, .frame43, .off])
    }

    func testCenterExcludesLetterbox() {
        XCTAssertEqual(RemoteFramingGrid.lines(.center, width: 1200, height: 800, aspect: 3), [
            RemoteFramingGridLine(start: CGPoint(x: 600, y: 200), end: CGPoint(x: 600, y: 600)),
            RemoteFramingGridLine(start: CGPoint(x: 0, y: 400), end: CGPoint(x: 1200, y: 400))])
    }

    func testGoldenFractions() {
        let lines = RemoteFramingGrid.lines(.golden, width: 1200, height: 800, aspect: 3)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].start.x, 458.3592, accuracy: 0.001)
        XCTAssertEqual(lines[2].start.x, 741.6408, accuracy: 0.001)
        XCTAssertEqual(lines[1].start.y, 352.7864, accuracy: 0.001)
        XCTAssertEqual(lines[3].start.y, 447.2136, accuracy: 0.001)
        XCTAssertEqual(lines[0].start.y, 200)
        XCTAssertEqual(lines[0].end.y, 600)
    }

    func testHeightLimitedViewport() {
        let lines = RemoteFramingGrid.lines(.thirds, width: 2000, height: 600, aspect: 2)
        XCTAssertEqual(lines[0].start.x, 800, accuracy: 0.001)
        XCTAssertEqual(lines[2].start.x, 1200, accuracy: 0.001)
        XCTAssertEqual(lines[1].start, CGPoint(x: 400, y: 200))
        XCTAssertEqual(lines[1].end, CGPoint(x: 1600, y: 200))
    }

    func testAllStylesAcrossShapesRotationsAndDesqueeze() {
        let frames: [Float] = [4 / 3, 3 / 2, 16 / 9]
        let multipliers: [Float] = [1, 1.33, 1.5, 1.8, 2]
        let viewports: [(Float, Float)] = [(720, 1280), (1280, 720), (2000, 600)]
        for (width, height) in viewports {
            for source in frames {
                for multiplier in multipliers {
                    let aspect = source * multiplier
                    let imageWidth = min(width, height * aspect), imageHeight = imageWidth / aspect
                    let left = (width - imageWidth) / 2, top = (height - imageHeight) / 2
                    for grid in RemoteGridMode.allCases {
                        let lines = RemoteFramingGrid.lines(grid, width: width, height: height, aspect: aspect)
                        XCTAssertEqual(lines.count, grid.frameAspect != nil ? 4 : grid.fractions.count * 2 + (grid.diagonals ? 2 : 0))
                        if let target = grid.frameAspect {
                            let x0 = lines[0].start.x, y0 = lines[0].start.y
                            let x1 = lines[1].start.x, y1 = lines[1].end.y
                            XCTAssertEqual((x1-x0)/(y1-y0), CGFloat(target), accuracy: 0.001)
                            XCTAssertEqual((x0+x1)/2, CGFloat(width/2), accuracy: 0.001)
                            XCTAssertEqual((y0+y1)/2, CGFloat(height/2), accuracy: 0.001)
                            XCTAssertGreaterThanOrEqual(x0, CGFloat(left)-0.001)
                            XCTAssertLessThanOrEqual(x1, CGFloat(left+imageWidth)+0.001)
                            XCTAssertGreaterThanOrEqual(y0, CGFloat(top)-0.001)
                            XCTAssertLessThanOrEqual(y1, CGFloat(top+imageHeight)+0.001)
                        }
                        if grid.diagonals {
                            let expected = [(left, top, left+imageWidth, top+imageHeight),
                                            (left+imageWidth, top, left, top+imageHeight)]
                            for (actual, want) in zip(lines.suffix(2), expected) {
                                XCTAssertEqual(actual.start.x, CGFloat(want.0), accuracy: 0.001)
                                XCTAssertEqual(actual.start.y, CGFloat(want.1), accuracy: 0.001)
                                XCTAssertEqual(actual.end.x, CGFloat(want.2), accuracy: 0.001)
                                XCTAssertEqual(actual.end.y, CGFloat(want.3), accuracy: 0.001)
                            }
                        }
                        for (index, fraction) in grid.fractions.enumerated() {
                            let vertical = lines[index*2], horizontal = lines[index*2+1]
                            XCTAssertEqual(vertical.start.x, CGFloat(left+imageWidth*fraction), accuracy: 0.001)
                            XCTAssertEqual(vertical.start.y, CGFloat(top), accuracy: 0.001)
                            XCTAssertEqual(vertical.end.y, CGFloat(top+imageHeight), accuracy: 0.001)
                            XCTAssertEqual(horizontal.start.y, CGFloat(top+imageHeight*fraction), accuracy: 0.001)
                            XCTAssertEqual(horizontal.start.x, CGFloat(left), accuracy: 0.001)
                            XCTAssertEqual(horizontal.end.x, CGFloat(left+imageWidth), accuracy: 0.001)
                        }
                    }
                }
            }
        }
    }

    func testOffAndInvalidGeometry() {
        XCTAssertTrue(RemoteFramingGrid.lines(.off, width: 1200, height: 800, aspect: 1.5).isEmpty)
        XCTAssertTrue(RemoteFramingGrid.lines(.golden, width: 0, height: 800, aspect: 1.5).isEmpty)
        XCTAssertTrue(RemoteFramingGrid.lines(.center, width: 1200, height: 0, aspect: 1.5).isEmpty)
        XCTAssertTrue(RemoteFramingGrid.lines(.thirds, width: 1200, height: 800, aspect: .nan).isEmpty)
    }
}
