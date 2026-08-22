import Foundation
import Combine

/// Owns the saved schedules and writes them to disk on every change.
final class Store: ObservableObject {
    static let shared = Store()

    @Published var data: AppData {
        didSet { save() }
    }

    private let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassSchedule", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("schedule.json")

        let raw = try? Data(contentsOf: fileURL)
        if let raw, let decoded = try? JSONDecoder().decode(AppData.self, from: raw) {
            data = decoded
        } else {
            // A file that exists but won't decode is somebody's whole timetable. New fields
            // are always decoded with `decodeIfPresent`, so this shouldn't be reachable on
            // an upgrade — but if it ever is, the original is set aside under a dated name
            // instead of being overwritten by the starter schedule.
            if let raw, !raw.isEmpty {
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let rescue = base.appendingPathComponent("schedule-unreadable-\(stamp).json")
                try? raw.write(to: rescue, options: .atomic)
            }
            data = .seeded
            save() // didSet doesn't fire during init, so write the starter schedule out now.
        }
    }

    var storageLocation: URL { fileURL }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? encoder.encode(data) else { return }
        try? raw.write(to: fileURL, options: .atomic)
    }

    // MARK: - Rotation days

    func addRotationDay() {
        let used = Set(data.rotation.map(\.name))
        let name = (0..<26).lazy
            .map { String(UnicodeScalar("A".unicodeScalars.first!.value + UInt32($0))!) }
            .first { !used.contains($0) } ?? "Day \(data.rotation.count + 1)"
        let accent = Accent.allCases[data.rotation.count % Accent.allCases.count]
        data.rotation.append(RotationDay(name: name, accent: accent,
                                         periods: AppData.defaultPeriods()))
    }

    /// Adds a day already filled in — used by the picture importer.
    @discardableResult
    func addRotationDay(named name: String, periods: [Period]) -> UUID {
        let used = Set(data.rotation.map(\.name))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = (0..<26).lazy
            .map { String(UnicodeScalar("A".unicodeScalars.first!.value + UInt32($0))!) }
            .first { !used.contains($0) } ?? "Day \(data.rotation.count + 1)"
        let accent = Accent.allCases[data.rotation.count % Accent.allCases.count]
        let day = RotationDay(name: trimmed.isEmpty ? fallback : trimmed, accent: accent,
                              periods: periods.sorted { $0.start < $1.start })
        data.rotation.append(day)
        return day.id
    }

    func removeRotationDay(id: UUID) {
        guard data.rotation.count > 1 else { return } // never leave the cycle empty
        data.rotation.removeAll { $0.id == id }
        if !data.rotation.contains(where: { $0.id == data.anchorRotationID }) {
            data.anchorRotationID = data.rotation[0].id
        }
    }

    func moveRotationDay(id: UUID, by delta: Int) {
        guard let i = data.rotation.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard data.rotation.indices.contains(j) else { return }
        data.rotation.swapAt(i, j)
    }

    /// Pins today (or the next weekday, if it's the weekend) to a rotation day.
    func setToday(_ rotationID: UUID) {
        data.anchorDayKey = Rotation.dayKey(Rotation.snapToWeekday(Date()))
        data.anchorRotationID = rotationID
    }

    // MARK: - Special days

    func addSpecialDay() {
        let accent = Accent.allCases[(data.specialDays.count + 4) % Accent.allCases.count]
        data.specialDays.append(SpecialDay(name: "New Special Day", accent: accent,
                                           periods: AppData.defaultPeriods()))
    }

    @discardableResult
    func addSpecialDay(named name: String, periods: [Period]) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let accent = Accent.allCases[(data.specialDays.count + 4) % Accent.allCases.count]
        let day = SpecialDay(name: trimmed.isEmpty ? "Imported Day" : trimmed, accent: accent,
                             periods: periods.sorted { $0.start < $1.start })
        data.specialDays.append(day)
        return day.id
    }

    func removeSpecialDay(id: UUID) {
        data.specialDays.removeAll { $0.id == id }
        // Any date pointing at it becomes a plain no-school day.
        for i in data.overrides.indices where data.overrides[i].specialDayID == id {
            data.overrides[i].specialDayID = nil
        }
    }

    // MARK: - Periods (shared by both kinds of day)

    func periods(rotationID: UUID) -> [Period] { data.rotationDay(id: rotationID)?.sorted ?? [] }
    func periods(specialID: UUID) -> [Period] { data.specialDay(id: specialID)?.sorted ?? [] }

    func setPeriods(_ periods: [Period], rotationID: UUID) {
        guard let i = data.rotation.firstIndex(where: { $0.id == rotationID }) else { return }
        data.rotation[i].periods = periods
    }

    func setPeriods(_ periods: [Period], specialID: UUID) {
        guard let i = data.specialDays.firstIndex(where: { $0.id == specialID }) else { return }
        data.specialDays[i].periods = periods
    }

    static func appended(to list: [Period]) -> [Period] {
        let lastEnd = list.map(\.end).max() ?? (8 * 60)
        let start = min(lastEnd + 10, 23 * 60)
        return (list + [Period(name: "New Class", start: start, end: min(start + 50, 23 * 60 + 59))])
            .sorted { $0.start < $1.start }
    }

    // MARK: - Weekday rules

    /// Starts a rule for a weekday, pre-filled from whatever that weekday currently looks
    /// like so the fields open on real times instead of placeholders.
    @discardableResult
    func addWeekdayShape(weekday: Int) -> UUID {
        if let existing = data.weekdayShapeEntry(weekday: weekday) { return existing.id }
        let shape = WeekdayShape(weekday: weekday, name: "\(WeekdayShape.weekdayName(weekday))s")
        data.weekdayShapes.append(shape)
        data.weekdayShapes.sort { $0.weekday < $1.weekday }
        return shape.id
    }

    func removeWeekdayShape(id: UUID) {
        data.weekdayShapes.removeAll { $0.id == id }
    }

    func updateWeekdayShape(id: UUID, transform: (inout WeekdayShape) -> Void) {
        guard let i = data.weekdayShapes.firstIndex(where: { $0.id == id }) else { return }
        transform(&data.weekdayShapes[i])
    }

    // MARK: - Date overrides

    func setOverride(date: Date, specialDayID: UUID?, pausesRotation: Bool, note: String) {
        let key = Rotation.dayKey(date)
        let entry = DateOverride(dayKey: key, specialDayID: specialDayID,
                                 pausesRotation: pausesRotation, note: note)
        if let i = data.overrides.firstIndex(where: { $0.dayKey == key }) {
            data.overrides[i] = DateOverride(id: data.overrides[i].id, dayKey: key,
                                             specialDayID: specialDayID,
                                             pausesRotation: pausesRotation, note: note)
        } else {
            data.overrides.append(entry)
        }
        data.overrides.sort { $0.dayKey < $1.dayKey }
    }

    func removeOverride(id: UUID) {
        data.overrides.removeAll { $0.id == id }
    }

    func updateOverride(id: UUID, transform: (inout DateOverride) -> Void) {
        guard let i = data.overrides.firstIndex(where: { $0.id == id }) else { return }
        transform(&data.overrides[i])
    }

    // MARK: - Events
    //
    // Nothing in this section touches `rotation`, `specialDays` or `weekdayShapes`. Adding,
    // editing and deleting events leaves every schedule exactly as it was.

    @discardableResult
    func addEvent(named name: String = "New Event", on dayKey: String? = nil) -> UUID {
        let accent = Accent.allCases[(data.events.count + 2) % Accent.allCases.count]
        var event = SchoolEvent(name: name, accent: accent)
        if let dayKey { event.dayKeys = [dayKey] }
        data.events.append(event)
        return event.id
    }

    func removeEvent(id: UUID) {
        data.events.removeAll { $0.id == id }
    }

    func updateEvent(id: UUID, transform: (inout SchoolEvent) -> Void) {
        guard let i = data.events.firstIndex(where: { $0.id == id }) else { return }
        transform(&data.events[i])
    }

    /// Adds or removes a single date from a `.dates` event — what the calendar's
    /// event chips toggle.
    func toggleEventDate(id: UUID, date: Date) {
        updateEvent(id: id) { event in
            guard event.repeats == .dates else { return }
            event.toggleDate(Rotation.dayKey(date))
        }
    }

    /// Drops dates in the past from one-off events, so a spirit week from last year stops
    /// cluttering the list. Repeating events are left alone.
    func pruneExpiredEventDates() {
        let todayKey = Rotation.dayKey(Date())
        for i in data.events.indices where data.events[i].repeats == .dates {
            data.events[i].dayKeys.removeAll { $0 < todayKey }
        }
    }

    // MARK: - Date overrides (continued)

    /// Drops overrides for dates that have already passed.
    func pruneExpiredOverrides() {
        let todayKey = Rotation.dayKey(Date())
        data.overrides.removeAll { $0.dayKey < todayKey }
    }
}
