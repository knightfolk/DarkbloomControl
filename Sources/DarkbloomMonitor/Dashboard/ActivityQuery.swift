import DarkbloomTelemetry
import Foundation

enum ActivityPeriod: String, CaseIterable, Identifiable {
    case today = "Today", thisWeek = "This week", date = "Date", dateRange = "Date range"
    var id: Self { self }
}

/// Captures the complete request before suspension. A new date, timezone,
/// model, or ledger revision invalidates the old task without string collisions.
struct ActivityQuery: Hashable {
    let range: DateInterval?
    let unit: ActivityCalendarUnit
    let calendar: Calendar
    let model: String?
    let revision: UInt64
    let refreshID: Int

    init(period: ActivityPeriod, selectedDate: Date, endDate: Date, now: Date,
         calendar: Calendar, model: String?, revision: UInt64, refreshID: Int) {
        self.calendar = calendar
        self.model = model
        self.revision = revision
        self.refreshID = refreshID
        unit = period == .thisWeek || period == .dateRange ? .day : .hour
        switch period {
        case .today: range = calendar.dateInterval(of: .day, for: now)
        case .thisWeek: range = calendar.dateInterval(of: .weekOfYear, for: now)
        case .date: range = calendar.dateInterval(of: .day, for: selectedDate)
        case .dateRange:
            range = try? ActivityCalendar.dateRange(from: selectedDate, through: endDate, calendar: calendar)
        }
    }
}
