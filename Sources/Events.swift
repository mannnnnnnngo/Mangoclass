import Foundation

// MARK: - Events

/// How an event decides which dates it lands on.
enum EventRepeat: String, Codable, CaseIterable, Identifiable {
    /// Only the exact dates in `dayKeys` — a field trip, picture day, one assembly.
    case dates
    /// Every Friday, every Tuesday — keyed to the weekday, so it never drifts.
    case weekly
    /// Every A day, every C day — keyed to the cycle, so it moves with the letter.
    case rotationDay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dates:       return "On dates I pick"
        case .weekly:      return "Every week"
        case .rotationDay: return "Every letter day"
        }
    }
}

/// Something happening on a day that isn't a class: House Shirts, picture day, a bake sale.
///
/// Events are deliberately *beside* the schedule rather than in it. Nothing here can add,
/// remove, move or reshape a `Period` — an event is a label attached to a date, and the
/// timeline it appears next to is resolved exactly as it would be without it. That's the
/// whole design: someone can pile on as many events as they like and their school day
/// still runs to the minute it always did.
struct SchoolEvent: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var accent: Accent = .pink
    /// SF Symbol drawn on the chip. Always falls back to a star if the name is unknown.
    var symbol: String = "star.fill"
    var note: String = ""
    /// Switched off keeps the event without it showing anywhere — a spirit week that's over.
    var isOn: Bool = true

    var repeats: EventRepeat = .dates

    /// `.dates` — the exact days, "yyyy-MM-dd", sorted.
    var dayKeys: [String] = []
    /// `.weekly` — `Calendar`'s numbering, 1 = Sunday … 7 = Saturday.
    var weekday: Int? = nil
    /// `.rotationDay` — which letter in the cycle it rides along with.
    var rotationDayID: UUID? = nil

    /// Optional bounds for a repeating event, so "House Shirts every A day" can stop when
    /// the term does instead of running forever. Ignored by `.dates`.
    var startsOn: String? = nil
    var endsOn: String? = nil

    /// An optional window inside the day, purely for display — "8:00 AM – 8:30 AM" on the
    /// chip. It never becomes a period and never touches the class times around it.
    var startMinute: Int? = nil
    var endMinute: Int? = nil

    var isAllDay: Bool { startMinute == nil }

    var timeText: String? {
        guard let startMinute else { return nil }
        guard let endMinute, endMinute > startMinute else { return Period.clock(startMinute) }
        return "\(Period.clock(startMinute)) – \(Period.clock(endMinute))"
    }

    var trimmedName: String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled Event" : t
    }

    // MARK: Matching

    /// Whether this event lands on a date.
    ///
    /// `rotationID` is the letter running underneath that date — passed in rather than
    /// looked up, because the caller has already worked it out and because a special day
    /// hides its letter without stopping the cycle beneath it.
    ///
    /// A date the user picked by hand always counts. A repeating rule only fires on days
    /// that actually have school, so "every Friday" doesn't turn up over spring break.
    func occurs(on date: Date, dayKey: String, rotationID: UUID?, isSchoolDay: Bool) -> Bool {
        guard isOn else { return false }

        switch repeats {
        case .dates:
            return dayKeys.contains(dayKey)

        case .weekly:
            guard isSchoolDay, let weekday else { return false }
            guard Rotation.calendar.component(.weekday, from: date) == weekday else { return false }
            return withinWindow(dayKey)

        case .rotationDay:
            guard isSchoolDay, let rotationDayID, rotationID == rotationDayID else { return false }
            return withinWindow(dayKey)
        }
    }

    private func withinWindow(_ dayKey: String) -> Bool {
        if let startsOn, dayKey < startsOn { return false }
        if let endsOn, dayKey > endsOn { return false }
        return true
    }

    // MARK: Editing helpers

    mutating func toggleDate(_ dayKey: String) {
        if let i = dayKeys.firstIndex(of: dayKey) {
            dayKeys.remove(at: i)
        } else {
            dayKeys.append(dayKey)
            dayKeys.sort()
        }
    }

    /// "Every A day", "Every Friday", "3 dates" — what the rule does, in one line.
    func summary(data: AppData) -> String {
        switch repeats {
        case .dates:
            let upcoming = dayKeys.filter { $0 >= Rotation.dayKey(Date()) }.count
            if dayKeys.isEmpty { return "No dates picked yet" }
            let total = "\(dayKeys.count) date\(dayKeys.count == 1 ? "" : "s")"
            return upcoming == 0 ? "\(total) · all in the past" : "\(total) · \(upcoming) still ahead"
        case .weekly:
            guard let weekday else { return "No weekday picked yet" }
            return "Every \(WeekdayShape.weekdayName(weekday))" + boundsText
        case .rotationDay:
            guard let rotationDayID, let day = data.rotationDay(id: rotationDayID) else {
                return "No letter picked yet"
            }
            return "Every \(day.name) day" + boundsText
        }
    }

    private var boundsText: String {
        switch (startsOn, endsOn) {
        case let (from?, to?): return " · \(short(from)) to \(short(to))"
        case let (from?, nil): return " · from \(short(from))"
        case let (nil, to?):   return " · until \(short(to))"
        default: return ""
        }
    }

    private func short(_ key: String) -> String {
        guard let d = Rotation.date(fromKey: key) else { return key }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    /// The icons offered in the picker. Anything else typed into the file still renders —
    /// this is a shortlist, not a whitelist.
    static let symbolChoices = [
        "star.fill", "tshirt.fill", "sparkles", "party.popper.fill", "flag.fill",
        "gift.fill", "bus.fill", "camera.fill", "sportscourt.fill", "music.note",
        "theatermasks.fill", "book.fill", "pencil.and.ruler.fill", "fork.knife",
        "heart.fill", "graduationcap.fill", "megaphone.fill", "calendar"
    ]
}
