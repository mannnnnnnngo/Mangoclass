import SwiftUI
import AppKit

/// Publishes a tick once per second so the countdown stays live.
final class Ticker: ObservableObject {
    static let shared = Ticker()
    @Published var now = Date()
    private var timer: Timer?

    private init() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(DS.bone).frame(height: 1) }
}

struct PanelView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var ticker = Ticker.shared
    @ObservedObject var updater = Updater.shared

    private var snap: ScheduleSnapshot { Engine.snapshot(now: ticker.now, data: store.data) }

    var body: some View {
        let s = snap
        VStack(spacing: 0) {
            UpdateBanner()
            header(s)
            Hairline()
            eventsStrip(s)
            hero(s)
            Hairline()
            upNext(s)
            Hairline()
            timeline(s)
            Hairline()
            footer
        }
        .frame(width: 344)
        .background(DS.signalWhite)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusLargeCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusLargeCard, style: .continuous)
                .strokeBorder(DS.bone, lineWidth: 1)
        )
        // The panel is sized from its content when it opens, so the update strip appearing
        // or being dismissed while it's already open has to nudge the window to match.
        .onChange(of: updater.status) { _, _ in PanelController.shared.refit() }
        .onChange(of: updater.pendingBannerDismissed) { _, _ in PanelController.shared.refit() }
        .onChange(of: s.today.events) { _, _ in PanelController.shared.refit() }
    }

    // MARK: - Header

    private func header(_ s: ScheduleSnapshot) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                AppBadge(iconSize: 16, textSize: 13)
                Spacer(minLength: 8)
                Badge(text: badgeTitle(s.today), accent: s.today.accent, filled: s.today.isSpecial)
            }
            // The date keeps its own line: pairing it with the app name on one row left
            // the badge nowhere to go on long day titles ("Parent-Teacher Conference").
            HStack {
                MicroLabel(text: dateLine(s.now), color: DS.ash, size: 10)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func dateLine(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE · MMM d"
        return f.string(from: date)
    }

    private func badgeTitle(_ day: ResolvedDay) -> String {
        switch day.kind {
        case .rotation(let r): return "\(r.name) Day"
        case .special(let sp): return sp.name
        case .weekend: return "Weekend"
        case .holiday: return day.title
        case .unscheduled: return day.title
        }
    }

    // MARK: - Events

    /// Today's events, sitting between the header and the countdown. It only appears on a
    /// day that has any, and it's the one part of the panel that never affects the clock
    /// below it — the timeline is resolved from the schedule alone.
    @ViewBuilder
    private func eventsStrip(_ s: ScheduleSnapshot) -> some View {
        if !s.today.events.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FlowRow(spacing: 5) {
                    ForEach(s.today.events) { ev in
                        EventChip(event: ev)
                    }
                }
                if let note = s.today.events.compactMap({ noteLine($0) }).first {
                    Text(note)
                        .font(DS.text(11))
                        .foregroundStyle(DS.ash)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            Hairline()
        }
    }

    private func noteLine(_ event: SchoolEvent) -> String? {
        let note = event.note.trimmingCharacters(in: .whitespaces)
        return note.isEmpty ? nil : note
    }

    // MARK: - Hero

    private func hero(_ s: ScheduleSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(s.phase == .inClass ? DS.emerald : DS.fog)
                    .frame(width: 6, height: 6)
                MicroLabel(text: s.phase.label, color: DS.ash, size: 9)
                Spacer(minLength: 4)
                if let sub = rotationNote(s.today) {
                    MicroLabel(text: sub, color: DS.fog, size: 9)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(headline(s))
                    .font(DS.display(30, .heavy))
                    .tracking(DS.em(-0.04, 30))
                    .foregroundStyle(DS.onyx)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                if let detail = subhead(s) {
                    Text(detail)
                        .font(DS.mono(11, .regular))
                        .foregroundStyle(DS.slate)
                        .lineLimit(1)
                }
            }

            if s.phase == .noSchool && s.upNext == nil {
                Text("No classes scheduled. Add some in Edit Schedules.")
                    .font(DS.text(12))
                    .foregroundStyle(DS.ash)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let t = Engine.hms(s.secondsRemaining)
                HStack(spacing: 8) {
                    tile(t.h, "Hours")
                    tile(t.m, "Minutes")
                    tile(t.s, "Seconds")
                }
                MicroLabel(text: s.phase == .inClass ? "left in this class" : "until it starts",
                           color: DS.fog, size: 9)
            }

            if s.phase == .inClass {
                DSProgressBar(value: s.progress, tint: s.today.accent.color)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func headline(_ s: ScheduleSnapshot) -> String {
        if let c = s.current { return c.name }
        switch s.phase {
        case .afterSchool: return "All done"
        case .noSchool:
            switch s.today.kind {
            case .weekend: return "Weekend"
            case .holiday: return s.today.title
            default: return "Nothing scheduled"
            }
        default: return s.upNext?.period.name ?? "—"
        }
    }

    private func subhead(_ s: ScheduleSnapshot) -> String? {
        if let c = s.current { return c.rangeAndPlace }
        if let note = s.today.note { return note }
        if s.phase == .afterSchool, let last = s.today.periods.last { return "Ended \(last.endText)" }
        return nil
    }

    /// Surfaces what the cycle is doing behind a special day, or which weekday rule is
    /// bending today's times — either way, why the clock isn't the usual one.
    private func rotationNote(_ day: ResolvedDay) -> String? {
        if day.isSpecial, let under = day.underlyingRotation {
            let paused = Store.shared.data.override(on: Rotation.dayKey(day.date))?.pausesRotation ?? false
            return paused ? "\(under.name) day pushed" : "\(under.name) day underneath"
        }
        return day.weekdayShape?.name
    }

    private func tile(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%02d", max(0, value)))
                .font(DS.display(28, .heavy))
                .tracking(DS.em(-0.04, 28))
                .foregroundStyle(DS.onyx)
                .monospacedDigit()
            MicroLabel(text: label, color: DS.ash, size: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).fill(DS.mist)
        )
    }

    // MARK: - Up next

    private func upNext(_ s: ScheduleSnapshot) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                MicroLabel(text: "Up next", color: DS.ash, size: 9)
                if let n = s.upNext {
                    Text(n.period.name)
                        .font(DS.text(14, .bold))
                        .foregroundStyle(DS.inkBlack)
                        .lineLimit(1)
                    Text(nextDetail(n))
                        .font(DS.mono(10, .regular))
                        .foregroundStyle(DS.slate)
                        .lineLimit(1)
                } else {
                    Text("Nothing ahead")
                        .font(DS.text(14, .bold))
                        .foregroundStyle(DS.fog)
                }
            }
            Spacer(minLength: 8)
            if let n = s.upNext {
                Text(Engine.compact(n.secondsUntilStart, showSeconds: n.secondsUntilStart < 3600))
                    .font(DS.mono(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(DS.slate)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.mist))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func nextDetail(_ n: UpNext) -> String {
        var parts: [String] = []
        if let day = n.dayLabel { parts.append("\(day) · \(n.day.title)") }
        parts.append(n.period.rangeText)
        if n.period.hasLocation { parts.append(n.period.location) }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Timeline

    @ViewBuilder
    private func timeline(_ s: ScheduleSnapshot) -> some View {
        if s.today.periods.isEmpty {
            HStack {
                Text(emptyDayLine(s.today))
                    .font(DS.text(12))
                    .foregroundStyle(DS.ash)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        } else {
            // Only scroll when the day genuinely overflows — otherwise lay the rows out
            // plainly so the panel window can size itself exactly from fittingSize.
            let rows = VStack(spacing: 2) {
                ForEach(s.today.periods) { p in
                    row(p, s)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if CGFloat(s.today.periods.count) * 32 + 20 > 200 {
                ScrollView { rows }.frame(height: 200)
            } else {
                rows
            }
        }
    }

    private func emptyDayLine(_ day: ResolvedDay) -> String {
        switch day.kind {
        case .weekend: return "Enjoy the weekend."
        case .holiday: return day.title == "No School" ? "No school today." : "\(day.title) — no classes."
        default: return "No classes on this day."
        }
    }

    private func row(_ p: Period, _ s: ScheduleSnapshot) -> some View {
        let isCurrent = p.id == s.current?.id
        let isPast = Engine.secondsIntoDay(s.now) >= p.end * 60
        return HStack(spacing: 10) {
            Capsule()
                .fill(isCurrent ? s.today.accent.color : DS.bone)
                .frame(width: 3, height: 20)
            Text(p.name)
                .font(DS.text(12, isCurrent ? .bold : .medium))
                .foregroundStyle(isPast ? DS.fog : (isCurrent ? DS.inkBlack : DS.carbon))
                .lineLimit(1)
            if p.hasLocation {
                Text(p.location)
                    .font(DS.mono(9, .medium))
                    .foregroundStyle(isPast ? DS.fog : DS.slate)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(isPast ? Color.clear : DS.plaster))
            }
            Spacer(minLength: 8)
            Text(p.rangeText)
                .font(DS.mono(10, .regular))
                .foregroundStyle(isPast ? DS.fog : DS.ash)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? DS.mist : Color.clear)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            PillButton(title: "Edit Schedules", icon: "slider.horizontal.3", kind: .primary, compact: true) {
                PanelController.shared.hide()
                SettingsWindow.shared.show()
            }
            Spacer()
            // Which version you're running, always in sight. Clicking it opens Updates.
            Button {
                PanelController.shared.hide()
                SettingsWindow.shared.show(tab: .updates)
            } label: {
                MicroLabel(text: "v\(updater.currentVersionString)", color: DS.fog, size: 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("mangoclass \(updater.currentVersionString) — check for updates")

            PillButton(title: "Quit", kind: .quiet, compact: true) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
