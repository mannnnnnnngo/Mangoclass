import SwiftUI
import AppKit
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable {
    case schedules = "Schedules"
    case weekdays = "Weekdays"
    case special = "Special Days"
    case calendar = "Calendar"
    case general = "General"
    case updates = "Updates"

    var id: String { rawValue }
}

/// Which tab is showing. An object rather than `@State` so the menu bar can open Settings
/// straight onto a particular tab — "Check for Updates…" lands on Updates.
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .schedules
}

struct SettingsView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var nav = SettingsNavigation.shared
    @ObservedObject var updater = Updater.shared

    private var tab: SettingsTab { nav.tab }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Hairline()
            Group {
                switch tab {
                case .schedules: SchedulesTab()
                case .weekdays:  WeekdaysTab()
                case .special:   SpecialDaysTab()
                case .calendar:  CalendarTab()
                case .general:   GeneralTab()
                case .updates:   UpdatesTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(DS.signalWhite)
        .frame(width: 760, height: 600)
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            // Leaves room for the traffic lights.
            Spacer().frame(width: 62)

            AppBadge(iconSize: 18, textSize: 15)

            Spacer()

            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { t in
                    Chip(title: t.rawValue, selected: tab == t) {
                        withAnimation(DS.state) { nav.tab = t }
                    }
                    // A dot on the Updates chip is the whole notification, once you're
                    // already in here — no badge counts, no red.
                    .overlay(alignment: .topTrailing) {
                        if t == .updates, updater.status.manifest != nil, tab != t {
                            Circle()
                                .fill(DS.brandViolet)
                                .frame(width: 6, height: 6)
                                .offset(x: 1, y: -1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

// MARK: - Shared period editor

struct PeriodListEditor: View {
    @Binding var periods: [Period]
    var accent: Accent
    /// Which day the picture importer should fill in by default. nil hides the button.
    var importInto: ImportDestination? = nil

    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MicroLabel(text: "Class", size: 9).frame(maxWidth: .infinity, alignment: .leading)
                MicroLabel(text: "Room", size: 9).frame(width: 108, alignment: .leading)
                MicroLabel(text: "Starts", size: 9).frame(width: 88, alignment: .center)
                MicroLabel(text: "Ends", size: 9).frame(width: 88, alignment: .center)
                Spacer().frame(width: 24)
            }
            .padding(.horizontal, 2)

            if periods.isEmpty {
                HStack {
                    Text("No classes yet.")
                        .font(DS.text(12))
                        .foregroundStyle(DS.ash)
                    Spacer()
                }
                .padding(.vertical, 18)
            } else {
                ForEach($periods) { $p in
                    HStack(spacing: 8) {
                        DSTextField(placeholder: "Class name", text: $p.name)
                            .frame(maxWidth: .infinity)
                        DSTextField(placeholder: "", text: $p.location, font: DS.mono(12, .medium))
                            .frame(width: 108)
                        TimeField(minutes: $p.start).frame(width: 88)
                        TimeField(minutes: $p.end).frame(width: 88)
                        IconButton(icon: "trash", hoverTint: Color(hex: "d92d20"), help: "Delete this class") {
                            periods.removeAll { $0.id == p.id }
                        }
                        .frame(width: 24)
                    }
                }
            }

            HStack(spacing: 8) {
                PillButton(title: "Add Class", icon: "plus", kind: .ghost, compact: true) {
                    periods = Store.appended(to: periods)
                }
                if let destination = importInto {
                    PillButton(title: "From a Picture", icon: "camera", kind: .ghost, compact: true) {
                        importing = true
                    }
                    .sheet(isPresented: $importing) {
                        ImportSheet(initialDestination: destination)
                    }
                }
                PillButton(title: "Sort by Time", kind: .quiet, compact: true) {
                    withAnimation(DS.state) { periods.sort { $0.start < $1.start } }
                }
                Spacer()
                if let last = periods.map(\.end).max(), let first = periods.map(\.start).min() {
                    MicroLabel(text: "\(periods.count) classes · \(Period.clock(first))–\(Period.clock(last))",
                               color: DS.fog, size: 9)
                }
            }
            .padding(.top, 2)
        }
    }
}

struct AccentPicker: View {
    @Binding var accent: Accent

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Accent.allCases) { a in
                Button {
                    withAnimation(DS.hover) { accent = a }
                } label: {
                    Circle()
                        .fill(a.color)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().strokeBorder(DS.signalWhite, lineWidth: accent == a ? 2.5 : 0)
                        )
                        .overlay(
                            Circle().strokeBorder(accent == a ? a.color : Color.clear, lineWidth: 1.5)
                                .padding(-2.5)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Schedules

struct SchedulesTab: View {
    @ObservedObject var store = Store.shared
    @State private var selection: UUID?
    @State private var importingNewDay = false

    private var selectedID: UUID? {
        if let s = selection, store.data.rotation.contains(where: { $0.id == s }) { return s }
        return store.data.rotation.first?.id
    }

    var body: some View { ScrollView { content } }

    @ViewBuilder var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    MicroLabel(text: "The cycle", size: 9)
                    HStack(spacing: 6) {
                        ForEach(store.data.rotation) { day in
                            Chip(title: day.name, accent: day.accent, selected: selectedID == day.id) {
                                selection = day.id
                            }
                        }
                        PillButton(title: "Add Day", icon: "plus", kind: .ghost, compact: true) {
                            store.addRotationDay()
                            selection = store.data.rotation.last?.id
                        }
                        PillButton(title: "New Day from a Picture", icon: "camera", kind: .quiet, compact: true) {
                            importingNewDay = true
                        }
                        .sheet(isPresented: $importingNewDay) {
                            ImportSheet(initialDestination: .newRotation)
                        }
                    }
                    Text(cycleDescription)
                        .font(DS.text(12))
                        .foregroundStyle(DS.slate)
                }

                Hairline()

                if let id = selectedID,
                   let idx = store.data.rotation.firstIndex(where: { $0.id == id }) {
                    dayEditor(idx)
                }
            }
            .padding(24)
    }

    private var cycleDescription: String {
        let names = store.data.rotation.map(\.name)
        guard names.count > 1 else {
            return "One day in the cycle — every school day uses this schedule."
        }
        return "Repeats every \(names.count) school days: \(names.joined(separator: " → ")) → \(names[0])…"
    }

    @ViewBuilder
    private func dayEditor(_ idx: Int) -> some View {
        let day = store.data.rotation[idx]
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                DSTextField(placeholder: "Name", text: $store.data.rotation[idx].name,
                            font: DS.display(15, .bold))
                    .frame(width: 130)
                AccentPicker(accent: $store.data.rotation[idx].accent)
                Spacer()
                IconButton(icon: "chevron.left", help: "Move earlier in the cycle") {
                    store.moveRotationDay(id: day.id, by: -1)
                }
                IconButton(icon: "chevron.right", help: "Move later in the cycle") {
                    store.moveRotationDay(id: day.id, by: 1)
                }
                if store.data.rotation.count > 1 {
                    PillButton(title: "Delete Day", kind: .danger, compact: true) {
                        store.removeRotationDay(id: day.id)
                        selection = store.data.rotation.first?.id
                    }
                }
            }

            PeriodListEditor(periods: $store.data.rotation[idx].periods, accent: day.accent,
                             importInto: .rotation(day.id))
        }
    }
}

