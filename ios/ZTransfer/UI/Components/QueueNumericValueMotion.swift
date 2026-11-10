import Foundation

/// AnimatedQueuePillCount.kt / QueueNumericLabelTest: ungrouped decimal text,
/// including localized separators. Integers use place value, fractions index
/// from the separator, so adding a leading digit never rekeys the units.
struct QueueNumericLabel: Equatable {
    let integer: String
    let fraction: String
    let separator: String
    let suffix: String
    private let integers: [String]
    private let fractions: [String]

    init(integer: String, fraction: String, separator: String, suffix: String) {
        self.integer = integer; self.fraction = fraction; self.separator = separator; self.suffix = suffix
        integers = integer.map(String.init); fractions = fraction.map(String.init)
    }
    var integerCount: Int { integers.count }
    var fractionCount: Int { fractions.count }
    func digit(_ place: Int) -> String {
        if place >= 0 { return place < integers.count ? integers[integers.count - 1 - place] : "" }
        guard place != Int.min else { return "" }
        let index = -place - 1
        return index < fractions.count ? fractions[index] : ""
    }
    func character(_ place: Int) -> String { place == Int.min ? separator : digit(place) }
}

func queueNumericLabel(_ text: String) -> QueueNumericLabel? {
    // Kotlin Char.isDigit uses UTF-16 Nd characters, not every Unicode numeric
    // character (e.g. superscripts or Roman numerals).
    let units = Array(text.utf16)
    func digit(_ code: UInt16) -> Bool { UnicodeScalar(UInt32(code))?.properties.generalCategory == .decimalNumber }
    let end = units.firstIndex { !digit($0) && $0 != 0x2e && $0 != 0x2c && $0 != 0x66b } ?? units.count
    let number = Array(units[..<end])
    guard let first = number.first, let last = number.last, digit(first), digit(last) else { return nil }
    let decimal = number.firstIndex { !digit($0) }
    if let decimal, number[(decimal + 1)...].contains(where: { !digit($0) }) { return nil }
    let split = decimal ?? number.count
    return QueueNumericLabel(integer: String(decoding: number[..<split], as: UTF16.self),
        fraction: decimal.map { String(decoding: number[($0 + 1)...], as: UTF16.self) } ?? "",
        separator: decimal.map { String(decoding: [number[$0]], as: UTF16.self) } ?? "",
        suffix: String(decoding: units[end...], as: UTF16.self))
}

/// Kotlin Double.toLong saturation for the completed download's rate.
func queueNumericValue(_ value: Double) -> Int64 {
    if value.isNaN { return 0 }
    if value >= Double(Int64.max) { return .max }
    if value <= Double(Int64.min) { return .min }
    return Int64(value)
}

struct QueueValueLayerMotion {
    private(set) var fade: QueuePillFadeMotion
    private(set) var offset: ZTransferScalarAnimation
    private let halfHeightPixels: Float
    private var segmentSpec = ZTransferAndroidMotion.criticallyDampedSpring(stiffness: 400, threshold: 1)
    var isRunning: Bool { fade.alpha.isRunning || offset.isRunning }
    var exitFinished: Bool { fade.exitFinished && !offset.isRunning }
    var displayedOffsetPixels: Float { floor(offset.value + 0.5) }

    init(initiallyVisible: Bool, heightPixels: Int, direction: Int) {
        halfHeightPixels = Float(max(0, heightPixels) / 2)
        fade = .init(initiallyVisible: initiallyVisible, enterMilliseconds: 160,
                     enterDelayMilliseconds: 0, exitMilliseconds: 120)
        offset = .init(value: initiallyVisible ? 0 : halfHeightPixels * Float(direction), retainsEndVelocity: true)
    }
    mutating func setVisible(_ visible: Bool, direction: Int, frame: Int64?) {
        let next: QueuePillFadeMotion.Phase = visible ? .visible : .postExit
        if fade.phase != next {
            if fade.phase == .preEnter && visible || fade.phase == .visible && !visible {
                segmentSpec = .tween(milliseconds: 180)
            } else { segmentSpec = .criticallyDampedSpring(stiffness: 400, threshold: 1) }
        }
        fade.setVisible(visible, atFrameNanos: frame)
        retarget(visible ? 0 : -halfHeightPixels * Float(direction), frame: frame)
    }
    mutating func restart(frame: Int64?) {
        fade.setVisible(fade.phase == .visible, atFrameNanos: frame, force: true)
        retarget(offset.target, frame: frame)
    }
    private mutating func retarget(_ target: Float, frame: Int64?) {
        // Compose 1.7.6: an interrupted tween uses Transition's default1500
        // spring; a PostExit reversal uses EnterExitTransition's default400.
        var spec = segmentSpec
        if offset.isRunning, case .tween = spec { spec = .criticallyDampedSpring(stiffness: 1500, threshold: 1) }
        offset.retarget(target, using: spec,
                        fromDisplayedValue: displayedOffsetPixels, force: true, atFrameNanos: frame)
    }
    mutating func advance(_ nanos: Int64) { fade.advance(nanos); offset.advance(frameNanos: nanos) }
}

/// The same content-key ownership is used for a digit and for a unit change.
/// Reversing to a departing key reuses its displayed position and opacity.
struct QueueValueContentMotion {
    struct Layer: Identifiable {
        let key: String
        var motion: QueueValueLayerMotion
        var id: String { key }
    }
    private(set) var current: String
    private(set) var layers: [Layer]
    private let heightPixels: Int
    private var frame: Int64?
    var isRunning: Bool { layers.contains { $0.motion.isRunning } }

