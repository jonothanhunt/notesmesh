import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var indexer: Indexer
    @StateObject private var graph = GraphController()
    @State private var selection: String?
    @State private var search = ""
    @State private var detent: PanelDetent = .medium
    @State private var openControl: ControlPanel?
    @State private var entered = false
    @AppStorage("layer.link") private var showLinks = true
    @AppStorage("layer.notelink") private var showNoteLinks = true
    @AppStorage("layer.tag.v2") private var showTags = false
    @AppStorage("layer.topic") private var showTopics = true
    @AppStorage("layer.similar") private var showSimilar = true
    @AppStorage("similarPerNote") private var similarPerNote = 2
    @AppStorage("cluster.islands") private var islands = true
    @AppStorage("cluster.folders") private var byFolder = false

    var body: some View {
        Group {
            if case .failed(let message) = indexer.state { LoadFailedView(message: message) } else { main }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { if indexer.state == .idle { indexer.start() } }
    }

    // Laid out like Apple Maps: the graph is the map and fills the window, under a transparent
    // toolbar whose only item (Apple Intelligence) the system centres on the traffic lights; a
    // glass drawer rises from the bottom-left with search and whatever you've selected; map
    // controls stack top-right under the toolbar button, zoom bottom-right.
    private var main: some View {
        ZStack(alignment: .topLeading) {
            GraphCanvas(controller: graph)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) { IslandPills(graph: graph) { focus("island:\($0)") } }
                .overlay(alignment: .topLeading) { hoverCard }

            // The drawer rises from the bottom-left edge, like Maps.
            GeometryReader { geo in
                SidePanel(graph: graph, selection: $selection, search: $search, detent: $detent,
                          available: geo.size.height - Self.toolbarHeight - 8 - Self.edge, focus: focus)
                    .environmentObject(graph)
                    .padding(.leading, Self.edge)
                    // Floats just above the bottom edge, like the drawers in Maps and Find My.
                    .padding(.bottom, Self.edge)
                    .entrance(entered, delay: 0, anchor: .bottomLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            // Mirrors the close button: its centre is ~26pt from the top-left corner on both axes,
            // so the first circle is centred 26pt from the top-right — equal top and side margins,
            // on the traffic lights' line.
            // Clicking anywhere else closes an open control panel (it morphs back into its circle).

            TopControls(indexer: indexer, graph: graph, open: $openControl)
                .padding(.trailing, Self.edge).padding(.top, Self.edge)
                .entrance(entered, delay: 0.08, anchor: .topTrailing)
                .frame(maxWidth: .infinity, alignment: .topTrailing)

            ZoomControls(zoomIn: { graph.zoom(by: 1.6) }, zoomOut: { graph.zoom(by: 1 / 1.6) }, fit: { graph.fit() })
                .padding(.trailing, Self.edge).padding(.bottom, Self.edge)
                .entrance(entered, delay: 0.16, anchor: .bottomTrailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            if indexer.state == .loading {
                ProgressView(indexer.isDemo ? "Opening sample notes…" : "Reading your notes…").padding(20).glassEffect(in: .rect(cornerRadius: 20))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .toolbar {
            // An empty, invisible item keeps the 52pt unified toolbar row, which is what centres
            // the traffic lights on the same line as our controls. The controls themselves are
            // our own glass circles, so they all match.
            ToolbarItem(placement: .automatic) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                .sharedBackgroundVisibility(.hidden)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .modifier(FallbackNotice(indexer: indexer))
        .confirmationDialog("Delete everything NoteMesh has stored?", isPresented: $indexer.confirmDeleteData) {
            Button("Delete NoteMesh Data", role: .destructive) { indexer.deleteAllData() }
        } message: {
            Text("This removes NoteMesh's topics, profiles, similarity index and settings from this Mac. Your notes stay as they are, and NoteMesh rebuilds what it needs next time.")
        }
        .confirmationDialog("Rebuild the index?", isPresented: $indexer.confirmReindex) {
            Button("Rebuild Index") { indexer.reindex() }
        } message: {
            Text("NoteMesh forgets its topics and profiles and reads every note again. Keyword topics show until Apple Intelligence catches up.")
        }
        .sheet(isPresented: $indexer.showPalette) {
            CommandPalette(onOpen: { indexer.open($0) }, onFocus: focus)
                .environmentObject(indexer)
        }
        .onAppear {
            graph.onSelect = { id in selection = id }
            entered = true
            graph.onOpen = { id in indexer.open(id) }
            graph.onPillClick = { focus("island:\($0)") }
            // Pressing the graph (to pan, select or zoom) closes an open control panel; the graph
            // keeps the gesture, so you can drag straight away.
            graph.onPress = { if openControl != nil { withAnimation(TopControls.morph) { openControl = nil } } }
            graph.setClustering(islands: islands, folders: byFolder)
            pushLayers()
            pushInsets()
            graph.setSimilar(similarPerNote)
            if let p = indexer.payload { graph.setData(p) }
        }
        .onChange(of: indexer.payloadVersion) { if let p = indexer.payload { graph.setData(p) } }
        .onChange(of: search) { graph.setQuery(search) }
        .onChange(of: [showNoteLinks, showLinks, showTags, showTopics, showSimilar]) { pushLayers() }
        .onChange(of: similarPerNote) { graph.setSimilar(similarPerNote) }
        .onChange(of: [islands, byFolder]) { graph.setClustering(islands: islands, folders: byFolder) }
        .onChange(of: selection) {
            // A note folded into a same-titled profile opens as that profile.
            if let s = selection, let canon = indexer.alias[s] { selection = canon; return }
            graph.focus(selection)
        }
        .onChange(of: openControl) { DebugClicks.log("NMState open=\(String(describing: openControl))") }
        .onChange(of: [showLinks, showTags, showTopics, showSimilar, islands, byFolder]) { DebugClicks.log("NMState toggles=\([showLinks, showTags, showTopics, showSimilar, islands, byFolder])") }
        .onChange(of: detent) { pushInsets() }
        .onChange(of: indexer.benchRequested) {
            guard indexer.benchRequested else { return }
            // Worst case: every layer on. Let the layout settle, sweep, then restore your layers.
            graph.setLayers(["notelink": true, "link": true, "tag": true, "topic": true, "similar": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                graph.view.runBenchmark { result in
                    pushLayers()
                    let url = IndexCache.url(demo: false).deletingLastPathComponent().appendingPathComponent("bench.txt")
                    try? result.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// Unified toolbar height on macOS 26; the traffic lights and toolbar items centre in it.
    static let toolbarHeight: CGFloat = 52
    /// Margin from the window edges for floating controls and the drawer.
    static let edge: CGFloat = Self.toolbarHeight / 2 - TopControls.size / 2

    /// Native glass card for whatever the cursor is over in the graph.
    @ViewBuilder private var hoverCard: some View {
        if let h = graph.hover {
            GeometryReader { geo in
                let width: CGFloat = 300
                HoverCard(hover: h)
                    .frame(width: width, alignment: .leading)
                    .offset(x: min(max(8, h.point.x - width / 2), geo.size.width - width - 8),
                            y: h.point.y + 22)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func pushLayers() {
        graph.setLayers(["notelink": showNoteLinks, "link": showLinks, "tag": showTags, "topic": showTopics, "similar": showSimilar])
    }

    /// Keep fitted / focused nodes clear of the card and the controls.
    private func pushInsets() {
        graph.setInsets(top: Self.toolbarHeight, left: detent == .collapsed ? 0 : SidePanel.width + 20,
                        bottom: detent == .collapsed ? 80 : 0, right: 70)
    }

    private func focus(_ id: String?) {
        selection = id
        graph.focus(id)
    }
}

// MARK: - Map controls

/// Which top-right control is open (it morphs from its circle into a panel).
enum ControlPanel: Hashable { case ai, connect, highlight }

/// Top right, like Maps' map controls: one fixed glass column (three buttons in a capsule,
/// the similar-links slider under it) that never moves. A button's panel buds out of the
/// column to its left, level with the button; switching panels morphs that one piece of
/// glass across, and closing melts it back into the column.
struct TopControls: View {
    @ObservedObject var indexer: Indexer
    @ObservedObject var graph: GraphController
    @Binding var open: ControlPanel?
    @Namespace private var glass
    @State private var rebuild = 0
    @AppStorage("layer.notelink") private var showNoteLinks = true
    @AppStorage("layer.link") private var showLinks = true
    @AppStorage("layer.tag.v2") private var showTags = false
    @AppStorage("layer.topic") private var showTopics = true
    @AppStorage("layer.similar") private var showSimilar = true
    @AppStorage("similarPerNote") private var similarPerNote = 2
    @AppStorage("cluster.islands") private var islands = true
    @AppStorage("cluster.folders") private var byFolder = false
    static let size: CGFloat = 34
    static let morph = Animation.bouncy(duration: 0.45, extraBounce: 0.06)
    private static let order: [ControlPanel] = [.ai, .connect, .highlight]

    var body: some View {
        // Merge distance just under the 10pt gap: at rest the panel and column are separate
        // shapes; while the panel grows or shrinks they flow into each other.
        let container = GlassEffectContainer(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if let open {
                    panel(open)
                        .padding(.top, CGFloat(Self.order.firstIndex(of: open) ?? 0) * Self.size)
                }
                VStack(spacing: 10) {
                    buttonColumn
                    similarSlider
                    ThemeButton()
                        .glassEffect(.regular, in: .circle)
                        .glassEffectID("theme", in: glass)
                }
            }
        }
        return container
            // Workaround: after a tall panel morphs away, SwiftUI can leave the container's hit
            // testing stale. Once the morph has settled, rebuild the identical-looking container.
            .id(rebuild)
            .onChange(of: open) { _, now in
                guard now == nil else { return }
                let token = rebuild
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if open == nil && rebuild == token { rebuild &+= 1 } }
            }
    }

    // MARK: The column

    private var buttonColumn: some View {
        VStack(spacing: 0) {
            button(.ai, symbol: indexer.aiPhase == .paused ? "pause.circle" : "apple.intelligence",
                   help: indexer.aiStatus.isEmpty ? "Apple Intelligence" : indexer.aiStatus,
                   pulsing: indexer.aiPhase == .reading)
            button(.connect, symbol: "point.3.connected.trianglepath.dotted", help: "Connect and arrange notes")
            button(.highlight, symbol: graph.typeFilter.map(NoteTypes.symbol) ?? "line.3.horizontal.decrease",
                   help: "Highlight people, organisations, notes or topics",
                   dot: graph.typeFilter.map { Color(MeshTheme.make(dark: false).color(forType: $0)) })
        }
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("column", in: glass)
        .hoverLift(1.03)
        .background(NoWindowDrag())
    }

    private func button(_ id: ControlPanel, symbol: String, help: String, pulsing: Bool = false, dot: Color? = nil) -> some View {
        let selected = open == id
        return Button { withAnimation(Self.morph) { open = selected ? nil : id } } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, isActive: pulsing)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(selected ? Color.accentColor.opacity(0.16) : .clear).padding(3))
                .overlay(alignment: .topTrailing) {
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7).padding(6) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .help(help)
        .accessibilityLabel(title(id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // Similar links per note: more at the top, fewer at the bottom. Always there.
    private var similarSlider: some View {
        VStack(spacing: 4) {
            Image(systemName: "link").font(.system(size: 12, weight: .medium))
            VerticalStepSlider(value: $similarPerNote, range: 1...5)
                .frame(width: 24, height: 96)
            Text("\(similarPerNote)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(similarPerNote)))
                .animation(.snappy, value: similarPerNote)
        }
        .symbolRenderingMode(.hierarchical)
        .padding(.vertical, 10)
        .frame(width: Self.size)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("slider", in: glass)
        .help("Similar notes linked to each note: \(similarPerNote)")
    }

    // MARK: The panel

    private func panel(_ id: ControlPanel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(id)).font(.headline)
                    Text(subtitle(id)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(GlassPressStyle()).help("Close").keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.top, 14)
            Group {
                switch id {
                case .ai: AIStatusPanel().environmentObject(indexer).environmentObject(graph)
                case .connect: connectPanel.padding(.horizontal, 12).padding(.bottom, 12)
                case .highlight: highlightPanel.padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
            .id(id)
            // In once the glass has budded out; out at once, so nothing lingers.
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)), removal: .identity))
        }
        .frame(width: 300, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .glassEffectID("panel", in: glass)
        .background(NoWindowDrag())
    }

    private func close() { withAnimation(Self.morph) { open = nil } }

    private func title(_ id: ControlPanel) -> String {
        switch id { case .ai: return "Apple Intelligence"; case .connect: return "Connections"; case .highlight: return "Highlight" }
    }

    private func subtitle(_ id: ControlPanel) -> String {
        switch id {
        case .ai:
            switch indexer.aiPhase {
            case .off: return "Using keywords"
            case .unavailable: return "Not available · using keywords"
            case .done: return "Up to date"
            case .paused: return "Paused"
            case .waiting: return "Waiting for the model"
            case .reading: return "Reading on this Mac"
            }
        case .connect: return "What links notes, and how they're laid out"
        case .highlight: return "Bring one kind of note forward"
        }
    }

    // MARK: Connections: Control Center–style tiles (fills on glass, never more glass)

    private var connectPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Link notes by")
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                // The links you made yourself in Notes (type >> in a note to link another), like
                // Obsidian's [[links]]: the most deliberate connection, so it leads.
                GridRow {
                    tile("Note links", "link", $showNoteLinks, help: "Links you made between notes in Apple Notes (type >> in a note)")
                        .gridCellColumns(2)
                }
                GridRow {
                    tile("Topics", "number", $showTopics, help: "Notes that share topics")
                    tile("Similar", "text.magnifyingglass", $showSimilar, help: "Notes with similar content")
                }
                GridRow {
                    tile("Mentions", "person.2", $showLinks, help: "Notes that mention a person or organisation link to their profile")
                    tile("Tags", "tag", $showTags, help: "Notes that share your #tags")
                }
            }
            section("Arrange")
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    tile("Islands", "circle.hexagongrid", $islands, help: "Pull related notes into separate islands")
                    tile("Folders", "folder", $byFolder, help: "Keep each Notes folder in its own region")
                }
            }
        }
    }

    private func section(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
    }

    /// A Control Center tile: the icon sits in a circle that fills with the accent when on.
    private func tile(_ title: String, _ symbol: String, _ on: Binding<Bool>, help: String) -> some View {
        let isOn = on.wrappedValue
        return Button { withAnimation(.snappy(duration: 0.25)) { on.wrappedValue.toggle() } } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolVariant(isOn ? .fill : .none)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isOn)
                    .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.1))))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.callout.weight(.medium))
                    Text(isOn ? "On" : "Off").font(.caption2).foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.primary.opacity(isOn ? 0.09 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .hoverRaise()
        .help(help)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: Highlight: one tile per kind of note, with its colour and count

    private var highlightPanel: some View {
        let kinds = NoteTypes.order.filter { graph.typeCounts[$0] != nil }
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                kindTile(nil, title: "Everything", count: nil).gridCellColumns(2)
            }
            ForEach(Array(stride(from: 0, to: kinds.count, by: 2)), id: \.self) { i in
                GridRow {
                    kindTile(kinds[i], title: NoteTypes.name(kinds[i]), count: graph.typeCounts[kinds[i]])
                    if i + 1 < kinds.count {
                        kindTile(kinds[i + 1], title: NoteTypes.name(kinds[i + 1]), count: graph.typeCounts[kinds[i + 1]])
                    } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
    }

    private func kindTile(_ kind: String?, title: String, count: Int?) -> some View {
        let selected = graph.typeFilter == kind
        let colour = kind.map { Color(MeshTheme.make(dark: false).color(forType: $0)) } ?? .accentColor
        return Button { withAnimation(.snappy(duration: 0.25)) { graph.setTypeFilter(selected && kind != nil ? nil : kind) } } label: {
            HStack(spacing: 9) {
                Image(systemName: kind.map(NoteTypes.symbol) ?? "circle.grid.3x3")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.bounce, value: selected)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(colour))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(selected ? AnyShapeStyle(colour) : AnyShapeStyle(colour.opacity(0.16))))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.callout.weight(.medium))
                    if let count { Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.primary.opacity(selected ? 0.1 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(colour.opacity(selected ? 0.5 : 0), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .hoverRaise()
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A true vertical slider (a rotated Slider still tracks the pointer sideways): the knob
/// follows the pointer up and down, snaps to whole steps, and clicking the track jumps there.
struct VerticalStepSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, knob: CGFloat = 16
            let travel = h - knob
            let steps = CGFloat(range.upperBound - range.lowerBound)
            let fraction = CGFloat(value - range.lowerBound) / steps
            let y = knob / 2 + (1 - fraction) * travel
            ZStack(alignment: .top) {
                Capsule().fill(.primary.opacity(0.14)).frame(width: 4)
                    .frame(maxHeight: .infinity)
                Capsule().fill(Color.accentColor).frame(width: 4, height: h - y)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                ForEach(range, id: \.self) { step in
                    Circle().fill(.primary.opacity(0.25)).frame(width: 3, height: 3)
                        .offset(x: 7, y: knob / 2 + (1 - CGFloat(step - range.lowerBound) / steps) * travel - 1.5)
                }
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(y: y - knob / 2)
                    .animation(.snappy(duration: 0.15), value: value)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = 1 - min(max((g.location.y - knob / 2) / travel, 0), 1)
                let v = range.lowerBound + Int((f * steps).rounded())
                if v != value { value = v }
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Similar links per note")
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }
}

/// Bottom right, like Maps: zoom in / out in one capsule, fit below it.
struct ZoomControls: View {
    let zoomIn: () -> Void, zoomOut: () -> Void, fit: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    button("plus", "Zoom in", zoomIn)
                    Divider().frame(width: 20)
                    button("minus", "Zoom out", zoomOut)
                }
                .glassEffect(.regular, in: .capsule)
                .hoverLift(1.04)
                button("arrow.up.left.and.down.right.magnifyingglass", "Fit the whole graph", fit)
                    .glassEffect(.regular, in: .circle)
                    .hoverLift()
            }
        }
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: TopControls.size, height: TopControls.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressStyle())
        .help(help)
    }
}

