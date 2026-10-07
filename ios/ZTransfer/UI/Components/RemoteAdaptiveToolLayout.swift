import SwiftUI

struct RemoteToolLayoutID: LayoutValueKey {
    static let defaultValue: RemoteTool? = nil
}

/// Pixel-space port of RemoteScreen.AdaptiveRemoteToolBar. Shared tracks stay
/// fixed even when only one regular control remains. Only RECORD spans tracks.
enum RemoteToolbarGeometry {
    struct Item {
        var size: CGSize
        var tool: RemoteTool? = nil
    }
    struct Result {
        var frames: [CGRect]
        var height: CGFloat
    }

    static func arrange(items: [Item], width: CGFloat, horizontalGap: CGFloat = 6,
                        verticalGap: CGFloat = 4, pinnedEndCount: Int,
                        secondRowFirst: RemoteTool? = nil, scale: CGFloat = 1) -> Result {
        let density = max(1, scale)
        func pixels(_ value: CGFloat) -> Int { Int((value * density).rounded(.toNearestOrAwayFromZero)) }
        let gap = pixels(horizontalGap), rowGap = pixels(verticalGap)
        let maxWidth = max(0, pixels(width))
        let sizes = items.map { (width: pixels($0.size.width), height: pixels($0.size.height)) }
        let regularEnd = items.count - min(max(0, pinnedEndCount), items.count)
        let visible = items.indices.filter { sizes[$0].width > 0 && sizes[$0].height > 0 }
        var regular = visible.filter { $0 < regularEnd }
        let pinned = visible.filter { $0 >= regularEnd }
        let cell = max(pixels(36), visible.filter { items[$0].tool != .record }.map { sizes[$0].width }.max() ?? 0)
        let columns = max(1, (maxWidth + gap) / (cell + gap))
        func span(_ index: Int) -> Int {
            min(columns, max(1, (sizes[index].width + gap + cell + gap - 1) / (cell + gap)))
        }
        // Compose uses Float for pitch before rounding placement to pixels.
        let pitch: Float = columns > 1 ? Float(maxWidth - cell) / Float(columns - 1) : 0
        let pinnedSpans = pinned.reduce(0) { $0 + span($1) }
        let firstCapacity = max(0, columns - pinnedSpans)
        let defaultLock = regular.first { secondRowFirst != nil && items[$0].tool == secondRowFirst }
        let rowTwoLock = defaultLock.flatMap { lock -> Int? in
            regular.prefix { $0 != lock }.reduce(0) { $0 + span($1) } >= firstCapacity ? lock : nil
        }
        if let rowTwoLock { regular.removeAll { $0 == rowTwoLock } }
        var rows: [[(index: Int, column: Int)]] = [[]]
        var next = 0, used = 0
        while next < regular.count, used + span(regular[next]) <= firstCapacity {
            let index = regular[next]
            rows[0].append((index, used))
            used += span(index)
            next += 1
        }
        var pinnedColumn = max(0, columns - pinnedSpans)
        for index in pinned {
            rows[0].append((index, pinnedColumn))
            pinnedColumn += span(index)
        }
        let remaining = rowTwoLock.map { [$0] } ?? []
        used = columns
        for index in remaining + regular.dropFirst(next) {
            if rows.count == 1 || used + span(index) > columns {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append((index, used))
            used += span(index)
        }
        var frames = Array(repeating: CGRect.zero, count: items.count)
        var y = 0
        for (rowIndex, row) in rows.enumerated() {
            let height = row.map { sizes[$0.index].height }.max() ?? 0
            for (index, column) in row {
                let slot = Float(cell) + Float(span(index) - 1) * pitch
                let x = max(0, Int(floor(Float(column) * pitch + (slot - Float(sizes[index].width)) / 2 + 0.5)))
                frames[index] = CGRect(x: CGFloat(x) / density,
                                       y: CGFloat(y + (height - sizes[index].height) / 2) / density,
                                       width: CGFloat(sizes[index].width) / density,
                                       height: CGFloat(sizes[index].height) / density)
            }
            y += height + (rowIndex < rows.count - 1 ? rowGap : 0)
        }
        return Result(frames: frames, height: CGFloat(y) / density)
    }
}

struct RemoteAdaptiveToolLayout: Layout {
    let displayScale: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let pinnedEndCount: Int
    var secondRowFirst: RemoteTool? = nil

    private func geometry(width: CGFloat, subviews: Subviews) -> RemoteToolbarGeometry.Result {
        RemoteToolbarGeometry.arrange(items: subviews.map {
            .init(size: $0.sizeThatFits(.unspecified), tool: $0[RemoteToolLayoutID.self])
        }, width: width, horizontalGap: horizontalSpacing, verticalGap: verticalSpacing,
           pinnedEndCount: pinnedEndCount, secondRowFirst: secondRowFirst, scale: displayScale)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? subviews.reduce(0) {
            $0 + $1.sizeThatFits(.unspecified).width + horizontalSpacing
        })
        return CGSize(width: width, height: geometry(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = geometry(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            let frame = result.frames[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
