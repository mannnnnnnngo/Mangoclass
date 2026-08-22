import AppKit
import CoreImage
import Foundation
import Vision

// MARK: - Issues

/// Everything the importer noticed but couldn't decide on its own. These drive the
/// badges in the review sheet — nothing is ever written to disk unnoticed.
enum ImportIssue: String, Hashable {
    // Worked out by re-checking the finished list.
    case endBeforeStart
    case overlapsPrevious
    case veryLong
    case veryShort
    case missingName
    // Noticed while reading the picture.
    case inferredEnd
    case lowConfidence
    case disagreement
    case secondReadOnly
    case firstReadOnly
    case extraRange
    case extraColumns

    var label: String {
        switch self {
        case .endBeforeStart:  return "Ends before it starts"
        case .overlapsPrevious: return "Overlaps the class above"
        case .veryLong:        return "Over 3 hours long"
        case .veryShort:       return "Under 5 minutes long"
        case .missingName:     return "No name found"
        case .inferredEnd:     return "End time guessed"
        case .lowConfidence:   return "Hard to read"
        case .disagreement:    return "The two reads differ"
        case .secondReadOnly:  return "Only the second read saw this"
        case .firstReadOnly:   return "Only the first read saw this"
        case .extraRange:      return "Two time ranges on one line"
        case .extraColumns:    return "Several columns on one line"
        }
    }

    /// Warnings are the ones worth stopping for; the rest are just notes.
    var isWarning: Bool {
        switch self {
        case .endBeforeStart, .overlapsPrevious, .missingName, .disagreement, .firstReadOnly,
             .extraColumns, .extraRange:
            return true
        default:
            return false
        }
    }
}

// MARK: - Draft

