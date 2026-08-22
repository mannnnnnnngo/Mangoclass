import SwiftUI

// MARK: - Shared pieces

/// One event, drawn as a chip. Used in the panel, the calendar and the editor — the same
/// shape everywhere so an event reads the same wherever it turns up.
struct EventChip: View {
    var event: SchoolEvent
    var compact: Bool = false
    var showTime: Bool = true

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Image(systemName: event.symbol)
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
            Text(event.trimmedName)
                .font(DS.text(compact ? 10 : 11, .bold))
                .lineLimit(1)
            if showTime, let time = event.timeText {
                Text(time)
                    .font(DS.mono(compact ? 8 : 9, .regular))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(event.accent.color)
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, compact ? 2 : 4)
        .background(Capsule().fill(event.accent.color.opacity(0.12)))
    }
}

/// A chip that can be switched on and off — the calendar uses it to drop an event onto a date.
struct EventToggleChip: View {
    var event: SchoolEvent
    var selected: Bool
    var enabled: Bool = true
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: event.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(event.trimmedName)
                    .font(DS.text(11, .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? DS.signalWhite : (enabled ? event.accent.color : DS.fog))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    Capsule().fill(selected ? event.accent.color
                                   : (hovering && enabled ? event.accent.color.opacity(0.12) : Color.clear))
                    Capsule().strokeBorder(selected ? Color.clear : DS.bone, lineWidth: 1)
                }
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { h in withAnimation(DS.hover) { hovering = h } }
    }
}

/// Compact date picker that can also be cleared, for a repeating event's bounds.
struct OptionalDateField: View {
    var label: String
    @Binding var dayKey: String?

    var body: some View {
        HStack(spacing: 6) {
            MicroLabel(text: label, color: DS.fog, size: 9)
            if let key = dayKey, let date = Rotation.date(fromKey: key) {
                DatePicker("", selection: Binding(
                    get: { date },
                    set: { dayKey = Rotation.dayKey($0) }
                ), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .font(DS.mono(11, .regular))
                IconButton(icon: "xmark", help: "Clear") { dayKey = nil }
            } else {
                PillButton(title: "Set", kind: .quiet, compact: true) {
                    dayKey = Rotation.dayKey(Date())
                }
            }
        }
    }
}

// MARK: - Events tab

struct EventsTab: View {
    @ObservedObject var store = Store.shared
    @State private var selection: UUID?

    private var selectedID: UUID? {
        if let s = selection, store.data.events.contains(where: { $0.id == s }) { return s }
        return store.data.events.first?.id
    }

