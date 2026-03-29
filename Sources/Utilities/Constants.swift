import SwiftUI
import AppKit

extension Notification.Name {
    static let openConnectionDoctor = Notification.Name("openConnectionDoctor")
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

    // MARK: - Adaptive Color Helpers

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }))
    }

    private static func nsColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // Base palette — extracted so opacity variants stay in sync
    private static let basePrimary = nsColor(0.137, 0.067, 0.235)     // #23113c
    private static let basePrimaryDark = nsColor(0.898, 0.898, 0.898)  // #e5e5e5

    private static func primaryLight(_ alpha: CGFloat) -> NSColor {
        nsColor(0.137, 0.067, 0.235, alpha)
    }
    private static func primaryDark(_ alpha: CGFloat) -> NSColor {
        nsColor(0.898, 0.898, 0.898, alpha)
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

    static let textPrimary = adaptive(light: basePrimary, dark: basePrimaryDark)
    static let textMuted = adaptive(light: primaryLight(0.65), dark: primaryDark(0.60))

    static let lightBackground = adaptive(
        light: nsColor(0.980, 0.976, 0.969),
        dark: nsColor(0.118, 0.118, 0.118)
    )
    static let surfaceWhite = adaptive(
        light: .white,
        dark: nsColor(0.176, 0.176, 0.176)
    )
    static let textHint = adaptive(light: primaryLight(0.30), dark: primaryDark(0.30))
    static let border = adaptive(light: primaryLight(0.12), dark: primaryDark(0.12))
    static let borderHover = adaptive(light: primaryLight(0.20), dark: primaryDark(0.20))

    // Overlay shadow (speech bubbles, permission cards)
    static let overlayShadow = adaptive(light: primaryLight(0.22), dark: nsColor(0, 0, 0, 0.25))

    // Code area colors (pre-baked opacity for overlay panels where dynamic opacity may not resolve)
    static let codeText = adaptive(light: primaryLight(0.85), dark: primaryDark(0.85))
    static let codeTextMuted = adaptive(light: primaryLight(0.75), dark: primaryDark(0.75))
    static let codeBg = adaptive(
        light: nsColor(0.980, 0.976, 0.969),
        dark: nsColor(0.145, 0.145, 0.145)
    )

    // Interactive state colors
    static let chip = adaptive(
        light: nsColor(0.906, 0.678, 0.408, 0.18),
        dark: nsColor(0.906, 0.678, 0.408, 0.15)
    )
    static let stage = adaptive(light: primaryLight(0.04), dark: primaryDark(0.06))
    static let orangePrimaryLight = adaptive(
        light: nsColor(0.976, 0.365, 0.008, 0.10),
        dark: nsColor(0.976, 0.365, 0.008, 0.18)
    )
    static let orangePrimarySubtle = adaptive(
        light: nsColor(0.976, 0.365, 0.008, 0.08),
        dark: nsColor(0.976, 0.365, 0.008, 0.14)
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

    static let cardShadowColor = adaptive(light: primaryLight(0.08), dark: nsColor(0, 0, 0, 0.4))
    static let cardShadowRadius: CGFloat = 1.5
    static let cardShadowY: CGFloat = 1

    static let cardHoverShadowColor = adaptive(light: primaryLight(0.12), dark: nsColor(0, 0, 0, 0.55))
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