// MARK: - Weekdays

/// The flat pill switch on its own, for rows that need a control between the label and the
/// switch. `DSToggle` owns its whole row, which doesn't leave room for a field.
struct MiniSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(DS.state) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? DS.inkBlack : DS.cloud)
                    .frame(width: 36, height: 21)
                Circle()
                    .fill(DS.signalWhite)
                    .frame(width: 17, height: 17)
                    .padding(.horizontal, 2)
            }
            .frame(width: 36, height: 21)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One knob of a weekday rule: a label, the value once it's switched on, and the switch.
struct RuleRow<Field: View>: View {
    var title: String
    var subtitle: String
    @Binding var isOn: Bool
    @ViewBuilder var field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(title)
                    .font(DS.text(13, .semibold))
                    .foregroundStyle(isOn ? DS.inkBlack : DS.ash)
                Spacer(minLength: 12)
                if isOn { field().frame(width: 100) }
                MiniSwitch(isOn: $isOn)
            }
            Text(subtitle)
                .font(DS.text(11))
                .foregroundStyle(DS.ash)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WeekdaysTab: View {
    @ObservedObject var store = Store.shared
    /// `Calendar`'s numbering — 2 is Monday. Weekends never have classes, so they're not offered.
    @State private var weekday: Int = 2

    private let schoolWeek = Array(2...6)

    var body: some View { ScrollView { content } }

    @ViewBuilder var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                MicroLabel(text: "The week", size: 9)
                HStack(spacing: 6) {
                    ForEach(schoolWeek, id: \.self) { wd in
                        Chip(title: String(WeekdayShape.weekdayName(wd).prefix(3)),
                             accent: store.data.weekdayShape(weekday: wd) != nil ? .orange : nil,
                             selected: weekday == wd) {
                            withAnimation(DS.state) { weekday = wd }
                        }
                    }
                }
                Text("A weekday rule reshapes whichever letter lands on that day — same classes, same order, different clock. "
                    + "Nothing here edits your schedules; an early dismissal is a rule, not a second copy of the day.")
                    .font(DS.text(12))
                    .foregroundStyle(DS.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Hairline()

            if let idx = store.data.weekdayShapes.firstIndex(where: { $0.weekday == weekday }) {
                editor(idx)
            } else {
                emptyState
            }
        }
        .padding(24)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(WeekdayShape.weekdayName(weekday))s run the normal schedule.")
                .font(DS.display(20, .bold))
                .tracking(DS.em(-0.03, 20))
                .foregroundStyle(DS.onyx)
            Text("Add a rule to change when the day starts, how long its classes are, or when the last one finishes.")
                .font(DS.text(12))
                .foregroundStyle(DS.slate)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(title: "Add a Rule", icon: "plus", kind: .primary, compact: true) {
                store.addWeekdayShape(weekday: weekday)
            }
        }
    }

    // MARK: Editor

    @ViewBuilder
    private func editor(_ idx: Int) -> some View {
        let shape = store.data.weekdayShapes[idx]
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                DSTextField(placeholder: "Name", text: $store.data.weekdayShapes[idx].name,
                            font: DS.display(15, .bold))
                    .frame(width: 220)
                Spacer()
                MicroLabel(text: shape.isOn ? "On" : "Off", color: shape.isOn ? DS.slate : DS.fog, size: 9)
                MiniSwitch(isOn: $store.data.weekdayShapes[idx].isOn)
                PillButton(title: "Delete Rule", kind: .danger, compact: true) {
                    store.removeWeekdayShape(id: shape.id)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                RuleRow(title: "Start the day at",
                        subtitle: "The first class begins here and everything after it moves by the same amount.",
                        isOn: flag(idx, \.startAt, on: defaultStart)) {
                    TimeField(minutes: value(idx, \.startAt, fallback: defaultStart))
                }
                Hairline()
                RuleRow(title: "Make every class",
                        subtitle: "Class lengths are set to this; the gaps between them stay exactly as they are.",
                        isOn: flag(idx, \.classLength, on: defaultLength)) {
                    MinutesField(minutes: value(idx, \.classLength, fallback: defaultLength))
                }
                Hairline()
                RuleRow(title: "Last class ends at",
                        subtitle: "The class still running when this comes round is cut short. Anything that would start after it is dropped.",
                        isOn: flag(idx, \.lastClassEndsAt, on: defaultEnd)) {
                    TimeField(minutes: value(idx, \.lastClassEndsAt, fallback: defaultEnd))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(fill: DS.mist)

            if shape.isOn && !shape.changesNothing {
                Hairline()
                preview(shape)
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func preview(_ shape: WeekdayShape) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MicroLabel(text: "How \(shape.weekdayName.lowercased())s come out", size: 9)
            ForEach(store.data.rotation) { day in
                let base = day.sorted
                let shaped = shape.apply(to: base)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Badge(text: "\(day.name) Day", accent: day.accent, filled: true)
                        Spacer()
                        if let first = shaped.first, let last = shaped.last {
                            MicroLabel(text: "\(Period.clock(first.start))–\(Period.clock(last.end))",
                                       color: DS.fog, size: 9)
                        }
                    }
                    ForEach(base) { p in
                        previewRow(original: p, shaped: shaped.first { $0.id == p.id })
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCard()
            }
        }
    }

    private func previewRow(original: Period, shaped: Period?) -> some View {
        let changed = shaped.map { $0.start != original.start || $0.end != original.end } ?? true
        return HStack(spacing: 8) {
            Text(original.name)
                .font(DS.text(12, changed ? .semibold : .regular))
                .foregroundStyle(shaped == nil ? DS.fog : DS.carbon)
                .lineLimit(1)
            Spacer(minLength: 8)
            if changed {
                Text(original.rangeText)
                    .font(DS.mono(10, .regular))
                    .foregroundStyle(DS.fog)
                    .strikethrough(color: DS.fog)
            }
            if let shaped {
                Text(shaped.rangeText)
                    .font(DS.mono(11, .medium))
                    .foregroundStyle(changed ? DS.inkBlack : DS.slate)
            } else {
                Badge(text: "Dropped", accent: .ink)
            }
        }
    }

    // MARK: Bindings

    private func flag(_ idx: Int, _ kp: WritableKeyPath<WeekdayShape, Int?>, on: Int) -> Binding<Bool> {
        Binding(
            get: { store.data.weekdayShapes.indices.contains(idx)
                    && store.data.weekdayShapes[idx][keyPath: kp] != nil },
            set: { yes in
                guard store.data.weekdayShapes.indices.contains(idx) else { return }
                store.data.weekdayShapes[idx][keyPath: kp] = yes ? on : nil
            })
    }

    private func value(_ idx: Int, _ kp: WritableKeyPath<WeekdayShape, Int?>, fallback: Int) -> Binding<Int> {
        Binding(
            get: {
                guard store.data.weekdayShapes.indices.contains(idx) else { return fallback }
                return store.data.weekdayShapes[idx][keyPath: kp] ?? fallback
            },
            set: { new in
                guard store.data.weekdayShapes.indices.contains(idx) else { return }
                store.data.weekdayShapes[idx][keyPath: kp] = new
            })
    }

    // MARK: Sensible starting values

    /// A rule's fields open on what the schedule already does, so switching one on is a
    /// visible no-op until you actually change the number.
    private var sampleDay: RotationDay? { store.data.rotation.first { !$0.periods.isEmpty } }

    private var defaultStart: Int { sampleDay?.sorted.first?.start ?? 8 * 60 + 30 }

    private var defaultEnd: Int { sampleDay?.sorted.last?.end ?? 15 * 60 + 20 }

    private var defaultLength: Int {
        guard let day = sampleDay else { return 45 }
        let lengths = day.sorted.map { max(1, $0.end - $0.start) }
        let tally = Dictionary(grouping: lengths, by: { $0 }).mapValues(\.count)
        return tally.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .first?.key ?? 45
    }
}

// MARK: - Special days

struct SpecialDaysTab: View {
    @ObservedObject var store = Store.shared
    @State private var selection: UUID?
    @State private var importingNewDay = false

    private var selectedID: UUID? {
        if let s = selection, store.data.specialDays.contains(where: { $0.id == s }) { return s }
        return store.data.specialDays.first?.id
    }

    var body: some View { ScrollView { content } }

    @ViewBuilder var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    MicroLabel(text: "Templates", size: 9)
                    HStack(spacing: 6) {
                        ForEach(store.data.specialDays) { sp in
                            Chip(title: sp.name, accent: sp.accent, selected: selectedID == sp.id) {
                                selection = sp.id
                            }
                        }
                        PillButton(title: "Add Special Day", icon: "plus", kind: .ghost, compact: true) {
                            store.addSpecialDay()
                            selection = store.data.specialDays.last?.id
                        }
                        PillButton(title: "From a Picture", icon: "camera", kind: .quiet, compact: true) {
                            importingNewDay = true
                        }
                        .sheet(isPresented: $importingNewDay) {
                            ImportSheet(initialDestination: .newSpecial)
                        }
                    }
                    Text("A special day replaces the normal schedule on the dates you assign it. Assign dates in the Calendar tab.")
                        .font(DS.text(12))
                        .foregroundStyle(DS.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Hairline()

                if let id = selectedID,
                   let idx = store.data.specialDays.firstIndex(where: { $0.id == id }) {
                    let sp = store.data.specialDays[idx]
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            DSTextField(placeholder: "Name", text: $store.data.specialDays[idx].name,
                                        font: DS.display(15, .bold))
                                .frame(width: 200)
                            AccentPicker(accent: $store.data.specialDays[idx].accent)
                            Spacer()
                            PillButton(title: "Delete", kind: .danger, compact: true) {
                                store.removeSpecialDay(id: sp.id)
                                selection = store.data.specialDays.first?.id
                            }
                        }
                        PeriodListEditor(periods: $store.data.specialDays[idx].periods, accent: sp.accent,
                                         importInto: .special(sp.id))
                        MicroLabel(text: usageLine(sp), color: DS.fog, size: 9)
                    }
                } else {
                    Text("No special days yet.")
                        .font(DS.text(13))
                        .foregroundStyle(DS.ash)
                }
            }
            .padding(24)
    }

    private func usageLine(_ sp: SpecialDay) -> String {
        let n = store.data.overrides.filter { $0.specialDayID == sp.id }.count
        return n == 0 ? "Not assigned to any dates yet" : "Assigned to \(n) date\(n == 1 ? "" : "s")"
    }
}

