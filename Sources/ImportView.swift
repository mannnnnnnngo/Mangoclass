import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Where the classes land

enum ImportDestination: Hashable {
    case rotation(UUID)
    case special(UUID)
    case newRotation
    case newSpecial
}

// MARK: - Sheet

/// Turns a photo or screenshot of a schedule into classes. Nothing is saved until
/// the review step is confirmed — the picture is read twice and every disagreement,
/// guess and oddity is surfaced first.
struct ImportSheet: View {
    @ObservedObject var store = Store.shared
    @Environment(\.dismiss) private var dismiss

    var initialDestination: ImportDestination
    /// Lets a caller hand the sheet a picture it already has, skipping the drop zone.
    var startingImage: NSImage? = nil

    private enum Phase {
        case pick
        case reading
        case review
    }

    @State private var phase: Phase = .pick
    @State private var image: NSImage?
    @State private var imageName = ""
    @State private var result = ImportResult()
    @State private var drafts: [DraftPeriod] = []
    @State private var destination: ImportDestination = .newRotation
    @State private var newName = ""
    @State private var replaceExisting = true
    @State private var dropTargeted = false
    @State private var failure: String?

    private var validation: [UUID: [ImportIssue]] { ScheduleImporter.validate(drafts) }

    private var included: [DraftPeriod] {
        drafts.filter(\.include).sorted { $0.start < $1.start }
    }