// MARK: - Apple Intelligence panel

struct AIStatusPanel: View {
    @EnvironmentObject var indexer: Indexer
    @EnvironmentObject var graph: GraphController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sourcePicker
            if indexer.aiTotal > 0 && indexer.aiPhase != .unavailable && indexer.aiPhase != .off { progressCard }
            if indexer.aiBlocker == nil {
                Text(explanation)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statsGrid
            footer
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 16)
        .animation(.smooth, value: indexer.aiRead)
        .animation(.smooth, value: indexer.aiPhase)
    }

    // MARK: Where topics come from

    /// Apple Intelligence or keywords, switchable at any time; the graph redraws straight away.
    /// Apple Intelligence or keywords. Apple Intelligence is greyed out on Macs that can't run
    /// it, and while it's selected but not ready a banner says keywords are in use for now.
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Find topics and people with").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                segment("Apple Intelligence", "apple.intelligence", selected: indexer.useAI && !indexer.aiUnusable,
                        enabled: !indexer.aiUnusable) { indexer.setUseAI(true) }
                    .help(indexer.aiUnusable ? (indexer.aiBlockerReason?.short ?? "Not available on this Mac") : "Use Apple Intelligence, on this Mac")
                segment("Keywords", "text.word.spacing", selected: !indexer.useAI || indexer.aiUnusable, enabled: true) {
                    indexer.setUseAI(false)
                }
            }
            .padding(2)
            .background(Capsule().fill(.primary.opacity(0.07)))
            if let reason = indexer.aiBlocker {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: reason == .downloading ? "arrow.down.circle" : "text.word.spacing")
                        .foregroundStyle(.orange)
                    Text("Using keywords for now. \(reason.short).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
                .transition(.opacity)
            }
        }
        .animation(.smooth, value: indexer.aiBlocker)
    }

    private func segment(_ title: String, _ symbol: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(Capsule().fill(selected ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.clear)))
                .contentShape(Capsule())
        }
        .buttonStyle(SoftPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Progress: the count, a bar, and pause/resume beside it

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text("\(indexer.aiRead)").font(.title2.weight(.semibold)))\(Text(" of \(indexer.aiTotal)").font(.callout).foregroundStyle(.secondary))")
                        .monospacedDigit()
                    Label(phaseLine, systemImage: phaseSymbol)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                control
            }
            // A drawn bar (not the AppKit-backed ProgressView), so the panel is pure SwiftUI.
            GeometryReader { geo in
                let f = CGFloat(indexer.aiRead) / CGFloat(max(indexer.aiTotal, 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule().fill(indexer.aiPhase == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                        .frame(width: max(6, geo.size.width * f))
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(indexer.aiRead) of \(indexer.aiTotal) notes read")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.05)))
    }

    @ViewBuilder private var control: some View {
        switch indexer.aiPhase {
        case .reading, .waiting:
            roundButton("pause.fill", prominent: false,
                        help: indexer.aiPhase == .waiting ? "Don't start reading when the model is ready" : "Pause to free up your Mac") {
                indexer.pauseTagging()
            }
        case .paused:
            roundButton("play.fill", prominent: true, help: "Resume reading") { indexer.resumeTagging() }
        default:
            EmptyView()
        }
    }

    private func roundButton(_ symbol: String, prominent: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 34, height: 34)
                .background(Circle().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.08))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(prominent ? "Resume" : "Pause")
    }

    // MARK: What's in the graph

    /// "654 notes · 0 links · …" as (value, label) pairs, skipping empty ones.
    private var stats: [(String, String)] {
        let base: [(String, String)] = indexer.stats.components(separatedBy: " · ").compactMap { part in
            let bits = part.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, bits[0] != "0" else { return nil }
            let n = Int(bits[0]).map { $0.formatted() } ?? bits[0]
            let label = bits[1] == "links" ? "Note links" : bits[1].replacingOccurrences(of: "similar pairs", with: "similar").capitalized
            return (n, label)
        }
        let people = indexer.categories.values.filter { $0 == "person" }.count
        let orgs = indexer.categories.values.filter { $0 == "entity" }.count
        let extra: [(String, String)] = [(people, "People"), (orgs, "Organisations"), (graph.islands.count, "Islands")]
            .filter { $0.0 > 0 }.map { ($0.0.formatted(), $0.1) }
        // Notes first, then who and where, then how they're linked.
        return Array(base.prefix(1)) + extra + Array(base.dropFirst())
    }

    private var statsGrid: some View {
        let items = stats
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { row in
                GridRow {
                    ForEach(row..<min(row + 3, items.count), id: \.self) { i in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(items[i].0).font(.headline).monospacedDigit()
                            Text(items[i].1).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            pill("Refresh", "arrow.clockwise", help: "Read the latest from Notes (⌘R)") { indexer.reload() }
            Spacer()
            pill("Rebuild Index…", "arrow.counterclockwise", help: "Forget everything and read every note again (⇧⌘R)") {
                indexer.confirmReindex = true
            }
        }
    }

    private func pill(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .help(help)
    }

    // MARK: Words

    private var phaseLine: String {
        switch indexer.aiPhase {
        case .waiting: return "Waiting for the model"
        case .reading: return timeLeft ?? "Reading…"
        case .paused: return "Paused"
        case .done: return "All read"
        case .unavailable, .off: return ""
        }
    }

    private var phaseSymbol: String {
        switch indexer.aiPhase {
        case .waiting: return "arrow.down.circle"
        case .reading: return "sparkles"
        case .paused: return "pause.circle"
        case .done: return "checkmark.circle"
        case .unavailable: return "exclamationmark.circle"
        case .off: return "text.word.spacing"
        }
    }

    private var explanation: String {
        switch indexer.aiPhase {
        case .unavailable:
            return "\(indexer.aiStatus.replacingOccurrences(of: " · topics from keywords", with: "")). Topics come from keywords instead."
        case .waiting:
            return "The on-device model is still downloading. Reading starts by itself; until then, topics come from keywords."
        case .reading:
            return "Reading your notes on this Mac to find topics and profiles. The graph updates as it goes."
        case .paused:
            return "Notes it hasn't read yet get keyword topics for now."
        case .done:
            return "New and edited notes are read as they change."
        case .off:
            return "Topics come from words your notes share, and people and companies from their names. Both options run on this Mac."
        }
    }

    private var timeLeft: String? {
        guard indexer.aiPhase == .reading, let s = indexer.aiSecondsPerNote else { return nil }
        let remaining = Double(indexer.aiTotal - indexer.aiRead) * s
        guard remaining > 1 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .short
        f.maximumUnitCount = 2
        return f.string(from: remaining).map { "About \($0) left" }
    }
}

// MARK: - Hover card

struct HoverCard: View {
    let hover: GraphHover

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TypeGlyph(type: hover.category)
                Text(hover.label).font(.headline).lineLimit(2)
            }
            Text("\(NoteTypes.name(hover.category, singular: true)) · \(hover.group) · \(hover.links) links")
                .font(.caption).foregroundStyle(.secondary)
            if !hover.snippet.isEmpty {
                Text(hover.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(4)
            }
            Text("Double-click to open in Notes").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

// MARK: - Note types (legend + filter)

struct TypeGlyph: View {
    let type: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if type == "entity" { Rectangle().frame(width: 8, height: 8) }
            else { Circle().frame(width: type == "topic" ? 6 : 9, height: type == "topic" ? 6 : 9) }
        }
        .foregroundStyle(Color(MeshTheme.make(dark: scheme == .dark).color(forType: type)))
        .frame(width: 10, height: 10)
    }
}

/// Names and symbols for the kinds of node.
enum NoteTypes {
    static let order = ["person", "entity", "note", "topic"]
    static func name(_ t: String, singular: Bool = false) -> String {
        switch t {
        case "person": return singular ? "Person" : "People"
        case "entity": return singular ? "Organisation" : "Organisations"
        case "topic": return singular ? "Topic" : "Topics"
        case "tag": return singular ? "Tag" : "Tags"
        default: return singular ? "Note" : "Notes"
        }
    }
    static func symbol(_ t: String) -> String {
        switch t {
        case "person": return "person.crop.circle"
        case "entity": return "building.2"
        case "topic": return "number"
        default: return "note.text"
        }
    }
}

// MARK: - ⌘K palette

struct CommandPalette: View {
    @EnvironmentObject var indexer: Indexer
    @Environment(\.dismiss) private var dismiss
    let onOpen: (String) -> Void
    let onFocus: (String?) -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable { let id: String; let title: String; let subtitle: String; let icon: String; let isNote: Bool }

    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let notes = indexer.notes
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q) }
            .sorted { a, b in
                let at = a.title.localizedCaseInsensitiveContains(q), bt = b.title.localizedCaseInsensitiveContains(q)
                return at != bt ? at : a.modified > b.modified
            }
            .prefix(12)
            .map { Item(id: $0.id, title: $0.title, subtitle: $0.folder, icon: "note.text", isNote: true) }
        let tags = indexer.tags
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .prefix(6)
            .map { Item(id: $0.id, title: $0.name, subtitle: "\($0.count) notes", icon: $0.kind == "tag" ? "number" : "sparkles", isNote: false) }
        return Array(notes) + Array(tags)
    }

    var body: some View {
        let items = self.items
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a note or topic", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { activate(items, focusOnly: false) }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            HStack {
                                Image(systemName: item.icon).frame(width: 20).foregroundStyle(item.isNote ? Color.secondary : Color.purple)
                                Text(item.title).lineLimit(1)
                                Spacer()
                                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(i == index ? Color.accentColor.opacity(0.25) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { index = i; activate(items, focusOnly: false) }
                            .id(i)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: index) { proxy.scrollTo(index) }
            }
            .frame(height: 320)
            Divider()
            HStack(spacing: 16) {
                Text("↩ open in Notes"); Text("⌘↩ show in graph"); Text("esc close")
            }
            .font(.caption).foregroundStyle(.secondary).padding(10)
            Button("") { activate(items, focusOnly: true) }
                .keyboardShortcut(.return, modifiers: .command).hidden().frame(height: 0)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
    }

    private func activate(_ items: [Item], focusOnly: Bool) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        dismiss()
        onFocus(item.id)
        if item.isNote && !focusOnly { onOpen(item.id) }
    }
}

