import SwiftUI

// MARK: - Forecast

extension Rotation {
    /// The next `count` school days starting at `date`, resolved against `data`.
    /// Weekends are stepped over, so this is "the next few days you actually go to school".
    static func forecast(from date: Date, data: AppData, count: Int) -> [ResolvedDay] {
        var out: [ResolvedDay] = []
        var day = calendar.startOfDay(for: date)
        var safety = 0
        while out.count < count && safety < 120 {
            safety += 1
            if !isWeekend(day) { out.append(resolve(day, data: data)) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }
}

extension AppData {
    /// A throwaway copy with one date pinned — used to preview a choice before committing it.
    func previewing(date: Date, specialDayID: UUID?, pausesRotation: Bool) -> AppData {
        var copy = self
        let key = Rotation.dayKey(date)
        let entry = DateOverride(dayKey: key, specialDayID: specialDayID,
                                 pausesRotation: pausesRotation, note: "")
        if let i = copy.overrides.firstIndex(where: { $0.dayKey == key }) {
            copy.overrides[i] = entry
        } else {
            copy.overrides.append(entry)
        }
        return copy
    }
}

// MARK: - The question

/// What the user is about to drop onto a date, held until they answer the cycle question.
struct PendingAssignment: Identifiable {
    var id: String { Rotation.dayKey(date) + (specialDayID?.uuidString ?? "off") }
    var date: Date
    /// nil means "No School".
    var specialDayID: UUID?
    var note: String
}

/// Asks the one question a special day raises: the letter that was supposed to land here
/// didn't get used — does it move to the next school day, or is it spent?
///
/// Both answers are shown as a real forecast of the next few school days, because the
/// wording alone ("pauses the rotation") never makes it obvious which one you meant.
struct CycleChoiceSheet: View {
    @ObservedObject var store = Store.shared
    @Environment(\.dismiss) private var dismiss

    var pending: PendingAssignment
    /// Pre-selects the answer when the date already has one, so reopening this doesn't lie.
    var initialPauses: Bool?

    @State private var pauses: Bool = false

    private var special: SpecialDay? {
        pending.specialDayID.flatMap { store.data.specialDay(id: $0) }
    }

    /// The letter that would have landed on this date if nothing were pinned to it.
    private var underlying: RotationDay? {
        Rotation.rotationDay(for: pending.date, data: store.data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    question
                    HStack(alignment: .top, spacing: 10) {
                        optionCard(pausing: true)
                        optionCard(pausing: false)
                    }
                }
                .padding(20)
            }
            Hairline()
            footer
        }
        .frame(width: 620, height: 560)
        .background(DS.signalWhite)
        .onAppear { pauses = initialPauses ?? suggested }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                MicroLabel(text: longDate, size: 9)
                Text(special?.name ?? "No School")
                    .font(DS.display(22, .heavy))
                    .tracking(DS.em(-0.035, 22))
                    .foregroundStyle(DS.onyx)
            }
            Spacer()
            if let sp = special {
                Badge(text: "Special Day", accent: sp.accent, filled: true)
            } else {
                Badge(text: "Day Off", accent: .ink, filled: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(questionTitle)
                .font(DS.display(17, .bold))
                .tracking(DS.em(-0.02, 17))
                .foregroundStyle(DS.inkBlack)
            Text(questionBody)
                .font(DS.text(12))
                .foregroundStyle(DS.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var questionTitle: String {
        guard let under = underlying else { return "How should the cycle handle this day?" }
        return "What happens to \(under.name)?"
    }

    private var questionBody: String {
        let name = special?.name ?? "No school"
        guard let under = underlying else {
            return "\(name) replaces the normal schedule on this date."
        }
        return "\(name) takes over a day that was going to be \(under.name). "
            + "Either \(under.name) waits and runs on the next school day, or it's counted as used and the cycle carries on. "
            + "Pick whichever matches what your school actually does."
    }

    /// A day off almost always pushes the letter forward; a special schedule usually still
    /// *is* that letter with different times, so the cycle keeps going. Only a starting point.
    private var suggested: Bool { pending.specialDayID == nil }

    // MARK: Option cards

    @ViewBuilder
    private func optionCard(pausing: Bool) -> some View {
        let selected = pauses == pausing
        let title = pausing ? pushTitle : keepTitle
        let blurb = pausing ? pushBlurb : keepBlurb

        Button {
            withAnimation(DS.state) { pauses = pausing }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? DS.inkBlack : DS.cloud)
                    Text(title)
                        .font(DS.text(13, .bold))
                        .foregroundStyle(DS.inkBlack)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if pausing == suggested && initialPauses == nil {
                        Badge(text: "Usual", accent: .orange)
                    }
                }

                Text(blurb)
                    .font(DS.text(11))
                    .foregroundStyle(DS.slate)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Hairline()
                MicroLabel(text: "Next school days", color: DS.fog, size: 8)
                forecastList(pausing: pausing)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                        .fill(selected ? DS.signalWhite : DS.mist)
                    RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                        .strokeBorder(selected ? DS.inkBlack : DS.bone,
                                      lineWidth: selected ? 1.5 : 1)
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pushTitle: String {
        guard let under = underlying else { return "Skip this day in the cycle" }
        return "Move \(under.name) to the next school day"
    }

    private var keepTitle: String {
        guard let under = underlying else { return "Keep the cycle running" }
        return "Count it as \(under.name) anyway"
    }

    private var pushBlurb: String {
        guard let under = underlying else {
            return "The cycle pauses here and picks up on the next school day."
        }
        return "Nothing in the cycle is used up today, so \(under.name) — and every letter after it — slides forward one school day."
    }

    private var keepBlurb: String {
        guard let under = underlying else {
            return "The cycle keeps counting underneath; only today's schedule changes."
        }
        return "Today still counts as \(under.name) underneath, so the days after it are exactly where they'd have been."
    }

    // MARK: Forecast

    @ViewBuilder
    private func forecastList(pausing: Bool) -> some View {
        let mine = Rotation.forecast(
            from: pending.date,
            data: store.data.previewing(date: pending.date,
                                        specialDayID: pending.specialDayID,
                                        pausesRotation: pausing),
            count: 6)
        let other = Rotation.forecast(
            from: pending.date,
            data: store.data.previewing(date: pending.date,
                                        specialDayID: pending.specialDayID,
                                        pausesRotation: !pausing),
            count: 6)

        VStack(spacing: 3) {
            ForEach(Array(mine.enumerated()), id: \.offset) { i, day in
                let differs = i < other.count && other[i].title != day.title
                HStack(spacing: 7) {
                    Text(shortDate(day.date))
                        .font(DS.mono(10, .regular))
                        .foregroundStyle(DS.ash)
                        .frame(width: 62, alignment: .leading)
                    Text(day.title)
                        .font(DS.text(11, differs ? .bold : .medium))
                        .foregroundStyle(differs ? DS.inkBlack : DS.slate)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if differs {
                        Circle().fill(day.accent.color).frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(i == 0 ? DS.plaster : (differs ? day.accent.color.opacity(0.09) : Color.clear))
                )
            }
        }
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f.string(from: date)
    }

    private var longDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f.string(from: pending.date)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(pauses ? "The cycle pauses on this date." : "The cycle keeps running underneath.")
                .font(DS.text(11))
                .foregroundStyle(DS.ash)
            Spacer()
            PillButton(title: "Cancel", kind: .quiet, compact: true) { dismiss() }
            PillButton(title: initialPauses == nil ? "Set This Day" : "Save", kind: .primary, compact: true) {
                store.setOverride(date: pending.date, specialDayID: pending.specialDayID,
                                  pausesRotation: pauses, note: pending.note)
                dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
