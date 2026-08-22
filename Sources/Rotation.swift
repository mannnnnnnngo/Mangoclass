import Foundation

/// What a given calendar date actually turns into.
struct ResolvedDay {
    enum Kind {
        case rotation(RotationDay)
        case special(SpecialDay)
        case weekend
        case holiday      // an override with no schedule attached
        case unscheduled  // a rotation day that has no classes in it
    }

    var date: Date
    var kind: Kind
    var title: String
    var accent: Accent
    var periods: [Period]
    var note: String?

    var isSchoolDay: Bool { !periods.isEmpty }

    var isSpecial: Bool {
        if case .special = kind { return true }
        return false
    }

    /// The rotation slot running underneath, even on a special day that hides it.
    var underlyingRotation: RotationDay?

    /// The weekday rule that reshaped the times, when one applied.
    var weekdayShape: WeekdayShape?
}

enum Rotation {
    static var calendar: Calendar { Calendar.current }

    // MARK: - Day keys

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { keyFormatter.string(from: date) }

    static func date(fromKey key: String) -> Date? {
        keyFormatter.date(from: key).map { calendar.startOfDay(for: $0) }
    }

    // MARK: - Weekday counting

    /// Monday, January 1 2001 — the reference point for counting weekdays.
    private static let epoch: Date = {
        var c = DateComponents()
        c.year = 2001; c.month = 1; c.day = 1
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    static func isWeekend(_ date: Date) -> Bool {
        let wd = calendar.component(.weekday, from: date)
        return wd == 1 || wd == 7
    }

    static func snapToWeekday(_ date: Date) -> Date {
        var d = calendar.startOfDay(for: date)
        while isWeekend(d) { d = calendar.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    /// Weekdays elapsed since the epoch. Saturday and Sunday share the index of the
    /// Friday before them, which is what keeps weekends from ever advancing the cycle.
    static func weekdayIndex(_ date: Date) -> Int {
        let days = calendar.dateComponents([.day], from: epoch, to: calendar.startOfDay(for: date)).day ?? 0
        let weeks = Int(floor(Double(days) / 7.0))
        let remainder = days - weeks * 7 // 0 = Monday ... 6 = Sunday
        return weeks * 5 + min(remainder, 5)
    }

    // MARK: - Cycle position

    /// Weekdays before `date` that are skipped by a rotation-pausing override.
    private static func pausedWeekdaysBefore(_ date: Date, data: AppData) -> Int {
        let target = weekdayIndex(date)
        return data.overrides.reduce(into: 0) { total, ov in
            guard ov.pausesRotation,
                  let d = Rotation.date(fromKey: ov.dayKey),
                  !isWeekend(d),
                  weekdayIndex(d) < target
            else { return }
            total += 1
        }
    }

    /// The date's position in the cycle, with paused days removed so they don't consume a slot.
    private static func slot(_ date: Date, data: AppData) -> Int {
        weekdayIndex(date) - pausedWeekdaysBefore(date, data: data)
    }

    /// Which rotation day this date lands on, ignoring overrides and weekends.
    static func rotationDay(for date: Date, data: AppData) -> RotationDay? {
        guard !data.rotation.isEmpty else { return nil }
        let anchor = Rotation.date(fromKey: data.anchorDayKey) ?? snapToWeekday(Date())
        let n = data.rotation.count
        let anchorIndex = data.rotation.firstIndex { $0.id == data.anchorRotationID } ?? 0
        let diff = slot(date, data: data) - slot(anchor, data: data)
        let offset = ((diff % n) + n) % n
        return data.rotation[(anchorIndex + offset) % n]
    }

    // MARK: - Weekday rules

    /// The recurring rule for this date's weekday, if one is switched on.
    static func weekdayShape(for date: Date, data: AppData) -> WeekdayShape? {
        data.weekdayShape(weekday: calendar.component(.weekday, from: date))
    }

    // MARK: - Resolution

    static func resolve(_ date: Date, data: AppData) -> ResolvedDay {
        let day = calendar.startOfDay(for: date)
        let underlying = isWeekend(day) ? nil : rotationDay(for: day, data: data)

        // An override always wins for what's displayed.
        if let ov = data.override(on: dayKey(day)) {
            let note = ov.note.trimmingCharacters(in: .whitespaces)
            if let sid = ov.specialDayID, let special = data.specialDay(id: sid) {
                return ResolvedDay(date: day, kind: .special(special), title: special.name,
                                   accent: special.accent, periods: special.sorted,
                                   note: note.isEmpty ? nil : note, underlyingRotation: underlying)
            }
            return ResolvedDay(date: day, kind: .holiday, title: note.isEmpty ? "No School" : note,
                               accent: .ink, periods: [], note: nil, underlyingRotation: underlying)
        }

        if isWeekend(day) {
            return ResolvedDay(date: day, kind: .weekend, title: "Weekend", accent: .ink,
                               periods: [], note: nil, underlyingRotation: nil)
        }

        guard let rot = underlying else {
            return ResolvedDay(date: day, kind: .unscheduled, title: "No Schedule", accent: .ink,
                               periods: [], note: nil, underlyingRotation: nil)
        }

        // A weekday rule reshapes the letter that landed here — it never replaces it, and
        // it never touches a special day, which was written for that one date on purpose.
        let shape = weekdayShape(for: day, data: data)
        let periods = shape?.apply(to: rot.sorted) ?? rot.sorted

        return ResolvedDay(date: day, kind: periods.isEmpty ? .unscheduled : .rotation(rot),
                           title: rot.name, accent: rot.accent, periods: periods,
                           note: nil, underlyingRotation: rot, weekdayShape: shape)
    }
}
