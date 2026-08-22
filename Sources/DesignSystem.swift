import SwiftUI
import AppKit

// MARK: - Color

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255,
                  opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255,
                  alpha: 1)
    }
}

extension Accent {
    var color: Color { Color(hex: hex) }
}

/// Design tokens, lifted from design.md.
enum DS {

    // MARK: Colors

    static let signalWhite = Color(hex: "ffffff")
    static let inkBlack    = Color(hex: "202020")
    static let onyx        = Color(hex: "090c1d")
    static let carbon      = Color(hex: "2a2a2a")
    static let slate       = Color(hex: "646464")
    static let ash         = Color(hex: "838383")
    static let fog         = Color(hex: "b3b3b3")
    static let cloud       = Color(hex: "d4d4d4")
    static let bone        = Color(hex: "e8e8e8")
    static let mist        = Color(hex: "f8f9fa")
    static let plaster     = Color(hex: "e9ebf0")
    /// Kept as a hex string too — the menu bar draws with NSColor, not SwiftUI.
    static let brandVioletHex = "6647f0"
    static let brandViolet = Color(hex: DS.brandVioletHex)
    static let signalBlue  = Color(hex: "0091ff")
    static let emerald     = Color(hex: "00c07a")

    // MARK: Typography
    //
    // The brand faces aren't installed, so each role resolves through its documented
    // substitute chain and falls back to the system font. Drop the real .ttf/.otf files
    // into Fonts/ and they light up automatically — see FontLoader.

    private static func firstAvailable(_ names: [String]) -> String? {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        return names.first { families.contains($0) }
    }

    static let displayFamily = firstAvailable(["Plus Jakarta Sans", "General Sans", "Inter"])
    static let textFamily    = firstAvailable(["Inter", "Plus Jakarta Sans"])
    static let monoFamily    = firstAvailable(["Sometype Mono", "JetBrains Mono", "IBM Plex Mono", "SF Mono", "Menlo"])

    /// Display type: 650–800 weight with tight negative tracking is the brand's signature.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        displayFamily.map { Font.custom($0, size: size).weight(weight) }
            ?? .system(size: size, weight: weight)
    }

    /// Body and UI copy.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        textFamily.map { Font.custom($0, size: size).weight(weight) }
            ?? .system(size: size, weight: weight)
    }

    /// Monospaced accent — status labels and wide-tracked uppercase micro labels.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        monoFamily.map { Font.custom($0, size: size).weight(weight) }
            ?? .system(size: size, weight: weight, design: .monospaced)
    }

    static func nsDisplay(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont {
        if let f = displayFamily, let font = NSFont(name: f, size: size) { return font }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// Converts the design file's em-based tracking into points at a given size.
    /// The brand's aggressive negative tracking is tuned for Plus Jakarta Sans, which is
    /// wider than the system fallback — so ease off when we're not using the real face.
    static func em(_ value: CGFloat, _ size: CGFloat) -> CGFloat {
        let factor: CGFloat = (displayFamily == nil && value < 0) ? 0.5 : 1
        return value * size * factor
    }

    // MARK: Shape

    static let radiusCard: CGFloat = 12
    static let radiusLargeCard: CGFloat = 20
    static let radiusInput: CGFloat = 9
    static let radiusPill: CGFloat = 9999

    // MARK: Motion

    /// The system's settle curve — cubic-bezier(0.33, 1, 0.68, 1) at 0.45s.
    static let settle = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 0.45)
    static let hover = Animation.easeOut(duration: 0.15)
    static let state = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 0.25)
}

// MARK: - Micro label

/// Mono, uppercase, 0.08em tracking — the design's technical meta label.
struct MicroLabel: View {
    var text: String
    var color: Color = DS.ash
    var size: CGFloat = 9

    var body: some View {
        Text(text.uppercased())
            .font(DS.mono(size, .medium))
            .tracking(DS.em(0.08, size))
            .foregroundStyle(color)
    }
}

// MARK: - App badge

/// The app icon next to the app name — the panel header and the Settings title bar.
///
/// The icon is read from the bundle rather than drawn, so it always matches whatever
/// build.sh last generated. `NSApp.applicationIconImage` is the fallback rather than
/// the first choice: this is an LSUIElement (menu bar) app, and an agent app has no
/// Dock icon for AppKit to hand back, so on some macOS versions it returns the generic
/// placeholder instead of ours.
struct AppBadge: View {
    var iconSize: CGFloat = 18
    var textSize: CGFloat = 15
    var showsName: Bool = true

