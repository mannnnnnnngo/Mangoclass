import Foundation

// MARK: - Period

struct Period: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Minutes from midnight.
    var start: Int
    /// Minutes from midnight.
    var end: Int
    /// Free text — room number, building, teacher, whatever. Blank by default.
    var location: String = ""

    var startText: String { Period.clock(start) }
    var endText: String { Period.clock(end) }
    var rangeText: String { "\(startText) – \(endText)" }

    var hasLocation: Bool { !location.trimmingCharacters(in: .whitespaces).isEmpty }

    /// "8:30 AM – 9:55 AM · Room 204"
    var rangeAndPlace: String {
        hasLocation ? "\(rangeText)  ·  \(location)" : rangeText
    }

    private enum Keys: String, CodingKey { case id, name, start, end, location }

    init(id: UUID = UUID(), name: String, start: Int, end: Int, location: String = "") {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.location = location
    }

    /// `location` was added after the first release, so treat it as optional on the way in.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        start = try c.decode(Int.self, forKey: .start)
        end = try c.decode(Int.self, forKey: .end)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
    }

    static func clock(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        var hour = m / 60
        let minute = m % 60
        let suffix = hour >= 12 ? "PM" : "AM"
        hour %= 12
        if hour == 0 { hour = 12 }
        return String(format: "%d:%02d %@", hour, minute, suffix)
    }
}

// MARK: - Accent

/// The accent palette, drawn from the design system's brand and conic-gradient stops.
enum Accent: String, Codable, CaseIterable, Identifiable {
    case violet, blue, teal, emerald, pink, orange, ink

    var id: String { rawValue }

    var hex: String {
        switch self {
        case .violet:  return "6647f0"
        case .blue:    return "0091ff"
        case .teal:    return "16c0a4"
        case .emerald: return "00c07a"
        case .pink:    return "fa24ce"
        case .orange:  return "fd9a46"
        case .ink:     return "202020"
        }
    }
}

// MARK: - Day templates

/// One slot in the repeating cycle. Two of these gives you A/B; three gives A/B/C, and so on.
struct RotationDay: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var accent: Accent
    var periods: [Period]

    var sorted: [Period] { periods.sorted { $0.start < $1.start } }
}

/// A named one-off schedule (assembly, half day, finals) that can be dropped onto any date.
struct SpecialDay: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var accent: Accent
    var periods: [Period]

    var sorted: [Period] { periods.sorted { $0.start < $1.start } }
}

/// Pins a specific calendar date to a special schedule, or to no school at all.
struct DateOverride: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// "yyyy-MM-dd".
    var dayKey: String
    /// nil means "no school that day".
    var specialDayID: UUID?
    /// When true this date is skipped by the cycle, so the letter it would have
    /// used lands on the next school day instead. When false the cycle carries on
    /// underneath and only the displayed schedule changes.
    var pausesRotation: Bool
    var note: String
}

// MARK: - Weekday shapes

/// A recurring change to whatever schedule lands on a given weekday.
///
/// Early-release Wednesday and late-start Friday aren't extra days in the cycle — they're
/// the same A or B day with its clock reshaped. They can't be rotation days, because a
/// rotation day drifts across the week; they can't be special days either, because those
/// have to be assigned one date at a time, forever. So they live here: a rule keyed to a
/// weekday, applied on top of whichever letter lands on it.
///
/// Every knob is optional, and the ones that are set are applied in the order they're
/// declared — resize, then shift, then land the finish time.
struct WeekdayShape: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// `Calendar`'s numbering: 1 = Sunday … 7 = Saturday.
    var weekday: Int
    var name: String
    var isOn: Bool = true
    /// The first class begins here and the rest of the day moves with it.
    var startAt: Int?
    /// Every class runs this many minutes, with the gaps between them kept as they are.
    var classLength: Int?
    /// The last class is cut back — or stretched — to finish exactly here.
    var lastClassEndsAt: Int?

    /// A rule with nothing set changes nothing; the editor uses this to stay quiet about it.
    var changesNothing: Bool { startAt == nil && classLength == nil && lastClassEndsAt == nil }

    static func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar(identifier: .gregorian).standaloneWeekdaySymbols
        guard (1...symbols.count).contains(weekday) else { return "Day \(weekday)" }
        return symbols[weekday - 1]
    }

    var weekdayName: String { WeekdayShape.weekdayName(weekday) }

    /// "Starts 9:00 AM · 45-minute classes · ends 4:00 PM" — what the rule does, in one line.
    var summary: String {
        var parts: [String] = []
        if let startAt { parts.append("starts \(Period.clock(startAt))") }
        if let classLength { parts.append("\(classLength)-minute classes") }
        if let lastClassEndsAt { parts.append("ends \(Period.clock(lastClassEndsAt))") }
        return parts.isEmpty ? "No changes yet" : parts.joined(separator: "  ·  ").capitalizedFirst
    }

    /// Reshapes a day's classes. The names, rooms and running order are never touched —
    /// only the clock — so this stays a view of the schedule rather than a second copy of it.
    func apply(to periods: [Period]) -> [Period] {
        var list = periods.sorted { $0.start < $1.start }
        guard !list.isEmpty else { return list }

        // Resize every class, carrying the gap that followed it along unchanged. Keeping
        // the gaps is what makes a 5-minute passing period stay 5 minutes.
        if let classLength {
            let gaps = zip(list, list.dropFirst()).map { max(0, $1.start - $0.end) }
            var cursor = list[0].start
            for i in list.indices {
                list[i].start = cursor
                list[i].end = cursor + max(1, classLength)
                cursor = list[i].end + (i < gaps.count ? gaps[i] : 0)
            }
        }

        // Slide the whole day so it opens at the right time.
        if let startAt, let first = list.first, first.start != startAt {
            let shift = startAt - first.start
            for i in list.indices {
                list[i].start += shift
                list[i].end += shift
            }
        }

        // Land the day on its finish time. Anything that would begin after the bell is
        // dropped and the class still running is cut back, rather than squeezing the
        // whole day — an early dismissal shortens the last period, it doesn't rush the
        // morning. A finish time before the day even starts is ignored as a typo.
        if let lastClassEndsAt, let firstStart = list.first?.start, lastClassEndsAt > firstStart {
            list.removeAll { $0.start >= lastClassEndsAt }
            if !list.isEmpty { list[list.count - 1].end = lastClassEndsAt }
        }

        return list
    }
}

private extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}

// MARK: - Stored data

struct AppData: Codable {
    var rotation: [RotationDay]
    var specialDays: [SpecialDay]
    var overrides: [DateOverride]
    /// Recurring per-weekday changes, applied on top of the rotation day that lands there.
    var weekdayShapes: [WeekdayShape]
    /// Labels attached to dates — House Shirts, picture day, a field trip. These sit
    /// alongside the schedule and can never alter it; see `SchoolEvent`.
    var events: [SchoolEvent]

    /// A weekday whose rotation slot the user pinned; everything else derives from it.
    var anchorDayKey: String
    var anchorRotationID: UUID

    var showClassNameInMenuBar: Bool
    var showDayLetterInMenuBar: Bool
    var showSecondsInMenuBar: Bool

    func rotationDay(id: UUID) -> RotationDay? { rotation.first { $0.id == id } }
    func specialDay(id: UUID) -> SpecialDay? { specialDays.first { $0.id == id } }
    func override(on key: String) -> DateOverride? { overrides.first { $0.dayKey == key } }
    func event(id: UUID) -> SchoolEvent? { events.first { $0.id == id } }

    /// The rule to run on a weekday, if there is a live one. Only the first is used, so
    /// two rules for the same weekday can't fight over the same day.
    func weekdayShape(weekday: Int) -> WeekdayShape? {
        weekdayShapes.first { $0.isOn && $0.weekday == weekday && !$0.changesNothing }
    }

    func weekdayShapeEntry(weekday: Int) -> WeekdayShape? {
        weekdayShapes.first { $0.weekday == weekday }
    }

    // MARK: Defaults

    private static func p(_ n: String, _ sh: Int, _ sm: Int, _ eh: Int, _ em: Int) -> Period {
        Period(name: n, start: sh * 60 + sm, end: eh * 60 + em)
    }

    /// The starter day: seven 45-minute classes with 5-minute passing periods, lunch in
    /// the middle, and a longer advisory at the end. Every name here is a placeholder —
    /// Settings → Schedules is where they get replaced with real ones.
    static func defaultPeriods() -> [Period] {
        [
            p("Period 1", 8, 25, 9, 15),
            p("Period 2", 9, 20, 10, 5),
            p("Period 3", 10, 10, 10, 55),
            p("Period 4", 11, 0, 11, 45),
            p("Lunch & Recess", 11, 50, 12, 35),
            p("Period 5", 12, 40, 13, 25),
            p("Period 6", 13, 30, 14, 15),
            p("Period 7", 14, 20, 15, 5),
            p("Advisory", 15, 10, 16, 0),
        ]
    }

    static var seeded: AppData {
        let a = RotationDay(name: "A", accent: .violet, periods: defaultPeriods())
        let b = RotationDay(name: "B", accent: .blue, periods: defaultPeriods())
        let assembly = SpecialDay(name: "Assembly", accent: .pink, periods: [
            p("Assembly", 8, 25, 9, 30),
            p("Period 1", 9, 40, 10, 30),
            p("Period 2", 10, 40, 11, 30),
            p("Lunch & Recess", 11, 50, 12, 35),
            p("Period 3", 12, 45, 13, 35),
            p("Period 4", 13, 45, 14, 35),
            p("Advisory", 14, 45, 15, 30),
        ])
        let halfDay = SpecialDay(name: "Half Day", accent: .orange, periods: [
            p("Period 1", 8, 25, 9, 5),
            p("Period 2", 9, 10, 9, 50),
            p("Period 3", 9, 55, 10, 35),
            p("Period 4", 10, 40, 11, 20),
            p("Period 5", 11, 25, 12, 5),
        ])
        // Two rules most schools have some version of: a Wednesday that lets out early,
        // and a Friday that starts late. Both are switched on out of the box so the
        // Weekdays tab shows a working example rather than an empty screen.
        let earlyWednesday = WeekdayShape(weekday: 4, name: "Early-Release Wednesday",
                                          lastClassEndsAt: 15 * 60 + 25)
        let lateFriday = WeekdayShape(weekday: 6, name: "Late-Start Friday",
                                      startAt: 9 * 60, classLength: 45,
                                      lastClassEndsAt: 16 * 60)
        return AppData(
            rotation: [a, b],
            specialDays: [assembly, halfDay],
            overrides: [],
            weekdayShapes: [earlyWednesday, lateFriday],
            events: [SchoolEvent(name: "House Shirts", accent: .pink, symbol: "tshirt.fill",
                                 note: "Wear your house colours",
                                 repeats: .weekly, weekday: 6)],
            anchorDayKey: Rotation.dayKey(Rotation.snapToWeekday(Date())),
            anchorRotationID: a.id,
            showClassNameInMenuBar: true,
            showDayLetterInMenuBar: true,
            showSecondsInMenuBar: true
        )
    }