    private var warningCount: Int {
        let checks = validation
        return included.filter { d in
            ScheduleImporter.issues(for: d, validation: checks).contains { $0.isWarning }
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            Group {
                switch phase {
                case .pick:    picker
                case .reading: reading
                case .review:  ScrollView { review.padding(20) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Hairline()
            footer
        }
        .background(DS.signalWhite)
        .frame(width: 880, height: 660)
        .onAppear {
            destination = initialDestination
            if let startingImage, image == nil { begin(image: startingImage, name: "Picture") }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from a Picture")
                    .font(DS.display(17, .bold))
                    .tracking(DS.em(-0.02, 17))
                    .foregroundStyle(DS.inkBlack)
                Text(headerSubtitle)
                    .font(DS.text(11))
                    .foregroundStyle(DS.ash)
            }
            Spacer()
            if phase == .review {
                PillButton(title: "Start Over", kind: .quiet, compact: true) {
                    withAnimation(DS.state) {
                        image = nil
                        drafts = []
                        result = ImportResult()
                        failure = nil
                        phase = .pick
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    private var headerSubtitle: String {
        switch phase {
        case .pick:    return "A photo of a handout, a screenshot, anything with times on it."
        case .reading: return "Reading the picture twice and comparing the results…"
        case .review:  return "Check every row before it's saved — nothing is written yet."
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if phase == .review {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summaryLine)
                        .font(DS.text(12, .semibold))
                        .foregroundStyle(DS.carbon)
                    if warningCount > 0 {
                        Text("\(warningCount) row\(warningCount == 1 ? "" : "s") still \(warningCount == 1 ? "needs" : "need") a look — settle \(warningCount == 1 ? "it" : "them") below, or untick the row.")
                            .font(DS.text(11))
                            .foregroundStyle(Color(hex: "b54708"))
                    } else if !included.isEmpty {
                        Text("Everything checks out.")
                            .font(DS.text(11))
                            .foregroundStyle(DS.emerald)
                    }
                }
            }
            Spacer()
            PillButton(title: "Cancel", kind: .quiet) { dismiss() }
            if phase == .review {
                PillButton(title: importTitle, kind: .primary) { applyImport() }
                    .opacity(included.isEmpty ? 0.4 : 1)
                    .disabled(included.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
    }

    private var summaryLine: String {
        guard let first = included.map(\.start).min(), let last = included.map(\.end).max() else {
            return "Nothing selected."
        }
        return "\(included.count) class\(included.count == 1 ? "" : "es")  ·  \(Period.clock(first)) – \(Period.clock(last))"
    }

    private var importTitle: String {
        let n = included.count
        let verb = warningCount > 0 ? "Import Anyway" : "Import"
        guard warningCount == 0 else { return verb }
        return "\(verb) \(n) Class\(n == 1 ? "" : "es")"
    }

    // MARK: Step 1 — pick a picture

    private var picker: some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(dropTargeted ? DS.signalBlue : DS.fog)
                VStack(spacing: 5) {
                    Text("Drop a picture of your schedule")
                        .font(DS.display(16, .bold))
                        .tracking(DS.em(-0.02, 16))
                        .foregroundStyle(DS.inkBlack)
                    Text("Works best on a straight-on, well-lit shot where every time is readable.")
                        .font(DS.text(12))
                        .foregroundStyle(DS.ash)
                }
                HStack(spacing: 8) {
                    PillButton(title: "Choose File…", icon: "folder", kind: .ghost, compact: true) { chooseFile() }
                    PillButton(title: "Paste", icon: "doc.on.clipboard", kind: .ghost, compact: true) { pasteImage() }
                }
                if let failure {
                    Text(failure)
                        .font(DS.text(12))
                        .foregroundStyle(Color(hex: "d92d20"))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 46)
            .padding(.horizontal, 30)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radiusLargeCard, style: .continuous)
                        .fill(dropTargeted ? DS.signalBlue.opacity(0.04) : DS.mist)
                    RoundedRectangle(cornerRadius: DS.radiusLargeCard, style: .continuous)
                        .strokeBorder(dropTargeted ? DS.signalBlue : DS.bone,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }
            )
            .padding(.horizontal, 24)
            .animation(DS.hover, value: dropTargeted)

            Text("Everything happens on this Mac — the picture is never uploaded anywhere.")
                .font(DS.text(11))
                .foregroundStyle(DS.fog)
            Spacer()
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            load(providers: providers)
        }
    }

    private var reading: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.small)
            Text("Reading the picture…")
                .font(DS.display(15, .bold))
                .foregroundStyle(DS.inkBlack)
            Text("Once from the original and once from a cleaned-up copy, then the two are compared.")
                .font(DS.text(12))
                .foregroundStyle(DS.ash)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Step 2 — review

    @ViewBuilder private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            checkCard
            HStack(alignment: .top, spacing: 18) {
                imageColumn
                rowsColumn
            }
            if !result.skippedLines.isEmpty { skippedCard }
            destinationCard
        }
    }

    private var checkCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: warningCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(warningCount > 0 ? Color(hex: "f79009") : DS.emerald)
                MicroLabel(text: "Double-checked", color: DS.slate, size: 9)
            }
            ForEach(result.checkNotes, id: \.self) { note in
                Text("· " + note)
                    .font(DS.text(12))
                    .foregroundStyle(DS.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dsCard(fill: DS.mist)
    }

    private var imageColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: "The picture", size: 9)
            if let image {
                // Sized from the picture's own proportions — a .fit frame would reserve
                // its full height and leave a wide schedule floating in white space.
                let width: CGFloat = 238
                let ratio = image.size.width > 0 ? image.size.height / image.size.width : 1
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: min(460, width * ratio))
                    .padding(6)
                    .dsCard(radius: DS.radiusInput)
            }
            Text(imageName)
                .font(DS.mono(10, .regular))
                .foregroundStyle(DS.fog)
                .lineLimit(2)
                .truncationMode(.middle)
            Text("Compare it against the rows — the importer can misread a smudged digit.")
                .font(DS.text(11))
                .foregroundStyle(DS.ash)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 250)
    }

    private var rowsColumn: some View {
        let checks = validation
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MicroLabel(text: "Use", size: 9).frame(width: 24)
                MicroLabel(text: "Class", size: 9).frame(maxWidth: .infinity, alignment: .leading)
                MicroLabel(text: "Room", size: 9).frame(width: 92, alignment: .leading)
                MicroLabel(text: "Starts", size: 9).frame(width: 84, alignment: .center)
                MicroLabel(text: "Ends", size: 9).frame(width: 84, alignment: .center)
                Spacer().frame(width: 24)
            }
            .padding(.horizontal, 2)

            if drafts.isEmpty {
                Text("No classes left. Start over with a different picture, or close and add them by hand.")
                    .font(DS.text(12))
                    .foregroundStyle(DS.ash)
                    .padding(.vertical, 20)
            }

            ForEach($drafts) { $draft in
                draftRow($draft, issues: ScheduleImporter.issues(for: draft, validation: checks))
            }

            HStack(spacing: 8) {
                PillButton(title: "Add Row", icon: "plus", kind: .ghost, compact: true) {
                    let start = drafts.map(\.end).max() ?? (8 * 60)
                    drafts.append(DraftPeriod(name: "New Class", start: start, end: start + 45))
                }
                PillButton(title: "Sort by Time", kind: .quiet, compact: true) {
                    withAnimation(DS.state) { drafts.sort { $0.start < $1.start } }
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func draftRow(_ draft: Binding<DraftPeriod>, issues: [ImportIssue]) -> some View {
        let on = draft.wrappedValue.include
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconButton(icon: on ? "checkmark.circle.fill" : "circle",
                           tint: on ? DS.inkBlack : DS.cloud,
                           hoverTint: on ? DS.carbon : DS.ash,
                           help: on ? "Skip this row" : "Include this row") {
                    withAnimation(DS.hover) { draft.wrappedValue.include.toggle() }
                }
                .frame(width: 24)

                DSTextField(placeholder: "Class name", text: draft.name)
                    .frame(maxWidth: .infinity)
                DSTextField(placeholder: "", text: draft.location, font: DS.mono(12, .medium))
                    .frame(width: 92)
                TimeField(minutes: draft.start).frame(width: 84)
                TimeField(minutes: draft.end).frame(width: 84)
                IconButton(icon: "trash", hoverTint: Color(hex: "d92d20"), help: "Remove this row") {
                    let id = draft.wrappedValue.id
                    drafts.removeAll { $0.id == id }
                }
                .frame(width: 24)
            }

            if !issues.isEmpty {
                FlowRow(spacing: 5) {
                    ForEach(issues, id: \.self) { issue in
                        Badge(text: issue.label, accent: issue.isWarning ? .orange : .ink)
                    }
                    if let alt = draft.wrappedValue.altStart {
                        SuggestionChip(text: "Starts \(Period.clock(alt))?") {
                            settle(draft) { $0.start = alt; $0.altStart = nil }
                        }
                    }
                    if let alt = draft.wrappedValue.altEnd {
                        SuggestionChip(text: "Ends \(Period.clock(alt))?") {
                            settle(draft) { $0.end = alt; $0.altEnd = nil }
                        }
                    }
                    if let alt = draft.wrappedValue.altName {
                        SuggestionChip(text: "\"\(alt)\"?") {
                            settle(draft) { $0.name = alt; $0.altName = nil }
                        }
                    }
                    // Every reading warning is either fixed or ticked off, so the count
                    // in the footer means "still unlooked-at" rather than "unfixable".
                    if issues.contains(where: { $0.isWarning && !isFixable($0) }) {
                        SuggestionChip(text: "Looks right", icon: "checkmark",
                                       help: "Tick this row off — you've checked it against the picture") {
                            markChecked(draft)
                        }
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 2)
        .opacity(on ? 1 : 0.45)
    }

    /// Issues that only go away by changing the times themselves — no ticking them off.
    private func isFixable(_ issue: ImportIssue) -> Bool {
        switch issue {
        case .endBeforeStart, .overlapsPrevious, .missingName: return true
        default: return false
        }
    }

    /// Takes one of the other read's answers. Once nothing is left to choose between,
    /// the row has been looked at, so the disagreement mark comes off.
    private func settle(_ draft: Binding<DraftPeriod>, _ change: (inout DraftPeriod) -> Void) {
        change(&draft.wrappedValue)
        let d = draft.wrappedValue
        if d.altStart == nil, d.altEnd == nil, d.altName == nil {
            draft.wrappedValue.readIssues.removeAll { $0 == .disagreement }
        }
    }

    /// "I've compared this row against the picture and it's fine."
    private func markChecked(_ draft: Binding<DraftPeriod>) {
        withAnimation(DS.hover) {
            draft.wrappedValue.altStart = nil
            draft.wrappedValue.altEnd = nil
            draft.wrappedValue.altName = nil
            draft.wrappedValue.readIssues.removeAll { $0.isWarning }
        }
    }

    private var skippedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel(text: "Lines with no times — skipped", size: 9)
            Text(result.skippedLines.prefix(8).joined(separator: "   ·   "))
                .font(DS.text(11))
                .foregroundStyle(DS.ash)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dsCard(fill: DS.mist)
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicroLabel(text: "Add these classes to", size: 9)
            FlowRow(spacing: 6) {
                ForEach(store.data.rotation) { day in
                    Chip(title: day.name, accent: day.accent, selected: destination == .rotation(day.id)) {
                        destination = .rotation(day.id)
                    }
                }
                ForEach(store.data.specialDays) { sp in
                    Chip(title: sp.name, accent: sp.accent, selected: destination == .special(sp.id)) {
                        destination = .special(sp.id)
                    }
                }
                Chip(title: "+ New Day", selected: destination == .newRotation) { destination = .newRotation }
                Chip(title: "+ New Special Day", selected: destination == .newSpecial) { destination = .newSpecial }
            }

            if destination == .newRotation || destination == .newSpecial {
                HStack(spacing: 8) {
                    MicroLabel(text: "Name", color: DS.fog, size: 9).frame(width: 40, alignment: .leading)
                    DSTextField(placeholder: "e.g. C", text: $newName).frame(width: 200)
                    Text(destination == .newRotation
                         ? "Added to the end of the cycle."
                         : "Available to assign to dates in the Calendar tab.")
                        .font(DS.text(11))
                        .foregroundStyle(DS.ash)
                }
            } else {
                HStack(spacing: 6) {
                    Chip(title: "Replace what's there", selected: replaceExisting) { replaceExisting = true }
                    Chip(title: "Add to it", selected: !replaceExisting) { replaceExisting = false }
                    Spacer()
                    Text(existingCountLine)
                        .font(DS.text(11))
                        .foregroundStyle(DS.ash)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .dsCard()
    }

    private var existingCountLine: String {
        let existing: Int
        switch destination {
        case .rotation(let id): existing = store.data.rotationDay(id: id)?.periods.count ?? 0
        case .special(let id):  existing = store.data.specialDay(id: id)?.periods.count ?? 0
        default: return ""
        }
        guard existing > 0 else { return "That day is empty." }
        return replaceExisting
            ? "\(existing) existing class\(existing == 1 ? "" : "es") will be removed."
            : "Kept alongside \(existing) existing class\(existing == 1 ? "" : "es")."
    }

    // MARK: Loading a picture

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Read Schedule"
        guard panel.runModal() == .OK, let url = panel.url, let picked = NSImage(contentsOf: url) else { return }
        begin(image: picked, name: url.lastPathComponent)
    }

    private func pasteImage() {
        let board = NSPasteboard.general
        if let objects = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let picked = objects.first {
            begin(image: picked, name: "Pasted picture")
            return
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first, let picked = NSImage(contentsOf: url) {
            begin(image: picked, name: url.lastPathComponent)
            return
        }
        failure = "There's no picture on the clipboard. Take a screenshot with ⌃⌘⇧4, then press Paste."
    }

    private func load(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      let picked = NSImage(contentsOf: url) else { return }
                DispatchQueue.main.async { begin(image: picked, name: url.lastPathComponent) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let picked = object as? NSImage else { return }
                DispatchQueue.main.async { begin(image: picked, name: "Dropped picture") }
            }
            return true
        }
        return false
    }

    private func begin(image picked: NSImage, name: String) {
        image = picked
        imageName = name
        failure = nil
        withAnimation(DS.state) { phase = .reading }

        ScheduleImporter.read(image: picked) { outcome in
            if let problem = outcome.failure, outcome.drafts.isEmpty {
                failure = problem
                withAnimation(DS.state) { phase = .pick }
                return
            }
            result = outcome
            drafts = outcome.drafts
            if newName.isEmpty { newName = outcome.suggestedName ?? "" }
            withAnimation(DS.state) { phase = .review }
        }
    }

    // MARK: Saving

    private func applyImport() {
        let periods = included.map(\.period)
        guard !periods.isEmpty else { return }

        switch destination {
        case .rotation(let id):
            let existing = replaceExisting ? [] : (store.data.rotationDay(id: id)?.periods ?? [])
            store.setPeriods((existing + periods).sorted { $0.start < $1.start }, rotationID: id)
        case .special(let id):
            let existing = replaceExisting ? [] : (store.data.specialDay(id: id)?.periods ?? [])
            store.setPeriods((existing + periods).sorted { $0.start < $1.start }, specialID: id)
        case .newRotation:
            store.addRotationDay(named: newName, periods: periods)
        case .newSpecial:
            store.addSpecialDay(named: newName, periods: periods)
        }
        dismiss()
    }
}

// MARK: - Suggestion chip

/// The other read's answer for a field, one tap away. Blue because it's a proposal,
/// not a state — nothing changes until it's pressed.
struct SuggestionChip: View {
    var text: String
    var icon: String = "arrow.triangle.2.circlepath"
    var help: String = "Use what the other read of the picture found"
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                Text(text).font(DS.text(10, .bold))
            }
            .foregroundStyle(DS.signalBlue)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                ZStack {
                    Capsule().fill(DS.signalBlue.opacity(hovering ? 0.16 : 0.09))
                    Capsule().strokeBorder(DS.signalBlue.opacity(0.35), lineWidth: 1)
                }
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.hover) { hovering = h } }
        .help(help)
    }
}