/// One candidate class, still editable and not yet part of any schedule.
struct DraftPeriod: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var location: String = ""
    var start: Int
    var end: Int
    var include: Bool = true

    /// Issues spotted while reading the picture. Validation issues are recomputed
    /// from the current values instead of being stored, so editing a row clears them.
    var readIssues: [ImportIssue] = []

    /// What the *other* read of the picture thought, when it disagreed. Shown as
    /// one-tap chips so a wrong OCR guess is a click to fix rather than a retype.
    var altName: String?
    var altStart: Int?
    var altEnd: Int?

    var confidence: Double = 1
    var sourceLine: String = ""

    var period: Period {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Period(name: cleaned.isEmpty ? "Class" : cleaned,
                      start: start, end: end,
                      location: location.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Result

struct ImportResult {
    var drafts: [DraftPeriod] = []
    /// A likely title for the schedule, taken from a line above the classes.
    var suggestedName: String?
    /// Plain-language summary of what the two reads agreed and disagreed on.
    var checkNotes: [String] = []
    /// Lines with no times in them, kept so the user can see what was skipped.
    var skippedLines: [String] = []
    var failure: String?
}

// MARK: - Reading a picture

enum ScheduleImporter {

    /// Reads a schedule out of `image` twice — once from the picture as-is and once
    /// from a cleaned-up copy — then compares the two. Anything the reads disagree
    /// on comes back flagged rather than silently resolved.
    static func read(image: NSImage, completion: @escaping (ImportResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = readSync(image: image)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func readSync(image: NSImage) -> ImportResult {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ImportResult(failure: "That file couldn't be opened as an image.")
        }

        // Two deliberately different reads. The first keeps the raw pixels and turns
        // language correction off, which is kinder to times and room numbers; the
        // second works on an upscaled, contrast-boosted copy with correction on,
        // which is kinder to class names. Where they land in the same place we can
        // trust the row; where they don't, the user gets asked.
        let first = OCR.cells(in: cg, languageCorrection: false)
        let secondImage = OCR.enhanced(cg) ?? cg
        let second = OCR.cells(in: secondImage, languageCorrection: true)

        if first.isEmpty && second.isEmpty {
            return ImportResult(failure: "No text found in that picture. A sharper or larger photo usually helps.")
        }

        let passA = ScheduleParser.parse(cells: first)
        let passB = ScheduleParser.parse(cells: second)

        // Whichever read found more classes leads; the other one checks its work.
        let leadIsA = passA.drafts.count >= passB.drafts.count
        let lead = leadIsA ? passA : passB
        let check = leadIsA ? passB : passA

        var result = ImportResult()
        let merged = reconcile(lead: lead.drafts, check: check.drafts)
        result.drafts = merged.drafts.sorted { $0.start < $1.start }
        result.suggestedName = lead.suggestedName ?? check.suggestedName
        result.skippedLines = lead.skippedLines

        // The double-check summary, in plain words.
        let total = lead.drafts.count
        if total == 0 {
            result.failure = "Text was found, but none of it looked like class times. "
                + "The importer needs lines that pair a name with a time, like \"Period 1  8:30 – 9:55\"."
            return result
        }
        if merged.agreed == total && merged.checkOnly == 0 {
            result.checkNotes.append("Read twice — both reads agreed on all \(total) \(total == 1 ? "class" : "classes").")
        } else {
            var parts: [String] = []
            parts.append("\(merged.agreed) of \(total) matched exactly")
            if merged.differed > 0 { parts.append("\(merged.differed) differed") }
            if merged.leadOnly > 0 { parts.append("\(merged.leadOnly) only in one read") }
            if merged.checkOnly > 0 { parts.append("\(merged.checkOnly) extra found by the other read") }
            result.checkNotes.append("Read twice — " + parts.joined(separator: ", ") + ". Those rows are marked below.")
        }
        // A schedule written as start times only puts the same badge on every row,
        // which is noise. Say it once at the top instead.
        if result.drafts.count >= 3, result.drafts.allSatisfy({ $0.readIssues.contains(.inferredEnd) }) {
            for i in result.drafts.indices {
                result.drafts[i].readIssues.removeAll { $0 == .inferredEnd }
            }
            result.checkNotes.append("The picture only gave start times, so each class was set to end when the next one begins. "
                + "The last one was given 45 minutes.")
        }
        if lead.gridRows >= 2 {
            result.checkNotes.append("This looks like a week-at-a-glance grid with a column per day. "
                + "Only the first column became class names — the rest landed in Room. "
                + "Cropping the picture to one day's column and importing again gives a much cleaner result.")
        }
        if lead.inferredMeridiems > 0 {
            result.checkNotes.append("\(lead.inferredMeridiems) time\(lead.inferredMeridiems == 1 ? "" : "s") had no AM/PM, "
                + "so morning and afternoon were worked out from the running order. Check the afternoon rows.")
        }
        if !result.skippedLines.isEmpty {
            let n = result.skippedLines.count
            result.checkNotes.append("\(n) line\(n == 1 ? "" : "s") had no times and \(n == 1 ? "was" : "were") skipped.")
        }
        return result
    }

    // MARK: Cross-check

    struct Reconciled {
        var drafts: [DraftPeriod]
        var agreed = 0
        var differed = 0
        var leadOnly = 0
        var checkOnly = 0
    }

    /// Lines up the two reads and records where they part company.
    static func reconcile(lead: [DraftPeriod], check: [DraftPeriod]) -> Reconciled {
        var out = Reconciled(drafts: [])
        var used = Set<Int>()

        for var draft in lead {
            guard let j = bestMatch(for: draft, in: check, excluding: used) else {
                draft.readIssues.append(.firstReadOnly)
                out.leadOnly += 1
                out.drafts.append(draft)
                continue
            }
            used.insert(j)
            let other = check[j]
            var differs = false
            if other.start != draft.start { draft.altStart = other.start; differs = true }
            if other.end != draft.end { draft.altEnd = other.end; differs = true }
            if normalized(other.name) != normalized(draft.name), !other.name.isEmpty {
                draft.altName = other.name
                differs = true
            }
            // The cleaner second read usually wins on room text, so fill a blank in.
            if draft.location.isEmpty, !other.location.isEmpty { draft.location = other.location }
            if differs {
                draft.readIssues.append(.disagreement)
                out.differed += 1
            } else {
                out.agreed += 1
            }
            draft.confidence = max(draft.confidence, other.confidence)
            out.drafts.append(draft)
        }

        // Rows only the checking read found. Kept visible but switched off by default —
        // they're as likely to be a misread header as a missed class.
        for (j, var extra) in check.enumerated() where !used.contains(j) {
            extra.readIssues.append(.secondReadOnly)
            extra.include = false
            out.checkOnly += 1
            out.drafts.append(extra)
        }
        return out
    }

    private static func bestMatch(for draft: DraftPeriod, in list: [DraftPeriod],
                                  excluding used: Set<Int>) -> Int? {
        var best: (index: Int, distance: Int)?
        for (i, candidate) in list.enumerated() where !used.contains(i) {
            let distance = abs(candidate.start - draft.start)
            let sameName = !draft.name.isEmpty && normalized(candidate.name) == normalized(draft.name)
            guard distance <= 12 || (sameName && distance <= 90) else { continue }
            if best == nil || distance < best!.distance { best = (i, distance) }
        }
        return best?.index
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Validation

    /// Re-checks the finished list and hands back the problems per row. Recomputed on
    /// every render so fixing a time makes its warning disappear straight away.
    static func validate(_ drafts: [DraftPeriod]) -> [UUID: [ImportIssue]] {
        var out: [UUID: [ImportIssue]] = [:]
        let live = drafts.filter(\.include).sorted { $0.start < $1.start }
        var previousEnd: Int?
        var previousID: UUID?

        for d in live {
            var issues: [ImportIssue] = []
            if d.end <= d.start { issues.append(.endBeforeStart) }
            else {
                let length = d.end - d.start
                if length > 180 { issues.append(.veryLong) }
                if length < 5 { issues.append(.veryShort) }
            }
            if d.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.missingName) }
            if let end = previousEnd, d.start < end, previousID != d.id {
                issues.append(.overlapsPrevious)
            }
            if !issues.isEmpty { out[d.id] = issues }
            previousEnd = max(previousEnd ?? d.end, d.end)
            previousID = d.id
        }
        return out
    }

    /// Every issue on a row: what reading the picture turned up, plus what checking
    /// the current values turns up right now.
    static func issues(for draft: DraftPeriod, validation: [UUID: [ImportIssue]]) -> [ImportIssue] {
        var all = validation[draft.id] ?? []
        all.append(contentsOf: draft.readIssues)
        return all
    }
}

// MARK: - Vision

enum OCR {

    /// One chunk of recognized text and where it sat on the page.
    struct Cell {
        var text: String
        /// Normalized, origin bottom-left — Vision's coordinate space.
        var box: CGRect
        var confidence: Double
    }

    static func cells(in image: CGImage, languageCorrection: Bool) -> [Cell] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        request.recognitionLanguages = ["en-US"]
        // School schedules are dense tables; the default floor drops small rows.
        request.minimumTextHeight = 0.006

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Cell(text: text, box: observation.boundingBox, confidence: Double(candidate.confidence))
        }
    }

    /// Upscaled, desaturated, contrast-boosted copy — the second read's source.
    /// Photos of a wall poster and low-res screenshots both gain a lot from this.
    static func enhanced(_ image: CGImage) -> CGImage? {
        var ci = CIImage(cgImage: image)

        let scale = min(3, max(1, 2400 / CGFloat(max(image.width, 1))))
        if scale > 1.01, let f = CIFilter(name: "CILanczosScaleTransform") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(scale, forKey: kCIInputScaleKey)
            f.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let out = f.outputImage { ci = out }
        }
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(0.0, forKey: kCIInputSaturationKey)
            f.setValue(1.35, forKey: kCIInputContrastKey)
            f.setValue(0.02, forKey: kCIInputBrightnessKey)
            if let out = f.outputImage { ci = out }
        }
        guard !ci.extent.isInfinite else { return nil }
        return CIContext(options: nil).createCGImage(ci, from: ci.extent)
    }
}

