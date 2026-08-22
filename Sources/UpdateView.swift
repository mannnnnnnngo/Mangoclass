import SwiftUI
import AppKit

// MARK: - Panel banner

/// The strip that appears at the top of the countdown panel when there's a new version.
/// Quiet until there's something to say, and dismissable for the session.
struct UpdateBanner: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        if let manifest = updater.status.manifest, !updater.pendingBannerDismissed {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(DS.brandViolet)
                        .frame(width: 6, height: 6)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline(manifest))
                            .font(DS.text(12, .bold))
                            .foregroundStyle(DS.inkBlack)
                            .lineLimit(1)
                        Text(detail(manifest))
                            .font(DS.mono(9, .regular))
                            .foregroundStyle(DS.slate)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    if case .downloading(_, let progress) = updater.status {
                        Text("\(Int(progress * 100))%")
                            .font(DS.mono(10, .medium))
                            .monospacedDigit()
                            .foregroundStyle(DS.slate)
                    } else {
                        PillButton(title: buttonTitle, kind: .primary, compact: true) {
                            updater.updateNow()
                        }
                    }

                    IconButton(icon: "xmark", help: "Not now") {
                        updater.pendingBannerDismissed = true
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if case .downloading(_, let progress) = updater.status {
                    DSProgressBar(value: progress, tint: DS.brandViolet)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 9)
                }
            }
            .background(DS.brandViolet.opacity(0.06))
            Hairline()
        }
    }

    private var buttonTitle: String {
        if case .ready = updater.status { return "Install" }
        return "Update"
    }

    private func headline(_ m: UpdateManifest) -> String {
        if case .ready = updater.status { return "Version \(m.version) is ready to install" }
        if case .downloading = updater.status { return "Downloading version \(m.version)…" }
        return "Version \(m.version) is available"
    }

    private func detail(_ m: UpdateManifest) -> String {
        if case .ready = updater.status { return "Restarts the app · schedules kept" }
        return "You're on \(updater.currentVersionString)"
    }
}

// MARK: - Settings tab

struct UpdatesTab: View {
    @ObservedObject var updater = Updater.shared
    @State private var checkAutomatically = UpdatePrefs.checkAutomatically
    @State private var downloadAutomatically = UpdatePrefs.downloadAutomatically
    @State private var installAutomatically = UpdatePrefs.installAutomatically

