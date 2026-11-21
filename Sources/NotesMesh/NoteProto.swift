import Foundation

/// Decodes the body of an Apple Note: ZICNOTEDATA.ZDATA is a gzipped protobuf
/// (NoteStoreProto → Document(2) → Note(3) → text(2) + attribute runs(5)).
/// Only the fields Notes Mesh needs are read: the plain text, link URLs and inline attachments.
struct ParsedNoteBody {
    var text = ""
    var links: [String] = []
    var attachments: [(id: String, uti: String)] = []
}

enum NoteProto {
    static func parse(_ data: Data) -> ParsedNoteBody? {
        let raw = Gzip.decompress(data) ?? data
        let b = [UInt8](raw)
        guard let doc = firstBytes(b, 0..<b.count, field: 2),
              let note = firstBytes(b, doc, field: 3) else { return nil }
        var out = ParsedNoteBody()
        for (f, v) in fields(b, note) {
            guard case .bytes(let r) = v else { continue }
            if f == 2 {
                out.text = String(decoding: b[r], as: UTF8.self).replacingOccurrences(of: "\u{FFFC}", with: "")
            } else if f == 5 {
                for (af, av) in fields(b, r) {
                    guard case .bytes(let ar) = av else { continue }
                    if af == 9 {
                        out.links.append(String(decoding: b[ar], as: UTF8.self))
                    } else if af == 12 {
                        var id = "", uti = ""
                        for (xf, xv) in fields(b, ar) {
                            guard case .bytes(let xr) = xv else { continue }
                            if xf == 1 { id = String(decoding: b[xr], as: UTF8.self) }
                            if xf == 2 { uti = String(decoding: b[xr], as: UTF8.self) }
                        }
                        if !id.isEmpty { out.attachments.append((id, uti)) }
                    }
                }
            }
        }
        return out
    }

    enum Value { case varint(UInt64), bytes(Range<Int>), other }

    static func fields(_ b: [UInt8], _ r: Range<Int>) -> [(Int, Value)] {
        var out: [(Int, Value)] = []
        var i = r.lowerBound
        let end = min(r.upperBound, b.count)
        while i < end {
            guard let key = varint(b, &i, end) else { break }
            let field = Int(truncatingIfNeeded: key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint(b, &i, end) else { return out }
                out.append((field, .varint(v)))
            case 1:
                i += 8; out.append((field, .other))
            case 2:
                guard let len = varint(b, &i, end), len <= UInt64(end - i) else { return out }
                let n = Int(len)
                out.append((field, .bytes(i..<(i + n))))
                i += n
            case 5:
                i += 4; out.append((field, .other))
            default:
                return out
            }
        }
        return out
    }

    private static func firstBytes(_ b: [UInt8], _ r: Range<Int>, field: Int) -> Range<Int>? {
        for (f, v) in fields(b, r) where f == field {
            if case .bytes(let range) = v { return range }
        }
        return nil
    }

    private static func varint(_ b: [UInt8], _ i: inout Int, _ end: Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < end, shift < 64 {
            let byte = b[i]; i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}

enum Gzip {
    /// Strips the gzip header/trailer and inflates the raw DEFLATE stream.
    static func decompress(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let deflate = Data(b[i..<(b.count - 8)])
        return try? (deflate as NSData).decompressed(using: .zlib) as Data
    }
}