// MARK: - Times in text

/// A clock time exactly as it was written, before morning/afternoon is settled.
struct RawTime {
    enum Meridiem { case am, pm }
    var hour: Int
    var minute: Int
    var meridiem: Meridiem?
}

enum TimeScanner {

    struct Hit {
        var range: NSRange
        var time: RawTime
    }

    // OCR routinely turns ":" into ".", ";" or an apostrophe, so all of them count
    // as the separator. The meridiem is optional here because the colon already
    // proves this is a time.
    private static let colonTime = try! NSRegularExpression(
        pattern: "(?<![0-9])([0-9]{1,2})\\s*[:.;'\u{2019}\u{02BC}]\\s*([0-9]{2})\\s*(?:([apAP])\\s*\\.?\\s*[mM]?\\.?)?(?![0-9])")

    // "8 AM" has no separator to lean on, so the "m" is required — otherwise a
    // trailing day letter ("Chemistry 3 A") would read as a time.
    private static let hourTime = try! NSRegularExpression(
        pattern: "(?<![0-9:.])([0-9]{1,2})\\s*([apAP])\\s*\\.?\\s*[mM]\\.?(?![0-9])")

    // Last resort for schedules typed without colons: "830-955".
    private static let bareRange = try! NSRegularExpression(
        pattern: "(?<![0-9])([0-9]{3,4})\\s*[-\u{2013}\u{2014}]\\s*([0-9]{3,4})(?![0-9])")

