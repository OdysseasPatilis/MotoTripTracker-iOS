import SwiftUI

enum ThemeMode: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    var colorScheme: ColorScheme {
        switch self {
        case .dark: .dark
        case .light: .light
        }
    }

    var toggleSymbol: String {
        switch self {
        case .dark: "sun.max.fill"
        case .light: "moon.fill"
        }
    }

    var toggleLabel: String {
        switch self {
        case .dark: "Light"
        case .light: "Dark"
        }
    }
}

struct AppPalette {
    let bgDeep: Color
    let bgCard: Color
    let bgPanel: Color
    let bgBar: Color
    let bgSurface: Color
    let textPrimary: Color
    let textMuted: Color
    let textSecondary: Color
    let emptyText: Color
    let divider: Color
    let borderSubtle: Color
    let neonGreen: Color
    let neonBlue: Color
    let neonRed: Color
    let stopRed: Color
    let arcTrack: Color
    let gForceTick: Color
    let routeAmber: Color
    let routeTeal: Color
    let routeCoral: Color
    let purpleAccent: Color
    let purpleAccentEnd: Color
    let mint: Color
    let deleteButtonBg: Color
    let layerActive: Color
    let mapCardBg: Color
    let batteryOutline: Color
    let batteryLabel: Color
    let startButtonDisabledBg: Color
    let startButtonDisabledText: Color
    let pauseBorder: Color
    let heroLabel: Color

    var startGradient: LinearGradient {
        LinearGradient(colors: [neonGreen, neonBlue], startPoint: .leading, endPoint: .trailing)
    }

    var heroGradient: LinearGradient {
        LinearGradient(colors: [purpleAccent, purpleAccentEnd], startPoint: .leading, endPoint: .trailing)
    }

    /// Softened dark surfaces closer to system grouped backgrounds, with brand accents.
    static let dark = AppPalette(
        bgDeep: Color(hex: 0x101014),
        bgCard: Color(hex: 0x1C1C22),
        bgPanel: Color(hex: 0x22222A),
        bgBar: Color(hex: 0x16161C),
        bgSurface: Color(hex: 0x4050E5),
        textPrimary: .white,
        textMuted: Color(hex: 0x8E8E9A),
        textSecondary: Color.white.opacity(0.55),
        emptyText: Color(hex: 0x5C5C6A),
        divider: Color(hex: 0x2A2A34),
        borderSubtle: Color.white.opacity(0.08),
        neonGreen: Color(hex: 0x00E5A0),
        neonBlue: Color(hex: 0x00B4FF),
        neonRed: Color(hex: 0xFF4A6A),
        stopRed: Color(hex: 0xE24B4A),
        arcTrack: Color(hex: 0x2E2E3A),
        gForceTick: Color(hex: 0x4A4A5A),
        routeAmber: Color(hex: 0xEF9F27),
        routeTeal: Color(hex: 0x1D9E75),
        routeCoral: Color(hex: 0xD85A30),
        purpleAccent: Color(hex: 0x5B5FEF),
        purpleAccentEnd: Color(hex: 0x7C4DFF),
        mint: Color(hex: 0x5EFFC8),
        deleteButtonBg: Color(hex: 0x3A1A1A),
        layerActive: Color(hex: 0x5B5FEF),
        mapCardBg: Color(hex: 0x1C1C22),
        batteryOutline: Color.white.opacity(0.4),
        batteryLabel: Color.white.opacity(0.55),
        startButtonDisabledBg: Color.gray.opacity(0.28),
        startButtonDisabledText: .gray,
        pauseBorder: Color.white.opacity(0.12),
        heroLabel: Color.white.opacity(0.6)
    )

    /// Light theme: cool slate surfaces with the same brand accents.
    static let light = AppPalette(
        bgDeep: Color(hex: 0xF2F2F7),
        bgCard: Color(hex: 0xFFFFFF),
        bgPanel: Color(hex: 0xEBEBF0),
        bgBar: Color(hex: 0xF7F7FA),
        bgSurface: Color(hex: 0x4050E5),
        textPrimary: Color(hex: 0x1C1C1E),
        textMuted: Color(hex: 0x6C6C70),
        textSecondary: Color(hex: 0x1C1C1E).opacity(0.5),
        emptyText: Color(hex: 0xAEAEB2),
        divider: Color(hex: 0xE5E5EA),
        borderSubtle: Color(hex: 0x1C1C1E).opacity(0.06),
        neonGreen: Color(hex: 0x00B87A),
        neonBlue: Color(hex: 0x0090D0),
        neonRed: Color(hex: 0xE03555),
        stopRed: Color(hex: 0xD63A3A),
        arcTrack: Color(hex: 0xD1D1D6),
        gForceTick: Color(hex: 0xAEAEB2),
        routeAmber: Color(hex: 0xD98900),
        routeTeal: Color(hex: 0x178A66),
        routeCoral: Color(hex: 0xC24E28),
        purpleAccent: Color(hex: 0x5B5FEF),
        purpleAccentEnd: Color(hex: 0x7C4DFF),
        mint: Color(hex: 0x00C9A0),
        deleteButtonBg: Color(hex: 0xFFE5E5),
        layerActive: Color(hex: 0x5B5FEF),
        mapCardBg: Color(hex: 0xFFFFFF),
        batteryOutline: Color(hex: 0x1C1C1E).opacity(0.35),
        batteryLabel: Color(hex: 0x1C1C1E).opacity(0.5),
        startButtonDisabledBg: Color(hex: 0xD1D1D6),
        startButtonDisabledText: Color(hex: 0x8E8E93),
        pauseBorder: Color(hex: 0x1C1C1E).opacity(0.1),
        heroLabel: Color.white.opacity(0.67)
    )
}

@Observable
@MainActor
final class ThemeStore {
    private static let storageKey = "moto.theme.mode"

    var mode: ThemeMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
        }
    }

    var palette: AppPalette {
        mode == .dark ? .dark : .light
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let stored = ThemeMode(rawValue: raw) {
            mode = stored
        } else {
            mode = .dark
        }
    }

    func toggle() {
        mode = mode == .dark ? .light : .dark
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