// MARK: - Connect your notes (top of the drawer while sample notes are showing)

/// NoteMesh opens straight into a graph of sample notes, so you can see what it does. This
/// card, at the top of the drawer, explains what it does with your notes and walks you through
/// Full Disk Access; the moment access is on, your own notes replace the samples.
struct ConnectCard: View {
    @EnvironmentObject var indexer: Indexer
    @State private var openedSettings = false
    @State private var showWhy = false
    @Environment(\.colorScheme) private var scheme

    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    private static let tileShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    /// A lighter panel on the card's warm glass, clearly its own tile in light and dark.
    private var tileFill: Color { Color(nsColor: .controlBackgroundColor).opacity(scheme == .dark ? 0.55 : 0.7) }

    // Built from the same tiles as the Connections panel: icons in circles, soft fills on
    // glass, one type scale. Header, three promise tiles, a details tile, a steps tile, a button.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.bottom, 4)
            switch indexer.connect {
            case .noLibrary?:
                problemTile("Open the Notes app once (and sign in to iCloud Notes if you use it), then try again.", technical: nil)
                retry
            case .failed(let message)?:
                problemTile("NoteMesh couldn't read part of your library. Try again, and if it keeps failing, please report it on GitHub.", technical: message)
                retry
            default:
                promises
                whyTile
                stepsTile
                connectButton.padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: .orange.opacity(0.45))
        .animation(.smooth, value: openedSettings)
        .animation(.smooth, value: showWhy)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(.linearGradient(colors: [.orange, .pink, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 1) {
                Text(indexer.connect == .noLibrary ? "No Notes library yet" : "These are sample notes")
                    .font(.headline)
                Text(indexer.connect == .noLibrary ? "NoteMesh couldn't find one on this Mac." : "Connect yours to see them as a map.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4).padding(.top, 4)
    }

    private var promises: some View {
        HStack(spacing: 8) {
            promise("lock.shield.fill", "This Mac", help: "Stays on this Mac: no accounts, network or analytics.")
            promise("eye.fill", "Read-only", help: "Your notes are never changed.")
            promise("cpu.fill", "On-device", help: "Any AI runs privately on your Mac.")
        }
    }

    private func promise(_ symbol: String, _ title: String, help: String) -> some View {
        VStack(spacing: 6) {
            iconCircle(symbol)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Self.tileShape.fill(tileFill))
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }

    /// The full story, folded into a tile under the promises.
    private var whyTile: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showWhy.toggle() } label: {
                HStack(spacing: 10) {
                    iconCircle("text.magnifyingglass")
                    Text("What NoteMesh does with your notes").font(.callout.weight(.medium))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showWhy ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(showWhy ? .isSelected : [])
            if showWhy {
                VStack(alignment: .leading, spacing: 10) {
                    fact("doc.on.doc", "Reads a temporary copy of your notes, then deletes it.")
                    fact("lock", "Never edits your notes and skips locked ones.")
                    fact("trash", "File → Delete NoteMesh Data removes everything it saved.")
                }
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .padding(10)
        .clipped()   // grows within its own tile instead of sliding over the text above
        .background(Self.tileShape.fill(tileFill))
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.callout.weight(.medium)).foregroundStyle(.secondary).frame(width: 30)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepsTile: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, "Open Full Disk Access", done: openedSettings)
            HStack(spacing: 10) {
                step(2, "Drag NoteMesh into the list", done: false)
                Spacer(minLength: 4)
                appTile
            }
            step(3, "Switch it on; your notes load", done: false)
        }
        .padding(10)
        .background(Self.tileShape.fill(tileFill))
    }

    private func step(_ n: Int, _ text: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(Color.green) : AnyShapeStyle(.primary.opacity(0.1)))
                if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.callout.weight(.semibold)).monospacedDigit() }
            }
            .frame(width: 30, height: 30)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func iconCircle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(.primary.opacity(0.1)))
    }

    /// The app itself, draggable into System Settings' Full Disk Access list.
    private var appTile: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable().frame(width: 30, height: 30)
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
            .help("Drag into the Full Disk Access list")
            .accessibilityLabel("NoteMesh app, drag into the Full Disk Access list")
    }

    private var connectButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                NSWorkspace.shared.open(Self.settingsURL)
                withAnimation { openedSettings = true }
            } label: {
                Label(openedSettings ? "Open Settings Again" : "Connect My Notes", systemImage: "lock.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            if openedSettings {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for access… If macOS offers Quit & Reopen, choose it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .transition(.opacity)
            }
        }
    }

    private func problemTile(_ text: String, technical: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Circle().fill(.orange))
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let technical {
                Text(technical).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.tileShape.fill(tileFill))
    }

    private var retry: some View {
        Button { indexer.retryConnect() } label: { Label("Try Again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
            .buttonStyle(.glassProminent).controlSize(.large)
    }
}

/// Only if even the sample notes can't load (shouldn't happen): a plain message.
struct LoadFailedView: View {
    let message: String
    var body: some View {
        ContentUnavailableView("NoteMesh couldn't start", systemImage: "exclamationmark.triangle",
                               description: Text(message))
    }
}

// MARK: - Simple flow layout for tag chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(bounds.width, subviews)
        for (i, p) in rows.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x)
        }
        return (points, maxX, y + rowHeight)
    }
}