// MARK: - Calendar

struct CalendarTab: View {
    @ObservedObject var store = Store.shared
    @State private var month: Date = Rotation.calendar.startOfDay(for: Date())
    @State private var selected: Date? = Rotation.calendar.startOfDay(for: Date())

    private var cal: Calendar { Rotation.calendar }

    var body: some View { ScrollView { content } }

    @ViewBuilder var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                todayBlock
                Hairline()
                monthBlock
                if let day = selected {
                    Hairline()
                    DateAssignmentEditor(date: day)
                }
                if !store.data.overrides.isEmpty {
                    Hairline()
                    overridesList
                }
            }
            .padding(24)
    }

    // MARK: Today

    private var todayBlock: some View {
        let today = Rotation.resolve(Date(), data: store.data)
        return VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: "Today is", size: 9)
            HStack(alignment: .center, spacing: 12) {
                Text(today.isSpecial ? today.title : (today.periods.isEmpty && !today.isSpecial ? today.title : "\(today.title) Day"))
                    .font(DS.display(30, .heavy))
                    .tracking(DS.em(-0.04, 30))
                    .foregroundStyle(DS.onyx)
                Spacer()
                HStack(spacing: 6) {
                    MicroLabel(text: "Set today to", color: DS.fog, size: 9)
                    ForEach(store.data.rotation) { day in
                        Chip(title: day.name, accent: day.accent,
                             selected: store.data.anchorRotationID == day.id
                                && store.data.anchorDayKey == Rotation.dayKey(Rotation.snapToWeekday(Date()))) {
                            store.setToday(day.id)
                        }
                    }
                }
            }
            Text("Everything else is worked out from this one pin. Weekends are skipped entirely — Monday picks up exactly where Friday left off.")
                .font(DS.text(12))
                .foregroundStyle(DS.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Month grid

    private var monthBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MicroLabel(text: monthTitle, size: 9)
                Spacer()
                IconButton(icon: "chevron.left", help: "Previous month") { shiftMonth(-1) }
                PillButton(title: "Today", kind: .quiet, compact: true) {
                    month = cal.startOfDay(for: Date())
                    selected = cal.startOfDay(for: Date())
                }
                IconButton(icon: "chevron.right", help: "Next month") { shiftMonth(1) }
            }

            let symbols = orderedWeekdaySymbols
            HStack(spacing: 4) {
                ForEach(symbols.indices, id: \.self) { i in
                    MicroLabel(text: symbols[i], color: DS.fog, size: 8)
                        .frame(maxWidth: .infinity)
                }
            }

            let cells = monthCells
            VStack(spacing: 4) {
                ForEach(0..<(cells.count / 7), id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { col in
                            if let date = cells[row * 7 + col] {
                                dayCell(date)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, minHeight: 52)
                            }
                        }
                    }
                }
            }
        }
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: month)
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: month) {
            withAnimation(DS.state) { month = d }
        }
    }

    private var orderedWeekdaySymbols: [String] {
        let base = cal.veryShortWeekdaySymbols
        let start = cal.firstWeekday - 1
        return (0..<7).map { base[($0 + start) % 7] }
    }

    private var monthCells: [Date?] {
        let start = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let days = cal.range(of: .day, in: .month, for: start)!.count
        let firstWeekday = cal.component(.weekday, from: start)
        let lead = (firstWeekday - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for d in 0..<days {
            cells.append(cal.date(byAdding: .day, value: d, to: start)!)
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private func dayCell(_ date: Date) -> some View {
        let resolved = Rotation.resolve(date, data: store.data)
        let isToday = cal.isDateInToday(date)
        let isSelected = selected.map { cal.isDate($0, inSameDayAs: date) } ?? false
        let weekend = Rotation.isWeekend(date)
        let hasOverride = store.data.override(on: Rotation.dayKey(date)) != nil

        return Button {
            withAnimation(DS.hover) { selected = date }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text("\(cal.component(.day, from: date))")
                        .font(DS.text(11, isToday ? .bold : .medium))
                        .foregroundStyle(weekend && !hasOverride ? DS.fog : DS.carbon)
                    if isToday {
                        Circle().fill(DS.signalBlue).frame(width: 4, height: 4)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                if !resolved.periods.isEmpty || resolved.isSpecial || hasOverride {
                    Text(cellLabel(resolved))
                        .font(DS.mono(9, .medium))
                        .foregroundStyle(resolved.isSpecial || hasOverride ? DS.signalWhite : resolved.accent.color)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(resolved.isSpecial || hasOverride
                                           ? resolved.accent.color
                                           : resolved.accent.color.opacity(0.12))
                        )
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(weekend ? DS.mist : DS.signalWhite)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? DS.inkBlack : DS.bone,
                                      lineWidth: isSelected ? 1.5 : 1)
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cellLabel(_ r: ResolvedDay) -> String {
        switch r.kind {
        case .rotation(let d): return d.name
        case .special(let s): return String(s.name.prefix(9))
        case .holiday: return "OFF"
        case .weekend, .unscheduled: return ""
        }
    }

    // MARK: Override list

    private var overridesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MicroLabel(text: "All assigned dates", size: 9)
                Spacer()
                PillButton(title: "Clear Past Dates", kind: .quiet, compact: true) {
                    store.pruneExpiredOverrides()
                }
            }
            ForEach(store.data.overrides) { ov in
                HStack(spacing: 10) {
                    Text(displayDate(ov.dayKey))
                        .font(DS.mono(11, .medium))
                        .foregroundStyle(DS.carbon)
                        .frame(width: 116, alignment: .leading)
                    if let sid = ov.specialDayID, let sp = store.data.specialDay(id: sid) {
                        Badge(text: sp.name, accent: sp.accent, filled: true)
                    } else {
                        Badge(text: "No School", accent: .ink, filled: true)
                    }
                    if ov.pausesRotation {
                        Badge(text: "Pauses cycle", accent: .orange)
                    }
                    if !ov.note.isEmpty {
                        Text(ov.note)
                            .font(DS.text(11))
                            .foregroundStyle(DS.ash)
                            .lineLimit(1)
                    }
                    Spacer()
                    IconButton(icon: "xmark", help: "Remove") {
                        store.removeOverride(id: ov.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .dsCard(radius: DS.radiusInput, fill: DS.mist)
            }
        }
    }

    private func displayDate(_ key: String) -> String {
        guard let d = Rotation.date(fromKey: key) else { return key }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: d)
    }
}

// MARK: - Date assignment

struct DateAssignmentEditor: View {
    @ObservedObject var store = Store.shared
    var date: Date

    /// Set when a chip has been tapped but the cycle question hasn't been answered yet.
    @State private var pending: PendingAssignment?
    /// The answer to pre-select in the sheet — nil while it's still a fresh question.
    @State private var pendingInitial: Bool?

    private var key: String { Rotation.dayKey(date) }
    private var existing: DateOverride? { store.data.override(on: key) }

    /// Whether dropping something on this date raises the A/B question at all. A weekend
    /// carries no letter, and a one-day cycle has nothing to push.
    private var cycleQuestionApplies: Bool {
        !Rotation.isWeekend(date) && store.data.rotation.count > 1
    }

    /// Assigns the date — asking about the cycle first the *first* time something lands
    /// here, and quietly reusing the existing answer when the day is just being swapped.
    private func assign(specialDayID: UUID?) {
        guard let e = existing else {
            guard cycleQuestionApplies else {
                store.setOverride(date: date, specialDayID: specialDayID,
                                  pausesRotation: false, note: "")
                return
            }
            pendingInitial = nil
            pending = PendingAssignment(date: date, specialDayID: specialDayID, note: "")
            return
        }
        store.setOverride(date: date, specialDayID: specialDayID,
                          pausesRotation: e.pausesRotation, note: e.note)
    }

    var body: some View {
        let resolved = Rotation.resolve(date, data: store.data)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MicroLabel(text: longDate, size: 9)
                Spacer()
                if existing != nil {
                    PillButton(title: "Back to Normal", kind: .quiet, compact: true) {
                        if let e = existing { store.removeOverride(id: e.id) }
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(resolved.isSpecial ? resolved.title : "\(resolved.title)\(resolved.isSchoolDay ? " Day" : "")")
                    .font(DS.display(22, .heavy))
                    .tracking(DS.em(-0.035, 22))
                    .foregroundStyle(DS.onyx)
                if let under = resolved.underlyingRotation, resolved.isSpecial {
                    Badge(text: pausesRotation ? "\(under.name) pushed" : "\(under.name) underneath",
                          accent: under.accent)
                }
                if let shape = resolved.weekdayShape {
                    Badge(text: shape.name, accent: .orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                MicroLabel(text: "Make this date", color: DS.fog, size: 9)
                FlowRow(spacing: 6) {
                    Chip(title: "Normal", selected: existing == nil) {
                        if let e = existing { store.removeOverride(id: e.id) }
                    }
                    ForEach(store.data.specialDays) { sp in
                        Chip(title: sp.name, accent: sp.accent,
                             selected: existing?.specialDayID == sp.id) {
                            assign(specialDayID: sp.id)
                        }
                    }
                    Chip(title: "No School", accent: .ink,
                         selected: existing != nil && existing?.specialDayID == nil) {
                        assign(specialDayID: nil)
                    }
                }
                if store.data.specialDays.isEmpty {
                    Text("No special days to place yet — build one in the Special Days tab first.")
                        .font(DS.text(11))
                        .foregroundStyle(DS.ash)
                }
            }

            if let e = existing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        DSToggle(title: "Skip this day in the cycle",
                                 subtitle: pauseExplanation,
                                 isOn: Binding(
                                    get: { pausesRotation },
                                    set: { on in
                                        store.updateOverride(id: e.id) { $0.pausesRotation = on }
                                    })
                        )
                        if cycleQuestionApplies {
                            PillButton(title: "Compare", kind: .ghost, compact: true) {
                                pendingInitial = e.pausesRotation
                                pending = PendingAssignment(date: date,
                                                            specialDayID: e.specialDayID,
                                                            note: e.note)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        MicroLabel(text: "Note", color: DS.fog, size: 9).frame(width: 34, alignment: .leading)
                        DSTextField(placeholder: "Optional — e.g. Snow day", text: Binding(
                            get: { existing?.note ?? "" },
                            set: { new in
                                guard let e = existing else { return }
                                store.updateOverride(id: e.id) { $0.note = new }
                            }))
                    }
                }
                .padding(12)
                .dsCard(radius: DS.radiusCard, fill: DS.mist)
            }
        }
        .sheet(item: $pending) { item in
            CycleChoiceSheet(pending: item, initialPauses: pendingInitial)
        }
    }

    private var pausesRotation: Bool { existing?.pausesRotation ?? false }

    private var pauseExplanation: String {
        if pausesRotation {
            return "The cycle pauses — whatever letter this day would have used moves to the next school day."
        }
        return "The cycle keeps running underneath; only today's schedule is replaced."
    }

    private var longDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f.string(from: date)
    }
}

/// Wraps chips onto multiple lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var updater = Updater.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View { ScrollView { content } }

    @ViewBuilder var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    MicroLabel(text: "Menu bar", size: 9)
                    DSToggle(title: "Show class name", isOn: $store.data.showClassNameInMenuBar)
                    DSToggle(title: "Show day name", isOn: $store.data.showDayLetterInMenuBar)
                    DSToggle(title: "Show seconds", isOn: $store.data.showSecondsInMenuBar)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .dsCard()

                VStack(alignment: .leading, spacing: 12) {
                    MicroLabel(text: "Startup", size: 9)
                    DSToggle(title: "Open at login",
                             subtitle: "Move the app to /Applications first so macOS can find it reliably.",
                             isOn: Binding(
                                get: { launchAtLogin },
                                set: { on in
                                    do {
                                        if on { try SMAppService.mainApp.register() }
                                        else { try SMAppService.mainApp.unregister() }
                                        launchAtLogin = SMAppService.mainApp.status == .enabled
                                    } catch {
                                        launchAtLogin = SMAppService.mainApp.status == .enabled
                                        NSSound.beep()
                                    }
                                }))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .dsCard()

                VStack(alignment: .leading, spacing: 10) {
                    MicroLabel(text: "Storage", size: 9)
                    Text(store.storageLocation.path)
                        .font(DS.mono(10, .regular))
                        .foregroundStyle(DS.slate)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        PillButton(title: "Reveal in Finder", icon: "folder", kind: .ghost, compact: true) {
                            NSWorkspace.shared.activateFileViewerSelecting([store.storageLocation])
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .dsCard()

                VStack(alignment: .leading, spacing: 6) {
                    MicroLabel(text: "Typography", size: 9)
                    Text(fontStatus)
                        .font(DS.text(11))
                        .foregroundStyle(DS.ash)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .dsCard(fill: DS.mist)

                VStack(alignment: .leading, spacing: 8) {
                    MicroLabel(text: "About", size: 9)
                    HStack(spacing: 8) {
                        Text("mangoclass \(appVersion)")
                            .font(DS.text(12, .medium))
                            .foregroundStyle(DS.inkBlack)
                        if updater.status.manifest != nil {
                            Badge(text: "Update available", accent: .violet, filled: true)
                        }
                        Spacer(minLength: 8)
                        PillButton(title: "Check for Updates", kind: .ghost, compact: true) {
                            SettingsNavigation.shared.tab = .updates
                            Updater.shared.check(userInitiated: true)
                        }
                    }
                    Text("Made by Mingyu")
                        .font(DS.text(11))
                        .foregroundStyle(DS.ash)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .dsCard()
            }
            .padding(24)
    }

    private var appVersion: String { updater.currentVersionString }

    private var fontStatus: String {
        let display = DS.displayFamily ?? "system font (fallback)"
        let mono = DS.monoFamily ?? "system mono (fallback)"
        return "Display: \(display)   ·   Mono: \(mono)\nDrop Plus Jakarta Sans and Sometype Mono files into the project's Fonts/ folder and rebuild to use the real brand faces."
    }
}

// MARK: - Window host

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    /// The updater asks before it puts an alert on screen, so dismissing the alert doesn't
    /// drop the app back to accessory mode while Settings is still open.
    var isOpen: Bool { window?.isVisible ?? false }

    func show(tab: SettingsTab? = nil) {
        if let tab { SettingsNavigation.shared.tab = tab }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Class Schedule"
            w.backgroundColor = NSColor(hex: "ffffff")
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .aqua)
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