    static func hits(in text: String) -> [Hit] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [Hit] = []

        for m in colonTime.matches(in: text, range: full) {
            guard let hour = intAt(m, 1, ns), let minute = intAt(m, 2, ns) else { continue }
            guard let time = make(hour: hour, minute: minute, meridiem: letterAt(m, 3, ns)) else { continue }
            found.append(Hit(range: m.range, time: time))
        }
        for m in hourTime.matches(in: text, range: full) {
            guard !found.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) else { continue }
            guard let hour = intAt(m, 1, ns) else { continue }
            guard let time = make(hour: hour, minute: 0, meridiem: letterAt(m, 2, ns)) else { continue }
            found.append(Hit(range: m.range, time: time))
        }
        if found.count < 2 {
            for m in bareRange.matches(in: text, range: full) {
                guard let a = digitsToTime(stringAt(m, 1, ns)), let b = digitsToTime(stringAt(m, 2, ns)) else { continue }
                found = [Hit(range: m.range(at: 1), time: a), Hit(range: m.range(at: 2), time: b)]
                break
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The text with every recognized time cut out of it.
    static func stripped(_ text: String, hits: [Hit]) -> String {
        let ns = NSMutableString(string: text)
        for hit in hits.sorted(by: { $0.range.location > $1.range.location }) {
            ns.replaceCharacters(in: hit.range, with: " ")
        }
        return ns as String
    }

    private static func make(hour: Int, minute: Int, meridiem letter: String?) -> RawTime? {
        guard minute >= 0, minute < 60, hour >= 0, hour <= 23 else { return nil }
        var m: RawTime.Meridiem?
        if let letter = letter?.lowercased() {
            // "13:00 pm" is a contradiction — trust the 24-hour number.
            if hour <= 12 { m = letter == "p" ? .pm : .am }
        }
        return RawTime(hour: hour, minute: minute, meridiem: m)
    }

    /// "1116" → 11:16, for digits that lost their colon somewhere in the picture.
    static func time(fromDigits digits: String) -> RawTime? { digitsToTime(digits) }

    private static func digitsToTime(_ digits: String) -> RawTime? {
        guard digits.count == 3 || digits.count == 4 else { return nil }
        let hour = Int(digits.prefix(digits.count - 2))
        let minute = Int(digits.suffix(2))
        guard let h = hour, let m = minute else { return nil }
        return make(hour: h, minute: m, meridiem: nil)
    }

    private static func stringAt(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String {
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }

    private static func intAt(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> Int? {
        Int(stringAt(m, i, ns))
    }

    private static func letterAt(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String? {
        let s = stringAt(m, i, ns)
        return s.isEmpty ? nil : s
    }

    // MARK: Morning or afternoon

    /// The clock readings a written time could stand for, earliest first.
    static func options(_ t: RawTime) -> [Int] {
        if let m = t.meridiem {
            var h = t.hour % 12
            if m == .pm { h += 12 }
            return [h * 60 + t.minute]
        }
        if t.hour > 12 || t.hour == 0 { return [t.hour * 60 + t.minute] }  // written in 24-hour
        if t.hour == 12 { return [t.minute, 12 * 60 + t.minute].sorted() } // midnight or noon
        return [t.hour * 60 + t.minute, (t.hour + 12) * 60 + t.minute]
    }

    /// Settles a written time against what came before it. School days run forwards,
    /// so the earliest reading that still moves the day along is the right one —
    /// which is how "12:20", "1:45" reads as afternoon without an am/pm anywhere.
    static func resolve(_ t: RawTime, after previous: Int) -> (minutes: Int, inferred: Bool) {
        let choices = options(t).sorted()
        let inferred = t.meridiem == nil && choices.count > 1
        if let fit = choices.first(where: { $0 >= previous }) { return (fit, inferred) }
        return (choices[0], inferred)  // nothing fits — keep it as written and let validation shout
    }
}

// MARK: - Parsing

enum ScheduleParser {

    struct Output {
        var drafts: [DraftPeriod] = []
        var suggestedName: String?
        var skippedLines: [String] = []
        var inferredMeridiems = 0
        var gridRows = 0
    }

    /// One line of the picture: the times on it, whatever text was left over, and
    /// how sure Vision was about the worst part of it.
    private struct Line {
        var start: RawTime?
        var end: RawTime?
        var labels: [String] = []
        var confidence: Double = 1
        var extraRange = false
        var extraColumns = false
        var raw: String = ""
    }

    static func parse(cells: [OCR.Cell]) -> Output {
        let rows = group(cells)
        var lines: [Line] = []
        var output = Output()

        for row in rows {
            let line = read(row: row)
            if line.start == nil {
                if let title = row.map(\.text).joined(separator: " ").nonEmptyTrimmed {
                    output.skippedLines.append(title)
                }
            }
            lines.append(line)
        }

        // A short line above the first class is usually the schedule's name — but the
        // line directly above it is just as often the table's column headings.
        if let firstTimeIndex = lines.firstIndex(where: { $0.start != nil }) {
            output.suggestedName = lines[..<firstTimeIndex]
                .compactMap { $0.raw.nonEmptyTrimmed }
                .last { $0.count <= 28 && $0.contains(where: \.isLetter) && !isColumnHeading($0) }
        }

        var previous = 5 * 60  // nothing lands before 5am unless the picture says so
        for (i, line) in lines.enumerated() {
            guard let rawStart = line.start else { continue }

            let (start, startInferred) = TimeScanner.resolve(rawStart, after: previous)
            if startInferred { output.inferredMeridiems += 1 }
            previous = start

            var end: Int
            var guessedEnd = false
            if let rawEnd = line.end {
                let (value, inferred) = TimeScanner.resolve(rawEnd, after: start)
                if inferred { output.inferredMeridiems += 1 }
                end = value
            } else {
                // No end on this line — borrow the next class's start, which is how
                // start-time-only schedules ("8:30 Math / 9:25 History") are written.
                guessedEnd = true
                if let next = lines[(i + 1)...].first(where: { $0.start != nil })?.start,
                   case let candidate = TimeScanner.resolve(next, after: start).minutes,
                   candidate > start, candidate - start <= 180 {
                    end = candidate
                } else {
                    end = min(start + 45, 23 * 60 + 59)
                }
            }
            previous = max(start, end)

            let (name, location) = split(labels: line.labels)
            var draft = DraftPeriod(name: name, location: location, start: start, end: end,
                                    confidence: line.confidence, sourceLine: line.raw)
            if guessedEnd { draft.readIssues.append(.inferredEnd) }
            if line.extraRange { draft.readIssues.append(.extraRange) }
            if line.extraColumns {
                draft.readIssues.append(.extraColumns)
                output.gridRows += 1
            }
            if line.confidence < 0.45 { draft.readIssues.append(.lowConfidence) }
            output.drafts.append(draft)
        }

        return output
    }

    // MARK: Rows

    /// Vision hands back a box per chunk of text, not per row, so a table arrives as
    /// scattered cells. Anything that shares most of its height with the row being
    /// built belongs to that row.
    private static func group(_ cells: [OCR.Cell]) -> [[OCR.Cell]] {
        let sorted = cells.sorted { $0.box.midY > $1.box.midY }
        var rows: [[OCR.Cell]] = []

        for cell in sorted {
            if let last = rows.indices.last {
                let top = rows[last].map(\.box.maxY).max() ?? 0
                let bottom = rows[last].map(\.box.minY).min() ?? 0
                let overlap = min(top, cell.box.maxY) - max(bottom, cell.box.minY)
                let shortest = min(top - bottom, cell.box.height)
                if shortest > 0, overlap / shortest > 0.45 {
                    rows[last].append(cell)
                    continue
                }
            }
            rows.append([cell])
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    private static func read(row: [OCR.Cell]) -> Line {
        var line = Line()
        line.raw = row.map(\.text).joined(separator: "  ")
        line.confidence = row.map(\.confidence).min() ?? 1

        var times: [RawTime] = []
        for cell in row {
            let hits = TimeScanner.hits(in: cell.text)
            times.append(contentsOf: hits.map(\.time))
            let leftover = TimeScanner.stripped(cell.text, hits: hits)
            if let label = clean(leftover) { line.labels.append(label) }
        }

        if times.count >= 2 {
            line.start = times[0]
            line.end = times[1]
            // Four-plus times means the picture has several day columns side by side;
            // take the first pair and say so rather than inventing a merge.
            line.extraRange = times.count >= 4
        } else if times.count == 1 {
            line.start = times[0]
            // A lost colon turns "11:16" into a bare "1116", which would otherwise be
            // filed as a room. Four digits that read as a clock time, on a row that's
            // missing its end, are far more likely to be that end time.
            if let i = line.labels.firstIndex(where: { $0.count == 4 && $0.allSatisfy(\.isNumber) }),
               let recovered = TimeScanner.time(fromDigits: line.labels[i]) {
                line.end = recovered
                line.labels.remove(at: i)
            }
        }
        // More than a name and a room left over usually means a week-at-a-glance grid
        // with a column per day. Nothing is thrown away, but the row gets flagged.
        line.extraColumns = line.labels.count >= 3
        return line
    }

    /// Drops the leftovers that are punctuation, a dangling "to", or pure noise.
    /// Bare numbers survive: in a table they're the room column or the period number.
    private static func clean(_ raw: String) -> String? {
        let junk = CharacterSet(charactersIn: " \t-\u{2013}\u{2014}:;|,.()[]•·*\u{2192}")
        let trimmed = raw.trimmingCharacters(in: junk)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        guard !["to", "am", "pm", "a.m.", "p.m.", "till", "until"].contains(lower) else { return nil }
        if trimmed.contains(where: \.isLetter) { return trimmed.count > 1 ? trimmed : nil }
        return trimmed.allSatisfy(\.isNumber) && trimmed.count <= 5 ? trimmed : nil
    }

    private static let headingWords: Set<String> = [
        "class", "classes", "course", "subject", "room", "rm", "location", "teacher",
        "start", "starts", "begin", "begins", "end", "ends", "time", "times", "day", "days",
        // A single weekday is a fine name for a schedule; a row of them is a grid heading.
        "monday", "tuesday", "wednesday", "thursday", "friday", "mon", "tue", "tues",
        "wed", "thu", "thur", "thurs", "fri",
    ]

    /// "CLASS  ROOM  START  END" is a table's headings, not the schedule's name.
    private static func isColumnHeading(_ line: String) -> Bool {
        let words = line.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 2 else { return false }
        return words.filter { headingWords.contains($0) }.count >= 2
    }

    // MARK: Name vs room

    private static let roomWords = ["room", "rm", "rm.", "bldg", "building", "lab", "gym", "hall", "wing", "portable"]

    /// The leftover text on a row, sorted into a class name and a room. Separate
    /// table cells make this easy; a single run of text needs the room words.
    private static func split(labels: [String]) -> (name: String, location: String) {
        guard !labels.isEmpty else { return ("", "") }

        // A number in its own cell means one of two columns depending on which side
        // of the name it sits: a period number on the left, a room on the right.
        guard let nameIndex = labels.firstIndex(where: { $0.contains(where: \.isLetter) }) else {
            return (labels.joined(separator: " "), "")
        }
        let lead = labels[..<nameIndex].joined(separator: " ")
        let trail = labels[(nameIndex + 1)...].joined(separator: " ")
        let first = lead.isEmpty ? labels[nameIndex] : lead + " " + labels[nameIndex]
        if !trail.isEmpty { return (first, trail) }

        let words = first.split(separator: " ").map(String.init)
        guard words.count > 1 else { return (first, "") }

        // "Biology Room 204" / "Biology Lab 3" — the room word and everything after it.
        if let i = words.indices.dropFirst().last(where: { roomWords.contains(words[$0].lowercased()) }),
           i < words.count - 1 {
            return (words[..<i].joined(separator: " "), words[i...].joined(separator: " "))
        }
        // "Biology 204" — a bare number or letter-plus-number hanging off the end.
        if let last = words.last, looksLikeRoom(last), words.count > 1 {
            return (words.dropLast().joined(separator: " "), last)
        }
        return (first, "")
    }

    private static func looksLikeRoom(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "#()"))
        guard t.count >= 2, t.count <= 5, t.contains(where: \.isNumber) else { return false }
        return t.allSatisfy { $0.isNumber || $0.isLetter }
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