// MARK: - Glass control behaviour

/// `.interactive()` glass swallows clicks on custom buttons on macOS, so controls use plain glass
/// and get their response here: the content dips while pressed…
struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// …and the glass itself swells a touch under the pointer.
private struct HoverLift: ViewModifier {
    let scale: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .animation(.bouncy(duration: 0.3, extraBounce: 0.1), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift(_ scale: CGFloat = 1.08) -> some View { modifier(HoverLift(scale: scale)) }
}

/// Controls that sit in the title bar strip would otherwise drag the window. AppKit leaves a
/// view's area out of the title bar's drag region when it says it can't move the window; this
/// one is invisible to clicks, so the SwiftUI control above it still gets them.
struct NoWindowDrag: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}
}

// MARK: - Entrance

/// Each floating surface rises into place once, when the window first appears: a short,
/// staggered spring from its own corner. Skipped with Reduce Motion.
private struct Entrance: ViewModifier {
    let shown: Bool, delay: Double, anchor: UnitPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.92, anchor: anchor)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .bouncy(duration: 0.55, extraBounce: 0.06).delay(delay), value: shown)
    }
}

extension View {
    func entrance(_ shown: Bool, delay: Double, anchor: UnitPoint) -> some View {
        modifier(Entrance(shown: shown, delay: delay, anchor: anchor))
    }
}

