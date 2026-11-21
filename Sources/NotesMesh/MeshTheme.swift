import SwiftUI
import simd

/// Mesh's palette (wiki-clients Theme.swift): everything comes from one warm sepia OKLCH seed.
/// Ink on paper, flipped for dark mode. People and entities get muted hues at the seed's lightness.
struct MeshTheme {
    var bg, fg, accent, person, entity: SIMD4<Float>

    static func make(dark: Bool) -> MeshTheme {
        let paper = (0.985, 0.008, 85.0), ink = (0.27, 0.024, 85.0)
        let bg = dark ? ink : paper, fg = dark ? paper : ink
        return MeshTheme(
            bg: oklch(bg.0, bg.1, bg.2),
            fg: oklch(fg.0, fg.1, fg.2),
            accent: dark ? oklch(0.68, 0.045, 85) : oklch(0.55, 0.04, 85),
            person: dark ? oklch(0.74, 0.11, 45) : oklch(0.58, 0.13, 42),
            entity: dark ? oklch(0.74, 0.08, 235) : oklch(0.52, 0.09, 240))
    }

    /// Island hues, shared with the pills and drawer cards (`IslandPalette`), so a cluster is
    /// the same colour in the graph, on its pill and on its card. Deeper on paper, brighter on ink.
    static let islandRGB: [SIMD3<Float>] = [
        SIMD3(0.98, 0.55, 0.36), SIMD3(0.36, 0.62, 0.98), SIMD3(0.42, 0.80, 0.56), SIMD3(0.80, 0.52, 0.95),
        SIMD3(0.98, 0.78, 0.30), SIMD3(0.30, 0.78, 0.82), SIMD3(0.96, 0.45, 0.62), SIMD3(0.62, 0.70, 0.40),
    ]
    func island(_ id: Int) -> SIMD4<Float> {
        let rgb = Self.islandRGB[((id % Self.islandRGB.count) + Self.islandRGB.count) % Self.islandRGB.count]
        let dark = bg.x < 0.5
        let c = dark ? rgb : rgb * 0.72
        return SIMD4(c.x, c.y, c.z, 1)
    }

    func color(forType type: String) -> SIMD4<Float> {
        switch type {
        case "person": return person
        case "entity": return entity
        case "topic", "tag": return accent
        default: return fg
        }
    }

    static func oklch(_ L: Double, _ C: Double, _ H: Double) -> SIMD4<Float> {
        let h = H * .pi / 180, a = C * cos(h), b = C * sin(h)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ x: Double) -> Float {
            Float(min(max(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055, 0), 1))
        }
        return SIMD4(gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                     gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                     gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), 1)
    }
}

extension Color {
    init(_ v: SIMD4<Float>) { self.init(.sRGB, red: Double(v.x), green: Double(v.y), blue: Double(v.z), opacity: Double(v.w)) }
}
