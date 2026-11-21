import AppKit

/// Debug only (`--click-channel <file>`): reads "x y" lines (points from the window's top-left)
/// and sends a real mouse down/up through the window, so hit testing (title bar included)
/// is exactly what a user's click gets. Lines starting with "drag" do a drag: "drag x0 y0 x1 y1".
enum DebugClicks {
#if NOTEMESH_DEBUG
    static var logFile: String?
    static func log(_ s: String) {
        guard let f = logFile, let d = (s + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: f) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { FileManager.default.createFile(atPath: f, contents: d) }
    }
    static func start(file: String) {
        logFile = file + ".log"
        log("started")
        var seen = 0
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n")
            guard lines.count > seen else { return }
            for line in lines[seen...] { run(String(line)) }
            seen = lines.count
        }
    }

    private static func run(_ line: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.height > 300 }) else { log("no window"); return }
        let n = line.split(separator: " ").compactMap { Double($0) }
        func pt(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: x, y: w.frame.height - y) }
        func send(_ type: NSEvent.EventType, _ p: NSPoint) {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                w.sendEvent(e)
            }
        }
        let before = w.frame.origin
        if n.count >= 2, let frame = w.contentView?.superview {
            let p = pt(n[0], n[1])
            var chain: [String] = []
            var v = frame.hitTest(frame.convert(p, from: nil))
            while let x = v, chain.count < 6 { chain.append(String(describing: type(of: x))); v = x.superview }
            log("hit: " + chain.joined(separator: " < "))
        }
        if line.hasPrefix("drag"), n.count == 4 {
            send(.leftMouseDown, pt(n[0], n[1]))
            for i in 1...8 { let t = Double(i) / 8; send(.leftMouseDragged, pt(n[0] + (n[2] - n[0]) * t, n[1] + (n[3] - n[1]) * t)) }
            send(.leftMouseUp, pt(n[2], n[3]))
        } else if n.count == 2 {
            send(.leftMouseDown, pt(n[0], n[1]))
            send(.leftMouseUp, pt(n[0], n[1]))
        }
        log("click \(line) moved: \(w.frame.origin != before) key: \(w.isKeyWindow) active: \(NSApp.isActive)")
    }
#else
    // Release builds: no test hooks at all.
    static func log(_ s: String) {}
    static func start(file: String) {}
#endif
}