// MARK: - Island pills

/// Zoomed far out, each island's name floats over its middle as a Liquid Glass pill (the
/// map's neighbourhood names). Positions come from the renderer in the same frame it draws.
struct IslandPills: View {
    @ObservedObject var graph: GraphController
    let open: (Int) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(graph.pills) { pill in
                    Button { open(pill.id) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(pill.colour).frame(width: 7, height: 7)
                            Text(pill.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Text("\(pill.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).frame(height: 30)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(GlassPressStyle())
                    .glassEffect(.regular, in: .capsule)
                    .fixedSize()
                    // Only opacity animates; position follows the graph exactly, frame by frame.
                    .opacity(pill.opacity)
                    .position(pill.point)
                    .transaction { $0.animation = nil }
                    .help("Show the \(pill.title) island")
                    .accessibilityLabel("\(pill.title) island, \(pill.count) notes")
                }
            }
        }
    }
}

// MARK: - Island colours

/// Each island gets its own hue (stable by island id), used for its pill dot, its card and
/// its detail page, so a cluster is recognisable wherever it appears.
enum IslandPalette {
    static let hues: [Color] = MeshTheme.islandRGB.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) }
    static func colour(_ id: Int) -> Color { hues[((id % hues.count) + hues.count) % hues.count] }
}

