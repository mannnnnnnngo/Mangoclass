import Foundation
import AppKit
import Combine
import CryptoKit

// MARK: - Version numbers

/// major.minor.patch, compared the way you'd expect: 0.1.0 → 0.1.1 → 0.2.0.
///
/// Anything after a `-` or `+` (`0.2.0-beta`, `0.2.0+3`) is ignored for comparison, and a
/// leading `v` is tolerated so a git tag (`v0.1.1`) parses without being trimmed first.
struct SemVer: Comparable, CustomStringConvertible, Codable {
    var major: Int
    var minor: Int
    var patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        text = text.components(separatedBy: CharacterSet(charactersIn: "-+"))[0]

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var numbers = [0, 0, 0]
        for (i, part) in parts.enumerated() {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers[i] = n
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

// MARK: - What the server says the latest version is

/// One published release, as written by `release.sh` into `updates/latest.json`.
struct UpdateManifest: Codable, Equatable {
    var version: String
    var build: Int?
    var publishedAt: String?
    var minimumSystemVersion: String?
    var notes: String?
    var downloadURL: String?
    var sha256: String?
    var releasePage: String?

    var semver: SemVer? { SemVer(version) }

    var downloadLink: URL? {
        guard let downloadURL, !downloadURL.isEmpty else { return nil }
        return URL(string: downloadURL)
    }

    var releaseLink: URL? {
        guard let releasePage, !releasePage.isEmpty else { return nil }
        return URL(string: releasePage)
    }

    /// A checksum only counts if it's a real one — `release.sh` always writes it, but a
    /// hand-edited manifest might leave it out, and an empty string must not read as "matches".
    var checksum: String? {
        guard let sha256 else { return nil }
        let clean = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean.count == 64 ? clean : nil
    }

    /// Whether this Mac is new enough to run the release.
    var runsOnThisMac: Bool {
        guard let required = SemVer(minimumSystemVersion ?? "") else { return true }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let here = SemVer(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion)
        return here >= required
    }
}

// MARK: - Status

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateManifest)
    case downloading(UpdateManifest, Double)
    case ready(UpdateManifest, URL)
    case installing
    case failed(String)

    var manifest: UpdateManifest? {
        switch self {
        case .available(let m), .downloading(let m, _), .ready(let m, _): return m
        case .idle, .checking, .upToDate, .installing, .failed: return nil
        }
    }

    /// True while something is in flight — the check button greys out rather than stacking work.
    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
}

// MARK: - Preferences
//
// These live in UserDefaults on purpose, not in schedule.json. That file is the user's
// timetable and its format is deliberately left exactly as it was — an update must never
// be a reason for a schedule to be rewritten, migrated, or lost.

enum UpdatePrefs {
    private static let d = UserDefaults.standard

    private enum Key {
        static let autoCheck = "updates.checkAutomatically"
        static let autoDownload = "updates.downloadAutomatically"
        static let autoInstall = "updates.installAutomatically"
        static let lastCheck = "updates.lastCheck"
        static let skipped = "updates.skippedVersion"
        static let announced = "updates.announcedVersion"
    }

    static var checkAutomatically: Bool {
        get { d.object(forKey: Key.autoCheck) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.autoCheck) }
    }

    static var downloadAutomatically: Bool {
        get { d.object(forKey: Key.autoDownload) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.autoDownload) }
    }

    /// Off by default: replacing the app relaunches it, and that shouldn't happen
    /// unasked in the middle of a class.
    static var installAutomatically: Bool {
        get { d.object(forKey: Key.autoInstall) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.autoInstall) }
    }

    static var lastCheck: Date? {
        get { d.object(forKey: Key.lastCheck) as? Date }
        set { d.set(newValue, forKey: Key.lastCheck) }
    }

    /// A version the user pressed "Skip" on. Later versions still come through.
    static var skippedVersion: String? {
        get { d.string(forKey: Key.skipped) }
        set { d.set(newValue, forKey: Key.skipped) }
    }

    /// The last version we put a dialog on screen for, so it's shown once and not every check.
    static var announcedVersion: String? {
        get { d.string(forKey: Key.announced) }
        set { d.set(newValue, forKey: Key.announced) }
    }
}

