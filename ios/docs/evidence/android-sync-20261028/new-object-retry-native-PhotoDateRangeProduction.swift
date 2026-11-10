import Foundation

struct PhotoDateRange: Equatable, Sendable, Codable {
    let start: String
    let end: String
    func contains(_ captureDate: String?) -> Bool {
        guard let date = captureDate?.prefix(8), date.count == 8 else { return false }
        let key = String(date)
        guard validPhotoCaptureDay(key) != nil,
              validPhotoCaptureDay(start) != nil,
              validPhotoCaptureDay(end) != nil else { return false }
        return key >= start && key <= end
    }
}

func validPhotoCaptureDay(_ value: String?) -> String? {
    // Android captureDayKey: strict ASCII/proleptic Gregorian validation,
    // without constructing a Calendar and Date for every catalog row.
    guard let value else { return nil }
    var key = 0, count = 0
    for byte in value.utf8.prefix(8) {
        guard (48...57).contains(byte) else { return nil }
        key = key * 10 + Int(byte - 48)
        count += 1
    }
    let year = key / 10_000, month = key / 100 % 100, day = key % 100
    guard count == 8, (1...9999).contains(year), (1...12).contains(month) else { return nil }
    let maxDay: Int
    switch month {
    case 2: maxDay = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
    case 4, 6, 9, 11: maxDay = 30
    default: maxDay = 31
    }
    return (1...maxDay).contains(day) ? String(value.prefix(8)) : nil
}
