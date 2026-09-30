import Foundation

/// Parsing/formatting for the Settings wake-time field, which the user types
/// into by hand. Accepts `6`, `06`, `6:30`, `06:30`, `6.30`, `6 30`, `630`,
/// `0630`; anything out of range (25:00, 06:75) or malformed is rejected so the
/// field can fall back to the last valid time.
enum TimeInput {
    static func parse(_ raw: String) -> (hour: Int, minute: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let separators = CharacterSet(charactersIn: ":. ")
        let parts = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        let hourText: String
        let minuteText: String
        if parts.count == 2 {
            hourText = parts[0]
            minuteText = parts[1]
            guard (1...2).contains(hourText.count), minuteText.count == 2 else { return nil }
        } else if parts.count == 1, trimmed.rangeOfCharacter(from: separators) == nil {
            let digits = parts[0]
            switch digits.count {
            case 1, 2: hourText = digits; minuteText = "00"
            case 3:    hourText = String(digits.prefix(1)); minuteText = String(digits.suffix(2))
            case 4:    hourText = String(digits.prefix(2)); minuteText = String(digits.suffix(2))
            default:   return nil
            }
        } else {
            return nil
        }

        guard hourText.allSatisfy(\.isASCIIDigit), minuteText.allSatisfy(\.isASCIIDigit),
              let hour = Int(hourText), let minute = Int(minuteText),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    static func text(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