    // MARK: Decoding (with migration off the old A/B-only format)

    private enum Keys: String, CodingKey {
        case rotation, specialDays, overrides, weekdayShapes, events, anchorDayKey, anchorRotationID
        case showClassNameInMenuBar, showDayLetterInMenuBar, showSecondsInMenuBar
        // Legacy
        case scheduleA, scheduleB, anchorDate, anchorLetter
    }

    init(rotation: [RotationDay], specialDays: [SpecialDay], overrides: [DateOverride],
         weekdayShapes: [WeekdayShape] = [], events: [SchoolEvent] = [],
         anchorDayKey: String, anchorRotationID: UUID,
         showClassNameInMenuBar: Bool, showDayLetterInMenuBar: Bool, showSecondsInMenuBar: Bool) {
        self.rotation = rotation
        self.specialDays = specialDays
        self.overrides = overrides
        self.weekdayShapes = weekdayShapes
        self.events = events
        self.anchorDayKey = anchorDayKey
        self.anchorRotationID = anchorRotationID
        self.showClassNameInMenuBar = showClassNameInMenuBar
        self.showDayLetterInMenuBar = showDayLetterInMenuBar
        self.showSecondsInMenuBar = showSecondsInMenuBar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)

        showClassNameInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showClassNameInMenuBar) ?? true
        showDayLetterInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showDayLetterInMenuBar) ?? true
        showSecondsInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showSecondsInMenuBar) ?? true
        specialDays = try c.decodeIfPresent([SpecialDay].self, forKey: .specialDays) ?? []
        overrides = try c.decodeIfPresent([DateOverride].self, forKey: .overrides) ?? []
        weekdayShapes = try c.decodeIfPresent([WeekdayShape].self, forKey: .weekdayShapes) ?? []
        // Added in 1.1. Absent in every file written before it, so it decodes to an empty
        // list rather than failing — an upgrade brings the events feature in switched off
        // and leaves the schedule that's already there exactly as it was.
        events = try c.decodeIfPresent([SchoolEvent].self, forKey: .events) ?? []

        if let rotation = try c.decodeIfPresent([RotationDay].self, forKey: .rotation), !rotation.isEmpty {
            self.rotation = rotation
            anchorDayKey = try c.decodeIfPresent(String.self, forKey: .anchorDayKey)
                ?? Rotation.dayKey(Rotation.snapToWeekday(Date()))
            let storedID = try c.decodeIfPresent(UUID.self, forKey: .anchorRotationID)
            anchorRotationID = rotation.contains { $0.id == storedID } ? storedID! : rotation[0].id
        } else {
            // Old file: two fixed schedules keyed A and B.
            let a = RotationDay(name: "A", accent: .violet,
                                periods: try c.decodeIfPresent([Period].self, forKey: .scheduleA) ?? AppData.defaultPeriods())
            let b = RotationDay(name: "B", accent: .blue,
                                periods: try c.decodeIfPresent([Period].self, forKey: .scheduleB) ?? AppData.defaultPeriods())
            self.rotation = [a, b]
            let legacyDate = try c.decodeIfPresent(Date.self, forKey: .anchorDate) ?? Date()
            anchorDayKey = Rotation.dayKey(Rotation.snapToWeekday(legacyDate))
            let legacyLetter = try c.decodeIfPresent(String.self, forKey: .anchorLetter) ?? "A"
            anchorRotationID = legacyLetter == "B" ? b.id : a.id
            if specialDays.isEmpty { specialDays = AppData.seeded.specialDays }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(specialDays, forKey: .specialDays)
        try c.encode(overrides, forKey: .overrides)
        try c.encode(weekdayShapes, forKey: .weekdayShapes)
        try c.encode(events, forKey: .events)
        try c.encode(anchorDayKey, forKey: .anchorDayKey)
        try c.encode(anchorRotationID, forKey: .anchorRotationID)
        try c.encode(showClassNameInMenuBar, forKey: .showClassNameInMenuBar)
        try c.encode(showDayLetterInMenuBar, forKey: .showDayLetterInMenuBar)
        try c.encode(showSecondsInMenuBar, forKey: .showSecondsInMenuBar)
    }
}
