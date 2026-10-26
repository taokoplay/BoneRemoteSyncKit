import Foundation

/// Shared only within this package: a bounded, strict Internet timestamp parser.
/// Creation metadata must not silently normalize invalid dates or accept trailing input.
package enum RemoteCreationDate {
    package static func parse(_ raw: String?) -> Date? {
        guard let raw, (20...128).contains(raw.utf8.count) else { return nil }
        let bytes = Array(raw.utf8)
        func number(_ start: Int, _ end: Int) -> Int? {
            guard start < end, end <= bytes.count else { return nil }
            var result = 0
            for byte in bytes[start..<end] {
                guard (48...57).contains(byte) else { return nil }
                result = result * 10 + Int(byte - 48)
            }
            return result
        }
        guard bytes[4] == 45, bytes[7] == 45, [84, 116].contains(bytes[10]),
              bytes[13] == 58, bytes[16] == 58,
              let year = number(0, 4), (1...9999).contains(year),
              let month = number(5, 7), (1...12).contains(month),
              let day = number(8, 10),
              let hour = number(11, 13), hour < 24,
              let minute = number(14, 16), minute < 60,
              let second = number(17, 19), second < 60 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }

        var index = 19
        var fraction = 0.0
        if bytes[index] == 46 {
            index += 1
            let start = index
            var scale = 0.1
            while index < bytes.count, (48...57).contains(bytes[index]) {
                fraction += Double(bytes[index] - 48) * scale
                scale *= 0.1
                index += 1
            }
            guard index > start else { return nil }
        }
        guard index < bytes.count else { return nil }
        let offset: Int
        if [90, 122].contains(bytes[index]), index + 1 == bytes.count {
            offset = 0
        } else {
            guard index + 6 == bytes.count, [43, 45].contains(bytes[index]), bytes[index + 3] == 58,
                  let hours = number(index + 1, index + 3), hours < 24,
                  let minutes = number(index + 4, index + 6), minutes < 60 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (bytes[index] == 43 ? 1 : -1)
        }
        // Count complete Gregorian years and months directly. Foundation Calendar can
        // apply the historical 1582 cutover even for .iso8601; timestamps use the
        // proleptic Gregorian calendar throughout the bounded 1...9999 range.
        func daysBeforeYear(_ year: Int) -> Int {
            let previous = year - 1
            return previous * 365 + previous / 4 - previous / 100 + previous / 400
        }
        let epochDays = daysBeforeYear(year) + days.prefix(month - 1).reduce(0, +) + day - 1 - daysBeforeYear(1970)
        let seconds = epochDays * 86400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}
