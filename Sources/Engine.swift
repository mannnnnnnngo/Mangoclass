import Foundation

enum Phase {
    case inClass
    case passing
    case beforeSchool
    case afterSchool
    case noSchool

    var label: String {
        switch self {
        case .inClass: return "In class"
        case .passing: return "Passing period"
        case .beforeSchool: return "Before school"
        case .afterSchool: return "School's out"
        case .noSchool: return "No school"
        }
    }
}

struct UpNext {
    var period: Period
    var day: ResolvedDay
    /// Nil when the class is later today.
    var dayLabel: String?
    var secondsUntilStart: Int
}

struct ScheduleSnapshot {
    var now: Date
    var today: ResolvedDay
    var phase: Phase
    var current: Period?
    var upNext: UpNext?
    /// Seconds left in the current class, or until the next one begins.
    var secondsRemaining: Int
    /// 0...1 progress through the current class.
    var progress: Double
}

enum Engine {
    static func snapshot(now: Date = Date(), data: AppData) -> ScheduleSnapshot {
        let today = Rotation.resolve(now, data: data)
        let periods = today.periods
        let secondsNow = secondsIntoDay(now)

        guard !periods.isEmpty else {
            let next = findNextSchoolDay(after: now, data: data)
            return ScheduleSnapshot(now: now, today: today, phase: .noSchool, current: nil,
                                    upNext: next, secondsRemaining: next?.secondsUntilStart ?? 0,
                                    progress: 0)
        }

        if let current = periods.first(where: { secondsNow >= $0.start * 60 && secondsNow < $0.end * 60 }) {
            let remaining = current.end * 60 - secondsNow
            let total = max(1, (current.end - current.start) * 60)
            let elapsed = secondsNow - current.start * 60
            let laterToday = periods.first { $0.start * 60 > secondsNow }
            let next: UpNext? = laterToday.map {
                UpNext(period: $0, day: today, dayLabel: nil, secondsUntilStart: $0.start * 60 - secondsNow)
            } ?? findNextSchoolDay(after: now, data: data)
            return ScheduleSnapshot(now: now, today: today, phase: .inClass, current: current,
                                    upNext: next, secondsRemaining: remaining,
                                    progress: min(1, max(0, Double(elapsed) / Double(total))))
        }

        if let upcoming = periods.first(where: { $0.start * 60 > secondsNow }) {
            let untilStart = upcoming.start * 60 - secondsNow
            let phase: Phase = secondsNow < (periods.first?.start ?? 0) * 60 ? .beforeSchool : .passing
            return ScheduleSnapshot(now: now, today: today, phase: phase, current: nil,
                                    upNext: UpNext(period: upcoming, day: today, dayLabel: nil,
                                                   secondsUntilStart: untilStart),
                                    secondsRemaining: untilStart, progress: 0)
        }

        let next = findNextSchoolDay(after: now, data: data)
        return ScheduleSnapshot(now: now, today: today, phase: .afterSchool, current: nil,
                                upNext: next, secondsRemaining: next?.secondsUntilStart ?? 0, progress: 0)
    }

    // MARK: - Helpers

    static func secondsIntoDay(_ date: Date, calendar: Calendar = Rotation.calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    /// Walks forward for the first date that actually has classes on it.
    private static func findNextSchoolDay(after now: Date, data: AppData) -> UpNext? {
        let cal = Rotation.calendar
        var day = cal.startOfDay(for: now)
        for step in 1...30 {
            day = cal.date(byAdding: .day, value: 1, to: day)!
            let resolved = Rotation.resolve(day, data: data)
            guard let first = resolved.periods.first else { continue }
            let start = day.addingTimeInterval(TimeInterval(first.start * 60))
            let formatter = DateFormatter()
            formatter.dateFormat = step == 1 ? "'Tomorrow'" : "EEEE"
            return UpNext(period: first, day: resolved, dayLabel: formatter.string(from: day),
                          secondsUntilStart: max(0, Int(start.timeIntervalSince(now))))
        }
        return nil
    }

    // MARK: - Formatting

    static func hms(_ seconds: Int) -> (h: Int, m: Int, s: Int) {
        let t = max(0, seconds)
        return (t / 3600, (t % 3600) / 60, t % 60)
    }

    static func compact(_ seconds: Int, showSeconds: Bool) -> String {
        let (h, m, s) = hms(seconds)
        if showSeconds {
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return "\(max(1, m))m"
    }
}