extension IslandPill { var colour: Color { IslandPalette.colour(id) } }
extension IslandSummary { var colour: Color { IslandPalette.colour(id) } }

// MARK: - Appearance

/// Auto (follows the Mac), Light or Dark. One glass circle under the slider; each click moves
/// to the next. The choice is remembered and applied at launch.
enum AppAppearance: String, CaseIterable {
    case auto, light, dark
    var next: AppAppearance { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
    var symbol: String {
        switch self { case .auto: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" }
    }
    var name: String {
        switch self { case .auto: "Automatic"; case .light: "Light"; case .dark: "Dark" }
    }
    @MainActor func apply() {
        switch self {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    @MainActor static func applySaved() {
        (AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .auto).apply()
    }
}

struct ThemeButton: View {
    @AppStorage("appearance") private var raw = AppAppearance.auto.rawValue
    private var mode: AppAppearance { AppAppearance(rawValue: raw) ?? .auto }

    var body: some View {
        Button {
            let next = mode.next
            raw = next.rawValue
            withAnimation(.smooth(duration: 0.35)) { next.apply() }
        } label: {
            Image(systemName: mode.symbol)
                .font(.system(size: 14, weight: .medium))
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: TopControls.size, height: TopControls.size)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .help("Appearance: \(mode.name). Click for \(mode.next.name).")
        .accessibilityLabel("Appearance")
        .accessibilityValue(mode.name)
    }
}

// MARK: - Why Apple Intelligence isn't in use

extension AITagger.Blocker {
    /// For the banner and tooltips.
    var short: String {
        switch self {
        case .downloading: "Apple Intelligence is still downloading to this Mac"
        case .restricted: "Your organisation has turned off Apple Intelligence on this Mac"
        case .notEnabled: "Apple Intelligence is turned off in System Settings"
        case .unsupported: "This Mac doesn't support Apple Intelligence"
        case .other: "Apple Intelligence isn't available right now"
        }
    }
    /// For the one-time notice.
    var message: String {
        switch self {
        case .downloading: "Apple Intelligence isn't downloaded to this Mac yet, so NoteMesh arranges your notes by keyword for now. It switches over by itself when the download finishes."
        case .restricted: "Your organisation has turned off Apple Intelligence on this Mac, so NoteMesh arranges your notes by keyword."
        case .notEnabled: "Apple Intelligence is turned off on this Mac, so NoteMesh arranges your notes by keyword. You can turn it on in System Settings under Apple Intelligence & Siri."
        case .unsupported: "This Mac doesn't support Apple Intelligence, so NoteMesh arranges your notes by keyword."
        case .other: "Apple Intelligence isn't available right now, so NoteMesh arranges your notes by keyword. It switches over by itself when it becomes available."
        }
    }
}

/// The one-time "arranging notes by keyword" notice.
struct FallbackNotice: ViewModifier {
    @ObservedObject var indexer: Indexer
    func body(content: Content) -> some View {
        content.alert("Arranging notes by keyword", isPresented: $indexer.showFallbackNotice, presenting: indexer.aiBlocker) { reason in
            if reason == .notEnabled {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                }
            }
            Button("OK", role: .cancel) {}
        } message: { reason in
            Text(reason.message)
        }
    }
}
