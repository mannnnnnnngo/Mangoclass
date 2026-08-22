import SwiftUI

// MARK: - Time parsing

enum TimeParser {
    /// Accepts "8:30", "830", "0830", "8", "8:30 AM", "8p", "14:05" and friends.
    /// Without an am/pm the school day is assumed: 1–6 reads as afternoon, 7–12 as morning.
    static func parse(_ raw: String) -> Int? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return nil }

        var meridiem: String? = nil
        if lower.contains("p") { meridiem = "pm" }
        else if lower.contains("a") { meridiem = "am" }

        let digitsAndColon = lower.filter { $0.isNumber || $0 == ":" }
        guard !digitsAndColon.isEmpty else { return nil }

        var hour = 0
        var minute = 0

        if digitsAndColon.contains(":") {
            let parts = digitsAndColon.split(separator: ":", omittingEmptySubsequences: false)
            guard let h = Int(parts[0]) else { return nil }
            hour = h
            if parts.count > 1, !parts[1].isEmpty {
                guard let m = Int(parts[1].prefix(2)) else { return nil }
                minute = m
            }
        } else {
            let digits = digitsAndColon
            switch digits.count {
            case 1, 2:
                guard let h = Int(digits) else { return nil }
                hour = h
            case 3:
                guard let h = Int(digits.prefix(1)), let m = Int(digits.suffix(2)) else { return nil }
                hour = h; minute = m
            case 4:
                guard let h = Int(digits.prefix(2)), let m = Int(digits.suffix(2)) else { return nil }
                hour = h; minute = m
            default:
                return nil
            }
        }

        guard minute >= 0, minute < 60, hour >= 0, hour <= 23 else { return nil }

        switch meridiem {
        case "pm": if hour < 12 { hour += 12 }
        case "am": if hour == 12 { hour = 0 }
        default:
            // No am/pm given — bias toward plausible school hours.
            if hour >= 1 && hour <= 6 { hour += 12 }
        }

        guard hour <= 23 else { return nil }
        return hour * 60 + minute
    }

    static func format(_ minutes: Int) -> String { Period.clock(minutes) }
}

// MARK: - Text field

/// Plain text input with the design system's 9px-radius outline, no macOS bezel.
struct DSTextField: View {
    var placeholder: String
    @Binding var text: String
    var font: Font = DS.text(13, .semibold)
    var alignment: TextAlignment = .leading

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .multilineTextAlignment(alignment)
            .foregroundStyle(DS.inkBlack)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radiusInput, style: .continuous)
                        .fill(focused ? DS.signalWhite : DS.mist)
                    RoundedRectangle(cornerRadius: DS.radiusInput, style: .continuous)
                        .strokeBorder(focused ? DS.signalBlue : DS.bone, lineWidth: 1)
                }
            )
            .animation(DS.hover, value: focused)
    }
}

/// Time input that shows "8:30 AM" at rest and accepts loose typing while editing.
struct TimeField: View {
    @Binding var minutes: Int

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(DS.mono(12, .medium))
            .foregroundStyle(DS.inkBlack)
            .multilineTextAlignment(.center)
            .focused($focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radiusInput, style: .continuous)
                        .fill(focused ? DS.signalWhite : DS.mist)
                    RoundedRectangle(cornerRadius: DS.radiusInput, style: .continuous)
                        .strokeBorder(focused ? DS.signalBlue : DS.bone, lineWidth: 1)
                }
            )
            .animation(DS.hover, value: focused)
            .onAppear { draft = TimeParser.format(minutes) }
            .onChange(of: minutes) { _, new in
                if !focused { draft = TimeParser.format(new) }
            }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    draft = TimeParser.format(minutes)
                } else {
                    commit()
                }
            }
            .onSubmit { commit() }
    }

    private func commit() {
        if let parsed = TimeParser.parse(draft) {
            minutes = parsed
            draft = TimeParser.format(parsed)
        } else {
            draft = TimeParser.format(minutes) // unparseable — snap back
        }
    }
}

/// Duration input — a plain minute count with the unit drawn in, for "45 min" style fields.
struct MinutesField: View {
    @Binding var minutes: Int
    var range: ClosedRange<Int> = 1...600

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(DS.mono(12, .medium))
                .foregroundStyle(DS.inkBlack)
                .multilineTextAlignment(.trailing)
                .focused($focused)
            Text("min")
                .font(DS.mono(10, .regular))
                .foregroundStyle(DS.fog)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DS.radiusInput, style: .continuous)
                    .fill(focused ? DS.signalWhite : DS.mist)
                RoundedRectangle(cornerRadius: DS.radiusInput, style: .continuous)
                    .strokeBorder(focused ? DS.signalBlue : DS.bone, lineWidth: 1)
            }
        )
        .animation(DS.hover, value: focused)
        .onAppear { draft = "\(minutes)" }
        .onChange(of: minutes) { _, new in
            if !focused { draft = "\(new)" }
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused { draft = "\(minutes)" } else { commit() }
        }
        .onSubmit { commit() }
    }

    private func commit() {
        if let value = Int(draft.filter(\.isNumber)), range.contains(value) {
            minutes = value
        }
        draft = "\(minutes)" // out of range or unparseable — snap back
    }
}

// MARK: - Toggle

/// Flat pill switch; replaces the stock macOS checkbox.
struct DSToggle: View {
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(DS.state) { isOn.toggle() }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.text(13, .semibold))
                        .foregroundStyle(DS.inkBlack)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.text(11))
                            .foregroundStyle(DS.ash)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 12)
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
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
