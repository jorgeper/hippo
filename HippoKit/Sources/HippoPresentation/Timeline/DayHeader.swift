import Foundation

public enum DayHeader {
    /// `localDay` is `YYYY-MM-DD`. Output is uppercased: "TODAY · SAT NOV 7", "YESTERDAY · FRI NOV 6",
    /// "THU NOV 5", and "WED NOV 5, 2025" for another year. An unparseable day is returned as given.
    public static func title(localDay: String, now: Date, calendar: Calendar, locale: Locale) -> String {
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return localDay }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        var text = formatter.string(from: day).replacingOccurrences(of: ",", with: "")
        if calendar.component(.year, from: day) != calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("y")
            text += ", " + formatter.string(from: day)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day),
                                           to: calendar.startOfDay(for: now)).day
        switch days {
        case 0: text = "Today · " + text
        case 1: text = "Yesterday · " + text
        default: break
        }
        return text.uppercased(with: locale)
    }
}