    var body: some View { ScrollView { content } }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            versionCard
            if let manifest = updater.status.manifest { releaseCard(manifest) }
            if let error = updater.lastError { errorCard(error) }
            preferencesCard
            whereFromCard
        }
        .padding(24)
    }

    // MARK: This version

    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            MicroLabel(text: "This copy", size: 9)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(updater.currentVersionString)
                    .font(DS.display(34, .heavy))
                    .tracking(DS.em(-0.04, 34))
                    .foregroundStyle(DS.onyx)
                Text("build \(updater.currentBuildString)")
                    .font(DS.mono(10, .regular))
                    .foregroundStyle(DS.fog)
                Spacer(minLength: 8)
                statusBadge
            }

            Text(statusLine)
                .font(DS.text(12))
                .foregroundStyle(DS.slate)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                PillButton(title: updater.status.isBusy ? "Checking…" : "Check for Updates",
                           icon: "arrow.clockwise",
                           kind: .ghost, compact: true) {
                    updater.check(userInitiated: true)
                }
                if let manifest = updater.status.manifest {
                    PillButton(title: primaryTitle, kind: .primary, compact: true) {
                        updater.updateNow()
                    }
                    PillButton(title: "Skip \(manifest.version)", kind: .quiet, compact: true) {
                        updater.skip(manifest)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .dsCard()
    }

    private var primaryTitle: String {
        switch updater.status {
        case .ready:                   return "Install & Restart"
        case .downloading(_, let p):   return "Downloading \(Int(p * 100))%"
        case .installing:              return "Installing…"
        default:                       return "Download & Install"
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch updater.status {
        case .upToDate:      Badge(text: "Up to date", accent: .emerald)
        case .checking:      Badge(text: "Checking", accent: .violet)
        case .available:     Badge(text: "Update available", accent: .violet, filled: true)
        case .downloading:   Badge(text: "Downloading", accent: .violet)
        case .ready:         Badge(text: "Ready to install", accent: .violet, filled: true)
        case .installing:    Badge(text: "Installing", accent: .violet, filled: true)
        case .failed:        Badge(text: "Check failed", accent: .orange)
        case .idle:          EmptyView()
        }
    }

    private var statusLine: String {
        switch updater.status {
        case .available(let m), .downloading(let m, _), .ready(let m, _):
            return "Version \(m.version) is newer than this one."
        case .installing:
            return "mangoclass will quit, swap itself out, and reopen in a moment."
        case .checking:
            return "Asking GitHub what the latest version is…"
        case .failed(let message):
            return message
        case .upToDate, .idle:
            guard let last = updater.lastChecked else {
                return "No update check has run yet."
            }
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return "This is the newest version. Last checked \(f.string(from: last))."
        }
    }

    // MARK: What's in the new one

    private func releaseCard(_ manifest: UpdateManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MicroLabel(text: "What's new in \(manifest.version)", size: 9)
                Spacer(minLength: 8)
                if let published = manifest.publishedAt {
                    MicroLabel(text: published, color: DS.fog, size: 9)
                }
            }
            Text(manifest.notes?.isEmpty == false ? manifest.notes! : "No release notes were written for this version.")
                .font(DS.text(12))
                .foregroundStyle(DS.carbon)
                .fixedSize(horizontal: false, vertical: true)

            Text("Installing replaces the app only. Your schedules stay in ~/Library/Application Support/ClassSchedule, and a copy of them is saved next to the download first.")
                .font(DS.text(11))
                .foregroundStyle(DS.ash)
                .fixedSize(horizontal: false, vertical: true)

            if let page = manifest.releaseLink {
                PillButton(title: "Open the release page", icon: "arrow.up.right", kind: .quiet, compact: true) {
                    NSWorkspace.shared.open(page)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .dsCard(fill: DS.mist)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel(text: "Last problem", color: DS.ash, size: 9)
            Text(message)
                .font(DS.text(12))
                .foregroundStyle(DS.carbon)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing was changed. You can try again, or download the new version by hand from the release page.")
                .font(DS.text(11))
                .foregroundStyle(DS.ash)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .dsCard(fill: DS.mist)
    }

    // MARK: Preferences

    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicroLabel(text: "Automatic updates", size: 9)

            DSToggle(title: "Check when the app opens",
                     subtitle: "Every launch, plus every few hours while it's running.",
                     isOn: Binding(get: { checkAutomatically },
                                   set: { checkAutomatically = $0; UpdatePrefs.checkAutomatically = $0 }))

            DSToggle(title: "Download in the background",
                     subtitle: "Fetches the new version as soon as it's found, so installing is instant.",
                     isOn: Binding(get: { downloadAutomatically },
                                   set: { downloadAutomatically = $0; UpdatePrefs.downloadAutomatically = $0 }))

            DSToggle(title: "Install without asking",
                     subtitle: "Off by default — installing restarts the app, and that shouldn't happen in the middle of a class.",
                     isOn: Binding(get: { installAutomatically },
                                   set: { installAutomatically = $0; UpdatePrefs.installAutomatically = $0 }))

            if let skipped = UpdatePrefs.skippedVersion {
                HStack(spacing: 8) {
                    Text("Version \(skipped) is being skipped.")
                        .font(DS.text(11))
                        .foregroundStyle(DS.ash)
                    PillButton(title: "Un-skip", kind: .quiet, compact: true) {
                        UpdatePrefs.skippedVersion = nil
                        updater.check(userInitiated: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .dsCard()
    }

    // MARK: Provenance

    private var whereFromCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel(text: "Where updates come from", size: 9)
            Text(Updater.manifestURL.absoluteString)
                .font(DS.mono(10, .regular))
                .foregroundStyle(DS.slate)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("A small text file in the project's public GitHub repository, listing the newest version and where to download it. It's only ever read — nothing about this Mac is sent.")
                .font(DS.text(11))
                .foregroundStyle(DS.ash)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(title: "Show Downloads Folder", icon: "folder", kind: .ghost, compact: true) {
                NSWorkspace.shared.activateFileViewerSelecting([updater.updatesDirectory])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .dsCard(fill: DS.mist)
    }
}