    init(key: String, heightPixels: Int) {
        current = key; self.heightPixels = heightPixels
        layers = [.init(key: key, motion: .init(initiallyVisible: true, heightPixels: heightPixels, direction: 1))]
    }
    mutating func update(_ key: String, direction: Int, frame origin: Int64? = nil, reset: Bool = false) {
        let origin = origin ?? frame
        guard key != current else {
            if reset { for index in layers.indices { layers[index].motion.restart(frame: origin) } }
            return
        }
        let previous = current; current = key
        if !layers.contains(where: { $0.key == key }) {
            layers.append(.init(key: key, motion: .init(initiallyVisible: false, heightPixels: heightPixels, direction: direction)))
        }
        for index in layers.indices {
            if layers[index].key == key || layers[index].key == previous {
                layers[index].motion.setVisible(layers[index].key == key, direction: direction, frame: origin)
            } else { layers[index].motion.restart(frame: origin) }
        }
    }
    mutating func advance(_ nanos: Int64) {
        guard isRunning || layers.count > 1 else { return }
        for index in layers.indices { layers[index].motion.advance(nanos) }
        layers.removeAll { $0.key != current && $0.motion.exitFinished }
        frame = isRunning ? nanos : nil
    }
}

struct QueueNumericValueMotion {
    struct Snapshot: Equatable {
        let text: String
        let value: Int64
        let number: QueueNumericLabel?
        var key: String { number?.suffix ?? text }
        init(text: String, value: Int64) { self.text = text; self.value = value; number = queueNumericLabel(text) }
    }
    struct Group {
        var snapshot: Snapshot
        var digits: [Int: QueueValueContentMotion] = [:]
        var places: [Int] = []
        var integerCount = 0
        var fractionCount = 0
        var isRunning: Bool { digits.values.contains { $0.isRunning } }

        init(snapshot: Snapshot, heightPixels: Int) {
            self.snapshot = snapshot
            if let number = snapshot.number {
                resize(integer: number.integerCount, fraction: number.fractionCount)
                for place in places { digits[place] = .init(key: number.character(place), heightPixels: heightPixels) }
            }
        }
        private mutating func resize(integer: Int, fraction: Int) {
            guard integerCount != integer || fractionCount != fraction else { return }
            integerCount = integer; fractionCount = fraction
            places = Array((0..<integer).reversed())
            if fraction > 0 { places += [Int.min] + (1...fraction).map { -$0 } }
        }
        mutating func update(_ next: Snapshot, heightPixels: Int, frame: Int64?) {
            let direction = next.value < snapshot.value ? 1 : -1
            guard snapshot.number != nil, let number = next.number else {
                self = Self(snapshot: next, heightPixels: heightPixels); return
            }
            snapshot = next
            resize(integer: max(integerCount, number.integerCount), fraction: max(fractionCount, number.fractionCount))
            for place in places {
                if digits[place] == nil { digits[place] = .init(key: "", heightPixels: heightPixels) }
                digits[place]?.update(number.character(place), direction: direction, frame: frame, reset: true)
            }
        }
        mutating func advance(_ nanos: Int64) {
            for place in places { digits[place]?.advance(nanos) }
            if !isRunning, let number = snapshot.number,
               integerCount != number.integerCount || fractionCount != number.fractionCount {
                resize(integer: number.integerCount, fraction: number.fractionCount)
                let retained = Set(places)
                digits = digits.filter { retained.contains($0.key) }
            }
        }
    }
    private(set) var target: Snapshot
    private(set) var outer: QueueValueContentMotion
    private(set) var groups: [String: Group]
    let heightPixels: Int
    private var frame: Int64?
    var isRunning: Bool { outer.isRunning || groups.values.contains { $0.isRunning } }

    init(text: String, value: Int64, heightPixels: Int) {
        let snapshot = Snapshot(text: text, value: value)
        target = snapshot; self.heightPixels = heightPixels
        outer = .init(key: snapshot.key, heightPixels: heightPixels)
        groups = [snapshot.key: .init(snapshot: snapshot, heightPixels: heightPixels)]
    }
    mutating func update(text: String, value: Int64, animate: Bool = true) {
        guard animate else {
            let displayedValue = text == target.text ? target.value : value
            self = Self(text: text, value: displayedValue, heightPixels: heightPixels); return
        }
        // Android remember(text): raw changes hidden by rounding do not restart
        // animations or alter the direction baseline of the displayed label.
        guard text != target.text else { return }
        let next = Snapshot(text: text, value: value), direction = value < target.value ? 1 : -1
        target = next
        if groups[next.key] == nil { groups[next.key] = .init(snapshot: next, heightPixels: heightPixels) }
        else { groups[next.key]?.update(next, heightPixels: heightPixels, frame: frame) }
        outer.update(next.key, direction: direction, frame: frame, reset: true)
    }
    mutating func advance(_ nanos: Int64) {
        outer.advance(nanos)
        if groups.count != outer.layers.count {
            let retained = Set(outer.layers.map(\.key))
            groups = groups.filter { retained.contains($0.key) }
        }
        for key in groups.keys { groups[key]?.advance(nanos) }
        frame = isRunning ? nanos : nil
    }
}