// MARK: - Updater

/// Checks a small JSON manifest on GitHub, downloads the published `.dmg`, and swaps the
/// app bundle out from under itself with a helper script.
///
/// Nothing outside the app bundle is touched. `~/Library/Application Support/ClassSchedule`
/// — the schedules — is only ever read, and only to copy a backup alongside the download.
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// Raw GitHub rather than the releases API: no rate limit, no auth, and the file is
    /// edited by `release.sh` in the same commit that ships the build.
    static let manifestURL = URL(string:
        "https://raw.githubusercontent.com/mannnnnnnngo/Mangoclass/main/updates/latest.json")!

    /// How often a copy that's been left open asks whether there's something newer.
    ///
    /// The promise is ten minutes: a release goes out, and every running mangoclass knows
    /// about it inside ten, without anyone clicking anything. `pollInterval` is the timer;
    /// `checkInterval` is deliberately a minute shorter, so a tick that arrives slightly
    /// early still counts as due instead of skipping a whole round and doubling the wait.
    ///
    /// The file being fetched is a few hundred bytes off `raw.githubusercontent.com`,
    /// which has no rate limit and caches for about five minutes — so polling harder than
    /// this would mostly re-read the same cached answer.
    private static let pollInterval: TimeInterval = 9 * 60
    private static let checkInterval: TimeInterval = 8 * 60

    @Published private(set) var status: UpdateStatus = .idle
    @Published private(set) var lastChecked: Date? = UpdatePrefs.lastCheck

    /// The last thing that went wrong, kept separately from `status` so a failed download
    /// doesn't lose track of the update that's still waiting to be installed.
    @Published private(set) var lastError: String?

    /// Set once an update is found and cleared when it's installed or skipped — this is
    /// what puts the dot in the menu bar and the strip at the top of the panel.
    @Published var pendingBannerDismissed = false

    /// `status` is `private(set)`, so hand out the publisher explicitly rather than
    /// relying on `$status` being reachable from outside the class.
    var statusPublisher: AnyPublisher<UpdateStatus, Never> { $status.eraseToAnyPublisher() }

    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var downloading: UpdateManifest?
    private var timer: Timer?

    private override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 15 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: Where things are

    var currentVersion: SemVer {
        SemVer(currentVersionString) ?? SemVer(major: 0, minor: 0, patch: 0)
    }

    var currentVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    var currentBuildString: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    /// `~/Library/Application Support/ClassSchedule/Updates` — downloads, the cached
    /// manifest, and schedule backups. Deliberately a subfolder, so `schedule.json`
    /// next to it is never in the blast radius.
    var updatesDirectory: URL {
        let dir = Store.shared.storageLocation
            .deletingLastPathComponent()
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var cachedManifestURL: URL { updatesDirectory.appendingPathComponent("manifest.json") }

    /// The manifest `install.sh` fetched at install time, so a fresh install already knows
    /// where it stands even before its first successful check.
    var cachedManifest: UpdateManifest? {
        guard let raw = try? Data(contentsOf: cachedManifestURL) else { return nil }
        return try? JSONDecoder().decode(UpdateManifest.self, from: raw)
    }

    // MARK: Scheduling

    /// Called once at launch.
    ///
    /// Every launch checks — no "checked recently" throttle on this one, so opening the app
    /// is always the way to find out whether there's something newer. The delay is only so a
    /// login-item launch isn't racing Wi-Fi coming up; if there's no network yet, the timer
    /// below picks it up later and the cached manifest covers the gap in the meantime.
    func startAutomaticChecks() {
        applyCachedManifest()

        guard UpdatePrefs.checkAutomatically else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.check(userInitiated: false)
        }

        // So it isn't only ever the launch check — this is what a copy left open all day
        // relies on. The tolerance is small on purpose: at nine minutes, letting the system
        // slide the timer by minutes at a time would eat the whole ten-minute promise.
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // A timer doesn't fire while the Mac is asleep, so a lid closed overnight would
        // otherwise wake to a stale answer and wait out another full round before asking.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard UpdatePrefs.checkAutomatically, !status.isBusy else { return }
        // Something is already found and waiting. Asking again can only turn up the same
        // version, and `finishCheck` would announce it a second time — which at this
        // polling rate would mean a dialog every nine minutes until it's installed.
        if status.manifest != nil { return }
        if let last = UpdatePrefs.lastCheck, Date().timeIntervalSince(last) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    /// Shows what the installer already downloaded, before any network call of our own.
    private func applyCachedManifest() {
        guard case .idle = status, let cached = cachedManifest else { return }
        if isNewer(cached), cached.runsOnThisMac, cached.version != UpdatePrefs.skippedVersion {
            status = .available(cached)
        }
    }

    // MARK: Checking

    func check(userInitiated: Bool) {
        guard !status.isBusy else { return }
        lastError = nil
        status = .checking

        var request = URLRequest(url: Self.manifestURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.setValue("mangoclass/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    self.finishCheck(.failure(error.localizedDescription), userInitiated: userInitiated)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    self.finishCheck(.failure("The update server answered \(http.statusCode)."),
                                     userInitiated: userInitiated)
                    return
                }
                guard let data, let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
                    self.finishCheck(.failure("Couldn't read the update information."),
                                     userInitiated: userInitiated)
                    return
                }
                try? data.write(to: self.cachedManifestURL, options: .atomic)
                self.finishCheck(.success(manifest), userInitiated: userInitiated)
            }
        }.resume()
    }

    private enum CheckResult {
        case success(UpdateManifest)
        case failure(String)
    }

    private func finishCheck(_ result: CheckResult, userInitiated: Bool) {
        switch result {
        case .failure(let message):
            // A failed automatic check is not worth interrupting anyone over — the cached
            // manifest keeps whatever we already knew.
            lastError = message
            if userInitiated {
                status = .failed(message)
            } else {
                status = .idle
                applyCachedManifest()
            }

        case .success(let manifest):
            UpdatePrefs.lastCheck = Date()
            lastChecked = UpdatePrefs.lastCheck
            lastError = nil

            guard isNewer(manifest) else {
                status = .upToDate
                return
            }
            guard manifest.runsOnThisMac else {
                status = userInitiated
                    ? .failed("Version \(manifest.version) needs macOS \(manifest.minimumSystemVersion ?? "newer") or newer.")
                    : .upToDate
                return
            }
            if !userInitiated, manifest.version == UpdatePrefs.skippedVersion {
                status = .idle
                return
            }

            status = .available(manifest)
            pendingBannerDismissed = false

            if UpdatePrefs.downloadAutomatically, manifest.downloadLink != nil {
                download(manifest, thenInstall: UpdatePrefs.installAutomatically)
            } else if !userInitiated {
                announce(manifest)
            }
        }
    }

    private func isNewer(_ manifest: UpdateManifest) -> Bool {
        guard let published = manifest.semver else { return false }
        return published > currentVersion
    }

    // MARK: Telling the user

    /// The "you need to update" notification. An alert rather than a Notification Center
    /// banner on purpose: the app asks for no permissions at all, and a notification would
    /// be the first thing it ever prompted for.
    private func announce(_ manifest: UpdateManifest) {
        guard UpdatePrefs.announcedVersion != manifest.version else { return }
        UpdatePrefs.announcedVersion = manifest.version

        let alert = NSAlert()
        alert.messageText = "mangoclass \(manifest.version) is available"
        alert.informativeText = announcementBody(manifest)
        alert.alertStyle = .informational
        alert.addButton(withTitle: readyDownload(for: manifest) != nil ? "Install & Restart" : "Update Now")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        NSApp.setActivationPolicy(SettingsWindow.shared.isOpen ? .regular : .accessory)

        switch response {
        case .alertFirstButtonReturn:  updateNow()
        case .alertThirdButtonReturn:  skip(manifest)
        default: break
        }
    }

    private func announcementBody(_ manifest: UpdateManifest) -> String {
        var lines = ["You're on \(currentVersionString)."]
        if let notes = manifest.notes, !notes.isEmpty { lines.append(notes) }
        lines.append("Your schedules are kept exactly as they are — only the app itself is replaced.")
        return lines.joined(separator: "\n\n")
    }

    func skip(_ manifest: UpdateManifest) {
        UpdatePrefs.skippedVersion = manifest.version
        cancelDownload()
        status = .idle
    }

    // MARK: Downloading

    /// Whether this release is already sitting on disk, fully downloaded and verified.
    private func readyDownload(for manifest: UpdateManifest) -> URL? {
        if case .ready(let m, let url) = status, m.version == manifest.version,
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    func download(_ manifest: UpdateManifest, thenInstall: Bool = false) {
        if let existing = readyDownload(for: manifest) {
            if thenInstall { install(manifest, dmg: existing) }
            return
        }
        guard let link = manifest.downloadLink else {
            // No file to fetch — send them to the release page and let them install by hand.
            if let page = manifest.releaseLink { NSWorkspace.shared.open(page) }
            return
        }

        installAfterDownload = thenInstall
        downloading = manifest
        status = .downloading(manifest, 0)

        var request = URLRequest(url: link, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("mangoclass/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloading = nil
        installAfterDownload = false
    }

    private var installAfterDownload = false

    // MARK: Installing

    /// The one-button path used by every "update" control in the UI.
    func updateNow() {
        switch status {
        case .ready(let manifest, let dmg): install(manifest, dmg: dmg)
        case .available(let manifest):      download(manifest, thenInstall: true)
        case .downloading:                  installAfterDownload = true
        default:                            check(userInitiated: true)
        }
    }

    func install(_ manifest: UpdateManifest, dmg: URL) {
        status = .installing
        lastError = nil
        backUpSchedules(before: manifest)

        do {
            let script = try writeInstallScript(dmg: dmg)
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Detached on purpose: this app is about to exit, and the script has to
            // outlive it in order to replace it.
            launcher.arguments = ["-c", "nohup /bin/bash \(Self.quote(script.path)) >/dev/null 2>&1 &"]
            try launcher.run()
        } catch {
            status = .failed("Couldn't start the installer: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    /// Copies the schedules next to the download before anything is replaced. The updater
    /// has no reason to write to that file — this is belt and braces, and it gives you
    /// something to drag back if you ever want the old timetable.
    private func backUpSchedules(before manifest: UpdateManifest) {
        let source = Store.shared.storageLocation
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let backup = updatesDirectory
            .appendingPathComponent("schedule-backup-\(currentVersionString).json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: source, to: backup)
    }

    /// Two scripts in a 0700 directory with no spaces in its path:
    ///
    /// - `update.sh` runs as you: waits for the app to quit, mounts the image, stages the
    ///   new bundle, swaps it in, and reopens it.
    /// - `privileged.sh` is only used when the install location isn't yours to write
    ///   (the usual `/Applications` case), and does nothing but the swap, so `open` still
    ///   runs as you afterwards and the app never starts up as root.
    private func writeInstallScript(dmg: URL) throws -> URL {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: "/tmp/mangoclass-update-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: work, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        let app = Bundle.main.bundleURL.standardizedFileURL
        let stage = work.appendingPathComponent("mangoclass.app")
        let owner = "\(getuid()):\(getgid())"

        let privileged = """
        #!/bin/bash
        # Run through osascript with administrator rights, and only when the install
        # location needs it. Replaces the bundle — nothing else.
        set -u
        /bin/rm -rf \(Self.quote(app.path))
        /usr/bin/ditto \(Self.quote(stage.path)) \(Self.quote(app.path))
        /usr/sbin/chown -R \(owner) \(Self.quote(app.path))
        """

        let privilegedURL = work.appendingPathComponent("privileged.sh")
        try privileged.write(to: privilegedURL, atomically: true, encoding: .utf8)

        let update = """
        #!/bin/bash
        # mangoclass updater. Replaces the app bundle and reopens it.
        #
        # Your schedules are in ~/Library/Application Support/ClassSchedule/schedule.json
        # and are not touched by anything in here.
        set -u

        APP=\(Self.quote(app.path))
        DMG=\(Self.quote(dmg.path))
        WORK=\(Self.quote(work.path))
        STAGE=\(Self.quote(stage.path))
        PID=\(ProcessInfo.processInfo.processIdentifier)

        exec >>"$WORK/update.log" 2>&1
        echo "=== $(date): updating $APP"

        # The app terminates itself right after starting this; wait for it to actually go.
        for _ in $(seq 1 60); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null; sleep 2; fi

        MOUNT="$WORK/mount"
        mkdir -p "$MOUNT"
        if ! hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT"; then
            echo "could not mount the disk image"
            open "$APP"
            exit 1
        fi

        if [ ! -d "$MOUNT/mangoclass.app" ]; then
            echo "no mangoclass.app inside the disk image"
            hdiutil detach "$MOUNT" -quiet -force 2>/dev/null
            open "$APP"
            exit 1
        fi

        rm -rf "$STAGE"
        if ! ditto "$MOUNT/mangoclass.app" "$STAGE"; then
            echo "could not copy the new version out of the image"
            hdiutil detach "$MOUNT" -quiet -force 2>/dev/null
            open "$APP"
            exit 1
        fi
        hdiutil detach "$MOUNT" -quiet -force 2>/dev/null

        DEST_DIR="$(dirname "$APP")"
        if [ -w "$DEST_DIR" ] && { [ ! -e "$APP" ] || [ -w "$APP" ]; }; then
            rm -rf "$APP" && ditto "$STAGE" "$APP"
        else
            echo "asking for an administrator password to write to $DEST_DIR"
            osascript -e "do shell script \\"/bin/bash $WORK/privileged.sh\\" with administrator privileges"
        fi

        if [ ! -d "$APP" ]; then
            echo "the swap failed; restoring from the staged copy"
            ditto "$STAGE" "$APP" 2>/dev/null
        fi

        xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        touch "$APP"
        open "$APP"
        echo "=== done"
        """

        let updateURL = work.appendingPathComponent("update.sh")
        try update.write(to: updateURL, atomically: true, encoding: .utf8)
        return updateURL
    }

    /// Single-quoted for /bin/bash. The Application Support path has spaces in it, so
    /// every path that reaches a script goes through here.
    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Checksum

    private func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Download progress

extension Updater: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            guard let self, let manifest = self.downloading else { return }
            if case .downloading = self.status {
                self.status = .downloading(manifest, min(max(fraction, 0), 1))
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let manifest = downloading else { return }

        // The temporary file is deleted the moment this returns, so move it first and do
        // everything else against the copy we own.
        let destination = updatesDirectory.appendingPathComponent("mangoclass-\(manifest.version).dmg")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.status = .failed("Couldn't save the download: \(error.localizedDescription)")
            }
            return
        }

        var failure: String?
        if let expected = manifest.checksum {
            let actual = sha256(of: destination)
            if actual != expected {
                try? FileManager.default.removeItem(at: destination)
                failure = "The download didn't match its checksum, so it wasn't installed."
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downloadTask = nil
            self.downloading = nil
            if let failure {
                self.installAfterDownload = false
                self.lastError = failure
                self.status = .available(manifest)
                return
            }
            self.lastError = nil
            self.status = .ready(manifest, destination)
            if self.installAfterDownload {
                self.installAfterDownload = false
                self.install(manifest, dmg: destination)
            } else {
                self.announce(manifest)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downloadTask = nil
            let manifest = self.downloading
            self.downloading = nil
            self.installAfterDownload = false
            if cancelled {
                self.status = manifest.map { UpdateStatus.available($0) } ?? UpdateStatus.idle
            } else if case .downloading = self.status {
                self.lastError = "The download failed: \(error.localizedDescription)"
                self.status = manifest.map { UpdateStatus.available($0) }
                    ?? UpdateStatus.failed(self.lastError ?? "The download failed.")
            }
        }
    }
}