    /// Loaded once — decoding the .icns on every SwiftUI redraw would be wasteful, and
    /// the panel redraws every time the clock ticks.
    private static let icon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let fallback = NSApp?.applicationIconImage
        return fallback
    }()

    var body: some View {
        HStack(spacing: 7) {
            if let icon = Self.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
                    .accessibilityHidden(true)
            }
            if showsName {
                Text("mangoclass")
                    .font(DS.display(textSize, .bold))
                    .tracking(DS.em(-0.02, textSize))
                    .foregroundStyle(DS.inkBlack)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("mangoclass")
    }
}

// MARK: - Badge

/// Full-radius status pill. Tinted fill, never a primary action.
struct Badge: View {
    var text: String
    var accent: Accent = .violet
    var filled: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(DS.mono(9, .medium))
            .tracking(DS.em(0.08, 9))
            .foregroundStyle(filled ? DS.signalWhite : accent.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(filled ? accent.color : accent.color.opacity(0.12))
            )
    }
}

// MARK: - Buttons

struct PillButton: View {
    enum Kind {
        case primary   // #202020 fill, white text — the main action
        case ghost     // transparent, 1px #e8e8e8 border
        case quiet     // no border, hover tint only
        case danger
    }

    var title: String
    var icon: String? = nil
    var kind: Kind = .ghost
    var compact: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: compact ? 9 : 10, weight: .bold)) }
                Text(title).font(DS.text(compact ? 11 : 13, .bold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 5 : 8)
            .background(
                ZStack {
                    Capsule().fill(background)
                    Capsule().strokeBorder(border, lineWidth: 1)
                }
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.hover) { hovering = h } }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return DS.signalWhite
        case .ghost:   return DS.inkBlack
        case .quiet:   return hovering ? DS.inkBlack : DS.slate
        case .danger:  return hovering ? Color(hex: "d92d20") : DS.slate
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return hovering ? DS.carbon : DS.inkBlack
        case .ghost:   return hovering ? DS.mist : .clear
        case .quiet:   return hovering ? Color.black.opacity(0.04) : .clear
        case .danger:  return hovering ? Color(hex: "d92d20").opacity(0.08) : .clear
        }
    }

    private var border: Color {
        switch kind {
        case .primary, .quiet, .danger: return .clear
        case .ghost: return DS.bone
        }
    }
}

/// Small square icon-only button used inside dense rows.
struct IconButton: View {
    var icon: String
    var tint: Color = DS.ash
    var hoverTint: Color = DS.inkBlack
    var help: String = ""
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? hoverTint : tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? Color.black.opacity(0.05) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.hover) { hovering = h } }
        .help(help)
    }
}

/// Selectable pill — the nav/tag chip. Ink fill when active, hairline outline when not.
struct Chip: View {
    var title: String
    var accent: Accent? = nil
    var selected: Bool
    var action: () -> Void

    @State private var hovering = false

    private var tint: Color { accent?.color ?? DS.inkBlack }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.text(12, .bold))
                .foregroundStyle(selected ? DS.signalWhite : (hovering ? DS.inkBlack : DS.slate))
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(
                    ZStack {
                        Capsule().fill(selected ? tint : (hovering ? DS.mist : Color.clear))
                        Capsule().strokeBorder(selected ? Color.clear : DS.bone, lineWidth: 1)
                    }
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.hover) { hovering = h } }
    }
}

// MARK: - Surfaces

/// Elevation as negative space: a 1px hairline, no drop shadow.
struct CardBackground: ViewModifier {
    var radius: CGFloat = DS.radiusCard
    var fill: Color = DS.signalWhite

    func body(content: Content) -> some View {
        content.background(
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.bone, lineWidth: 1)
            }
        )
    }
}

extension View {
    func dsCard(radius: CGFloat = DS.radiusCard, fill: Color = DS.signalWhite) -> some View {
        modifier(CardBackground(radius: radius, fill: fill))
    }
}

/// Flat progress track — bone rail, ink fill, fully rounded.
struct DSProgressBar: View {
    var value: Double
    var tint: Color = DS.inkBlack

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.bone)
                Capsule().fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Bundled fonts

enum FontLoader {
    /// Registers any font files shipped in the app bundle's Fonts/ folder.
    static func registerBundledFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