    var body: some View { ScrollView { content } }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Hairline()
            if let id = selectedID, let idx = store.data.events.firstIndex(where: { $0.id == id }) {
                editor(idx)
            } else {
                Text("No events yet. Add one — House Shirts, picture day, a field trip — and it shows up on the calendar and in the menu bar panel.")
                    .font(DS.text(13))
                    .foregroundStyle(DS.ash)
            }
        }
        .padding(24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: "Events", size: 9)
            FlowRow(spacing: 6) {
                ForEach(store.data.events) { ev in
                    EventToggleChip(event: ev, selected: selectedID == ev.id) {
                        selection = ev.id
                    }
                }
                PillButton(title: "Add Event", icon: "plus", kind: .ghost, compact: true) {
                    selection = store.addEvent()
                }
                if store.data.events.contains(where: { $0.repeats == .dates && !$0.dayKeys.isEmpty }) {
                    PillButton(title: "Clear Past Dates", kind: .quiet, compact: true) {
                        store.pruneExpiredEventDates()
                    }
                }
            }
            Text("An event is a label on a date — it never changes your class times. Add as many as you like; the schedule underneath stays exactly as you built it.")
                .font(DS.text(12))
                .foregroundStyle(DS.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Editor

    @ViewBuilder private func editor(_ idx: Int) -> some View {
        let event = store.data.events[idx]
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                DSTextField(placeholder: "Name", text: $store.data.events[idx].name,
                            font: DS.display(15, .bold))
                    .frame(width: 220)
                AccentPicker(accent: $store.data.events[idx].accent)
                Spacer()
                PillButton(title: "Delete", kind: .danger, compact: true) {
                    store.removeEvent(id: event.id)
                    selection = store.data.events.first?.id
                }
            }

            symbolPicker(idx)

            VStack(alignment: .leading, spacing: 8) {
                MicroLabel(text: "When", color: DS.fog, size: 9)
                HStack(spacing: 6) {
                    ForEach(EventRepeat.allCases) { mode in
                        Chip(title: mode.label, selected: event.repeats == mode) {
                            withAnimation(DS.state) { store.data.events[idx].repeats = mode }
                        }
                    }
                }
                schedulePicker(idx)
            }

            VStack(alignment: .leading, spacing: 10) {
                DSToggle(title: "Show this event",
                         subtitle: "Switch off to keep it without it appearing anywhere.",
                         isOn: $store.data.events[idx].isOn)
                HStack(spacing: 8) {
                    MicroLabel(text: "Note", color: DS.fog, size: 9).frame(width: 34, alignment: .leading)
                    DSTextField(placeholder: "Optional — e.g. Wear your house colours",
                                text: $store.data.events[idx].note)
                }
                timeWindow(idx)
            }
            .padding(12)
            .dsCard(radius: DS.radiusCard, fill: DS.mist)

            upcoming(event)
        }
    }

    private func symbolPicker(_ idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: "Icon", color: DS.fog, size: 9)
            FlowRow(spacing: 5) {
                ForEach(SchoolEvent.symbolChoices, id: \.self) { symbol in
                    let on = store.data.events[idx].symbol == symbol
                    Button {
                        withAnimation(DS.hover) { store.data.events[idx].symbol = symbol }
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? DS.signalWhite : DS.slate)
                            .frame(width: 28, height: 28)
                            .background(
                                ZStack {
                                    RoundedRectangle(cornerRadius: DS.radiusInput, style: .continuous)
                                        .fill(on ? store.data.events[idx].accent.color : DS.mist)
                                    RoundedRectangle(cornerRadius: DS.radiusInput, style: .continuous)
                                        .strokeBorder(on ? Color.clear : DS.bone, lineWidth: 1)
                                }
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func schedulePicker(_ idx: Int) -> some View {
        let event = store.data.events[idx]
        switch event.repeats {
        case .dates:
            VStack(alignment: .leading, spacing: 8) {
                if event.dayKeys.isEmpty {
                    Text("No dates yet — open the Calendar tab, pick a day, and switch this event on for it.")
                        .font(DS.text(11))
                        .foregroundStyle(DS.ash)
                } else {
                    FlowRow(spacing: 5) {
                        ForEach(event.dayKeys, id: \.self) { key in
                            HStack(spacing: 3) {
                                Text(prettyDate(key))
                                    .font(DS.mono(10, .medium))
                                    .foregroundStyle(DS.carbon)
                                IconButton(icon: "xmark", help: "Remove this date") {
                                    store.updateEvent(id: event.id) { ev in
                                        ev.dayKeys.removeAll { $0 == key }
                                    }
                                }
                            }
                            .padding(.leading, 9)
                            .background(Capsule().fill(DS.mist))
                            .overlay(Capsule().strokeBorder(DS.bone, lineWidth: 1))
                        }
                    }
                }
                PillButton(title: "Add Today", icon: "plus", kind: .quiet, compact: true) {
                    store.updateEvent(id: event.id) { $0.toggleDate(Rotation.dayKey(Date())) }
                }
            }

        case .weekly:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(2...6, id: \.self) { wd in
                        Chip(title: String(WeekdayShape.weekdayName(wd).prefix(3)),
                             selected: event.weekday == wd) {
                            store.data.events[idx].weekday = wd
                        }
                    }
                }
                boundsRow(idx)
            }

        case .rotationDay:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(store.data.rotation) { day in
                        Chip(title: day.name, accent: day.accent,
                             selected: event.rotationDayID == day.id) {
                            store.data.events[idx].rotationDayID = day.id
                        }
                    }
                }
                Text("Rides along with the letter, so it moves with the cycle — including when a skipped day pushes everything along.")
                    .font(DS.text(11))
                    .foregroundStyle(DS.ash)
                boundsRow(idx)
            }
        }
    }

    private func boundsRow(_ idx: Int) -> some View {
        HStack(spacing: 16) {
            OptionalDateField(label: "Starts", dayKey: $store.data.events[idx].startsOn)
            OptionalDateField(label: "Ends", dayKey: $store.data.events[idx].endsOn)
            Spacer()
        }
    }

    @ViewBuilder private func timeWindow(_ idx: Int) -> some View {
        let event = store.data.events[idx]
        HStack(spacing: 8) {
            MicroLabel(text: "Time", color: DS.fog, size: 9).frame(width: 34, alignment: .leading)
            if event.startMinute == nil {
                PillButton(title: "All day", kind: .quiet, compact: true) {
                    store.data.events[idx].startMinute = 8 * 60
                    store.data.events[idx].endMinute = 8 * 60 + 30
                }
                MicroLabel(text: "tap to give it a time", color: DS.fog, size: 9)
            } else {
                TimeField(minutes: Binding(
                    get: { store.data.events[idx].startMinute ?? 8 * 60 },
                    set: { store.data.events[idx].startMinute = $0 }))
                    .frame(width: 92)
                MicroLabel(text: "to", color: DS.fog, size: 9)
                TimeField(minutes: Binding(
                    get: { store.data.events[idx].endMinute ?? (store.data.events[idx].startMinute ?? 0) + 30 },
                    set: { store.data.events[idx].endMinute = $0 }))
                    .frame(width: 92)
                IconButton(icon: "xmark", help: "Back to all day") {
                    store.data.events[idx].startMinute = nil
                    store.data.events[idx].endMinute = nil
                }
                MicroLabel(text: "shown on the chip only — classes aren't moved", color: DS.fog, size: 9)
            }
            Spacer()
        }
    }

    /// The next few days this actually lands on — the quickest way to see a rule is right.
    @ViewBuilder private func upcoming(_ event: SchoolEvent) -> some View {
        let dates = nextOccurrences(event, limit: 4)
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel(text: event.summary(data: store.data), color: DS.fog, size: 9)
            if dates.isEmpty {
                Text("Nothing coming up in the next few months.")
                    .font(DS.text(11))
                    .foregroundStyle(DS.ash)
            } else {
                HStack(spacing: 6) {
                    MicroLabel(text: "Next", color: DS.fog, size: 9)
                    ForEach(dates, id: \.self) { d in
                        Text(longish(d))
                            .font(DS.mono(10, .medium))
                            .foregroundStyle(DS.slate)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(DS.mist))
                    }
                }
            }
        }
    }

    private func nextOccurrences(_ event: SchoolEvent, limit: Int) -> [Date] {
        let cal = Rotation.calendar
        var day = cal.startOfDay(for: Date())
        var found: [Date] = []
        for _ in 0..<180 {
            let resolved = Rotation.resolve(day, data: store.data)
            if resolved.events.contains(where: { $0.id == event.id }) {
                found.append(day)
                if found.count == limit { break }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return found
    }

    private func prettyDate(_ key: String) -> String {
        guard let d = Rotation.date(fromKey: key) else { return key }
        return longish(d)
    }

    private func longish(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }
}

// MARK: - Events on one date

/// The Calendar tab's events section. Everything here writes to `data.events` only —
/// dropping an event on a date can't reach the periods, so a day that had a schedule
/// before still has exactly that schedule afterwards.
struct DateEventsEditor: View {
    @ObservedObject var store = Store.shared
    var date: Date
    var resolved: ResolvedDay

    @State private var draftName = ""

    private var key: String { Rotation.dayKey(date) }

    /// Events you can pin to this one date by tapping.
    private var pinnable: [SchoolEvent] { store.data.events.filter { $0.repeats == .dates } }

    /// Events landing here because of a rule — shown, but not switched off from a date.
    private var recurring: [SchoolEvent] {
        resolved.events.filter { $0.repeats != .dates }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: "Events on this day", color: DS.fog, size: 9)

            HStack(spacing: 8) {
                DSTextField(placeholder: "New event — e.g. House Shirts", text: $draftName)
                    .frame(width: 260)
                PillButton(title: "Add", icon: "plus", kind: .ghost, compact: true) { add() }
            }

            if !pinnable.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(pinnable) { ev in
                        EventToggleChip(event: ev, selected: ev.dayKeys.contains(key)) {
                            store.toggleEventDate(id: ev.id, date: date)
                        }
                    }
                }
            }

            if !recurring.isEmpty {
                HStack(spacing: 6) {
                    ForEach(recurring) { ev in
                        EventChip(event: ev)
                    }
                    MicroLabel(text: "from a repeating rule", color: DS.fog, size: 9)
                }
            }

            if store.data.events.isEmpty {
                Text("Type a name above to put something on this date, or build a repeating one in the Events tab.")
                    .font(DS.text(11))
                    .foregroundStyle(DS.ash)
            }
        }
        .padding(12)
        .dsCard(radius: DS.radiusCard, fill: DS.mist)
    }

    private func add() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.addEvent(named: name, on: key)
        draftName = ""
    }
}
