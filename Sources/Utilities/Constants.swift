import SwiftUI
import AppKit

extension Notification.Name {
    static let openConnectionDoctor = Notification.Name("openConnectionDoctor")
}

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The NSAppearance corresponding to the user's choice (nil = follow system).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Read the current preference from UserDefaults.
    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "") ?? .system
    }
}

enum Constants {
    private static let serverPortKey = "serverPort"

    // Web links (opened in browser)
    #if DEBUG
    static let maskoBaseURL = "http://localhost:3000"
    #else
    static let maskoBaseURL = "https://masko.ai"
    #endif
    static let githubRepoURL = "https://github.com/RousselPaul/masko-code"

    // Local hook server
    static let legacyDefaultServerPort: UInt16 = 49152
    static let defaultServerPort: UInt16 = 45832
    static var serverPort: UInt16 {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: serverPortKey) != nil else {
            return defaultServerPort
        }

        let stored = defaults.integer(forKey: serverPortKey)
        if stored == Int(legacyDefaultServerPort) {
            defaults.set(Int(defaultServerPort), forKey: serverPortKey)
            return defaultServerPort
        }
        return stored > 0 ? UInt16(stored) : defaultServerPort
    }
    static func setServerPort(_ port: UInt16) {
        UserDefaults.standard.set(Int(port), forKey: serverPortKey)
    }

    // MARK: - Adaptive Color Helper

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }))
    }

    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Brand Colors (fixed across themes)

    static let orangePrimary = Color(red: 249.0/255, green: 93.0/255, blue: 2.0/255)     // #f95d02
    static let orangeHover = Color(red: 251.0/255, green: 121.0/255, blue: 16.0/255)     // #fb7910
    static let orangeShadow = Color(red: 201.0/255, green: 74.0/255, blue: 1.0/255)      // #c94a01
    static let destructiveRed = Color(.sRGB, red: 220.0/255, green: 38.0/255, blue: 38.0/255) // #dc2626

    // MARK: - Adaptive Theme Colors

    //                          Light                      Dark
    // lightBackground:         #faf9f7                    #1e1e1e
    // surfaceWhite:            #ffffff                    #2d2d2d
    // textPrimary:             #23113c                    #e5e5e5
    // textMuted:               #23113c @ 0.65             #e5e5e5 @ 0.60
    // border:                  #23113c @ 0.12             #e5e5e5 @ 0.14
    // borderHover:             #23113c @ 0.20             #e5e5e5 @ 0.24

    static let textPrimary = adaptive(
        light: c(0.137, 0.067, 0.235),
        dark: c(0.898, 0.898, 0.898)
    )
    static let textMuted = adaptive(
        light: c(0.137, 0.067, 0.235, 0.65),
        dark: c(0.898, 0.898, 0.898, 0.60)
    )
    static let lightBackground = adaptive(
        light: c(0.980, 0.976, 0.969),
        dark: c(0.118, 0.118, 0.118)
    )
    static let surfaceWhite = adaptive(
        light: .white,
        dark: c(0.176, 0.176, 0.176)
    )
    static let border = adaptive(
        light: c(0.137, 0.067, 0.235, 0.12),
        dark: c(1, 1, 1, 0.12)
    )
    static let borderHover = adaptive(
        light: c(0.137, 0.067, 0.235, 0.20),
        dark: c(1, 1, 1, 0.20)
    )

    // Overlay shadow (speech bubbles, permission cards — subtle in both modes)
    static let overlayShadow = adaptive(
        light: c(0.137, 0.067, 0.235, 0.22),
        dark: c(0, 0, 0, 0.25)
    )

    // Code area colors (pre-baked opacity for overlay panels where dynamic opacity may not resolve)
    static let codeText = adaptive(
        light: c(0.137, 0.067, 0.235, 0.85),
        dark: c(0.898, 0.898, 0.898, 0.85)
    )
    static let codeTextMuted = adaptive(
        light: c(0.137, 0.067, 0.235, 0.75),
        dark: c(0.898, 0.898, 0.898, 0.75)
    )
    static let codeBg = adaptive(
        light: c(0.980, 0.976, 0.969),
        dark: c(0.145, 0.145, 0.145)
    )

    // Interactive state colors
    static let chip = adaptive(
        light: c(0.906, 0.678, 0.408, 0.18),
        dark: c(0.906, 0.678, 0.408, 0.15)
    )
    static let stage = adaptive(
        light: c(0.137, 0.067, 0.235, 0.04),
        dark: c(1, 1, 1, 0.06)
    )
    static let orangePrimaryLight = adaptive(
        light: c(0.976, 0.365, 0.008, 0.10),
        dark: c(0.976, 0.365, 0.008, 0.18)
    )
    static let orangePrimarySubtle = adaptive(
        light: c(0.976, 0.365, 0.008, 0.08),
        dark: c(0.976, 0.365, 0.008, 0.14)
    )

    // MARK: - Typography

    /// Fredoka — headings, buttons, display text
    static func heading(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Fredoka", size: size).weight(weight)
    }

    /// Rubik — body text, labels, metadata
    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Rubik", size: size).weight(weight)
    }

    // MARK: - Layout

    static let cornerRadius: CGFloat = 14
    static let cornerRadiusSmall: CGFloat = 10

    // MARK: - Shadows

    static let cardShadowColor = adaptive(
        light: c(0.137, 0.067, 0.235, 0.08),
        dark: c(0, 0, 0, 0.4)
    )
    static let cardShadowRadius: CGFloat = 1.5
    static let cardShadowY: CGFloat = 1

    static let cardHoverShadowColor = adaptive(
        light: c(0.137, 0.067, 0.235, 0.12),
        dark: c(0, 0, 0, 0.55)
    )
    static let cardHoverShadowRadius: CGFloat = 6
    static let cardHoverShadowY: CGFloat = 4

    // MARK: - Gradients

    /// Feature card orange tint gradient (matches web)
    static let featureCardGradient = LinearGradient(
        colors: [
            Color(red: 249.0/255, green: 93.0/255, blue: 2.0/255).opacity(0.06),
            Color(red: 252.0/255, green: 155.0/255, blue: 43.0/255).opacity(0.06)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
