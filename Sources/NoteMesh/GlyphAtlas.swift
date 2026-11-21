import AppKit
import CoreText
import Metal

/// Labels are rasterised once, with Core Text, into one alpha texture. The renderer then draws
/// them as GPU quads, so zooming and panning never touch text again. JetBrains Mono is
/// monospaced, so truncating a label ("Weekly planning n…") is just a narrower quad.
final class GlyphAtlas {
    struct Entry { let x: Int, y: Int, width: Int, height: Int, length: Int }

    static let pointSize: CGFloat = 11
    static let boxHeight: CGFloat = 17      // label box height in points

    let device: MTLDevice
    private(set) var texture: MTLTexture!
    private(set) var width = 4096, height = 1024
    private(set) var scale: CGFloat = 2
    private(set) var advance: CGFloat = 6.6  // points per character
    private(set) var generation = 0           // bumps whenever slots move (reset / grow)
    private var context: CGContext!
    private var cursorX = 0, cursorY = 0, rowHeight = 0
    private var entries: [String: Entry] = [:]
    private var fonts: [Int: CTFont] = [:]

    init(device: MTLDevice, scale: CGFloat) {
        self.device = device
        Self.registerFonts()
        reset(height: 1024, scale: scale)
    }

    /// JetBrains Mono ships in the app bundle (Resources/Fonts), as in Mesh.
    static func registerFonts() {
        struct Once { static var done = false }
        guard !Once.done else { return }
        Once.done = true
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().appendingPathComponent("Web/fonts")].compactMap { $0 }
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
            return
        }
    }

    private func font(weight: Int) -> CTFont {
        if let f = fonts[weight] { return f }
        let name = weight >= 500 ? "JetBrainsMono-Medium" : "JetBrainsMono-Regular"
        var f = CTFontCreateWithName(name as CFString, Self.pointSize * scale, nil)
        if (CTFontCopyPostScriptName(f) as String) != name {
            f = NSFont.monospacedSystemFont(ofSize: Self.pointSize * scale, weight: weight >= 500 ? .medium : .regular) as CTFont
        }
        fonts[weight] = f
        return f
    }

    func reset(height: Int, scale: CGFloat) {
        self.scale = max(2, scale)
        self.height = height
        generation += 1
        fonts.removeAll()
        entries.removeAll()
        cursorX = 0; cursorY = 0; rowHeight = 0
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        context.setFillColor(gray: 1, alpha: 1)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        texture = device.makeTexture(descriptor: desc)
        let f = font(weight: 400)
        var glyph = CGGlyph(), ch: UniChar = 0x4D   // "M"
        CTFontGetGlyphsForCharacters(f, &ch, &glyph, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(f, .horizontal, &glyph, &adv, 1)
        advance = adv.width / self.scale
    }

    /// The atlas slot for a label, drawing it the first time it's asked for.
    func entry(_ text: String, weight: Int) -> Entry {
        let key = "\(weight)|\(text)"
        if let e = entries[key] { return e }
        let w = Int(ceil(CGFloat(text.count) * advance * scale)) + 4
        let h = Int(ceil(Self.boxHeight * scale))
        if cursorX + w > width { cursorX = 0; cursorY += rowHeight + 2; rowHeight = 0 }
        if cursorY + h > height {
            // Out of room: double the height and redraw what we had (rare; only on new data).
            let keys = Array(entries.keys)
            reset(height: min(height * 2, 16384), scale: scale)
            for k in keys {
                let parts = k.split(separator: "|", maxSplits: 1)
                _ = entry(String(parts[1]), weight: Int(parts[0]) ?? 400)
            }
            return entry(text, weight: weight)
        }
        let x = cursorX + 2, y = cursorY
        let f = font(weight: weight)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let line = CTLineCreateWithAttributedString(attr)
        let ascent = CTFontGetAscent(f), descent = CTFontGetDescent(f)
        // Bitmap rows run top-down in memory; Core Graphics draws bottom-up.
        let baselineFromTop = (CGFloat(h) - (ascent + descent)) / 2 + ascent
        context.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(height) - CGFloat(y) - baselineFromTop)
        CTLineDraw(line, context)
        if let data = context.data {
            texture.replace(region: MTLRegionMake2D(x, y, min(w, width - x), h), mipmapLevel: 0,
                            withBytes: data.advanced(by: y * width + x), bytesPerRow: width)
        }
        let e = Entry(x: x, y: y, width: w, height: h, length: text.count)
        entries[key] = e
        cursorX += w + 2
        rowHeight = max(rowHeight, h)
        return e
    }
}
