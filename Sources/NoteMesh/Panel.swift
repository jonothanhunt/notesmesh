import SwiftUI

/// How far the drawer is pulled up.
enum PanelDetent: Int { case collapsed, medium, large }

/// The Maps-style drawer: a Liquid Glass sheet rising from the bottom-left edge, with a grabber.
/// It snaps between three heights — just search, half, full — and follows the pointer while
/// you drag. Home shows search, people, entities, topics, recent notes and view options;
/// selecting a node turns it into that node's page.
struct SidePanel: View {
    @EnvironmentObject var indexer: Indexer
    @ObservedObject var graph: GraphController
    @Binding var selection: String?
    @Binding var search: String
    @Binding var detent: PanelDetent
    let available: CGFloat            // height from the drawer's top limit to the window bottom
    let focus: (String?) -> Void

    // View options (shared with ContentView through AppStorage).
    @AppStorage("layer.link") private var showLinks = true
    @AppStorage("layer.tag.v2") private var showTags = false
    @AppStorage("layer.topic") private var showTopics = true
    @AppStorage("layer.similar") private var showSimilar = true
    @AppStorage("similarPerNote") private var similarPerNote = 2
    @AppStorage("cluster.islands") private var islands = true
    @AppStorage("cluster.folders") private var byFolder = false

    @FocusState private var searchFocused: Bool
    @State private var drag: CGFloat = 0      // live drag, positive = taller
    @State private var hovering = false
    @State private var contentAtTop = true
    @State private var scrollMonitor: Any?
    @State private var lastWheelStep = Date.distantPast
    /// A scroll that starts on the drawer stays with the drawer until it ends (momentum
    /// included), even once the drawer has shrunk out from under the pointer.
    @State private var scrollLatched = false
    /// Decided once per swipe: a swipe that starts with the list scrolled down belongs to the
    /// list (it can scroll back to the top but never carries on into shrinking the drawer).
    @State private var swipeScrollsList = false
    @State private var wheelLatchUntil = Date.distantPast
    @State private var highlighted = 0        // keyboard-selected search result
    @State private var showAllIslands = false
    @Environment(\.colorScheme) private var scheme

    private var selectionTint: Color? {
        guard let id = selection else { return nil }
        if id.hasPrefix("island:"), let n = Int(id.dropFirst(7)) { return IslandPalette.colour(n) }
        let type: String
        if indexer.notesByID[id] != nil { type = indexer.categories[id] ?? "note" } else { type = "topic" }
        return Color(MeshTheme.make(dark: scheme == .dark).color(forType: type))
    }
    @State private var showAllPeople = false
    @State private var showAllEntities = false
    static let width: CGFloat = 340
    /// Collapsed with nothing selected, the drawer is just its search field: a glass pill.
    /// The search field (38pt) with the same 12pt all round, like Maps; the grabber sits in the
    /// top gap rather than adding to it.
    static let pillInset: CGFloat = 12
    static let pillHeight: CGFloat = 38 + pillInset * 2
    private var collapsedHeight: CGFloat { selection == nil ? Self.pillHeight : 150 }
    /// The pill: collapsed, nothing selected, not being dragged open.
    /// Rounded like a sheet when open; fully round as a pill.
    /// One shape at every size, like Maps: the corners run parallel to the search field's
    /// (19pt field radius + 12pt inset = 31), so collapsing just makes the drawer shorter and it
    /// wraps the field evenly with no special case.
    private var cornerRadius: CGFloat { 19 + Self.pillInset }
    func height(_ d: PanelDetent) -> CGFloat {
        switch d {
        case .collapsed: return collapsedHeight
        case .medium: return max(collapsedHeight + 60, available * 0.5)
        case .large: return available
        }
    }
    private var currentHeight: CGFloat {
        min(available, max(collapsedHeight, height(detent) + drag))
    }
    /// Content shows once the drawer is pulled up past its collapsed size.
    private var showsContent: Bool { currentHeight > collapsedHeight + 30 }

    var body: some View {
        VStack(spacing: 0) {
            if let id = selection {
                // The page runs to the drawer's top edge; the grabber floats over its bar.
                DetailPage(id: id, selection: $selection, collapsed: !showsContent, scrollEnabled: detent == .large,
                           atTop: $contentAtTop, focus: focus)
                    .overlay(alignment: .top) { grabber.frame(height: Self.pillInset) }
                    .clipShape(.rect(cornerRadius: cornerRadius))
            } else {
                // The grabber and search field float together over the list, so content runs
                // right up to the drawer's top edge and fades out under both.
                // The same inset on every side at every size; the grabber rides in the top gap.
                let bar = searchField
                    .padding(Self.pillInset)
                    .overlay(alignment: .top) { grabber.frame(height: Self.pillInset) }
                // One list at every size (so the search field keeps its focus as the drawer
                // grows). The field floats over the top: content scrolls up under it and fades
                // away softly, instead of stopping at a hard edge.
                // The content is always there; when the drawer shrinks, its edge simply clips it
                // (sliding out of view), rather than the content being removed and animating away.
                ScrollView {
                    if search.trimmingCharacters(in: .whitespaces).isEmpty { home } else { results }
                }
                .safeAreaInset(edge: .top, spacing: 0) { bar }
                .drawerScroll(enabled: detent == .large && showsContent, atTop: $contentAtTop)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width, height: currentHeight, alignment: .top)
        .clipShape(.rect(cornerRadius: cornerRadius))
        // A soft wash of the selection's colour from the drawer's top edge, like Maps' place cards.
        .background {
            if let tint = selectionTint {
                let fade = min(1, 240 / max(1, currentHeight))
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(LinearGradient(stops: [.init(color: tint.opacity(scheme == .dark ? 0.30 : 0.20), location: 0),
                                                 .init(color: tint.opacity(0), location: fade)],
                                         startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        .animation(drag == 0 ? .smooth(duration: 0.32) : nil, value: currentHeight)
        .animation(.smooth(duration: 0.25), value: selection)
        .onChange(of: selection) { if selection != nil && detent == .collapsed { detent = .medium } }
        .onChange(of: searchFocused) { if searchFocused { detent = .large } }
        .onChange(of: search) { highlighted = 0 }
        .onHover { hovering = $0 }
        .onAppear(perform: installScrollMonitor)
        .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m) }; scrollMonitor = nil }
        .background {
            // ⌘F jumps to search, as in Maps.
            Button("") { selection = nil; detent = .large; searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    // MARK: Grabber (drag to resize, click to step)

    private var grabber: some View {
        Capsule().fill(.tertiary).frame(width: 36, height: 5)
            .frame(maxWidth: .infinity).frame(height: 18)
            .contentShape(Rectangle())
            .gesture(resize)
            .onTapGesture {
                detent = detent == .large ? .collapsed : PanelDetent(rawValue: detent.rawValue + 1)!
            }
            .help("Drag to resize")
            .accessibilityElement()
            .accessibilityLabel("Panel size")
            .accessibilityValue(["Small", "Half", "Full"][detent.rawValue])
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: detent = PanelDetent(rawValue: min(2, detent.rawValue + 1))!
                case .decrement: detent = PanelDetent(rawValue: max(0, detent.rawValue - 1))!
                @unknown default: break
                }
            }
    }

    // MARK: Scrolling grows the drawer first (like an iPhone sheet), then scrolls inside

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleScroll(event) ? nil : event
        }
    }

    /// Returns true when the drawer used the scroll (so the content shouldn't).
    private func handleScroll(_ e: NSEvent) -> Bool {
        if e.hasPreciseScrollingDeltas {
            if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
                scrollLatched = hovering
                swipeScrollsList = detent == .large && !contentAtTop
            }
            // The gesture (and its coast) is over: let go.
            defer {
                if e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled)
                    || (e.momentumPhase.isEmpty && (e.phase.contains(.cancelled))) { scrollLatched = false }
            }
            guard hovering || scrollLatched else { return false }
            if swipeScrollsList { return false }   // the list's swipe, coast included
        } else {
            // A mouse wheel has no phases: keep it ours for a moment after each notch.
            guard hovering || Date() < wheelLatchUntil else { return false }
            wheelLatchUntil = Date().addingTimeInterval(0.4)
        }
        if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) && drag == 0 { return false }   // sideways: not ours
        let dy = e.scrollingDeltaY                 // < 0: content would move up (see more)
        let growing = detent != .large
        let pullingDown = detent == .large && contentAtTop && dy > 0
        guard growing || pullingDown || drag != 0 else { return false }
        if !e.hasPreciseScrollingDeltas {
            // Mouse wheel: one notch steps one size, with a short pause between steps.
            guard Date().timeIntervalSince(lastWheelStep) > 0.25 else { return true }
            lastWheelStep = Date()
            if dy < 0, detent != .large { withAnimation(.smooth(duration: 0.32)) { detent = PanelDetent(rawValue: detent.rawValue + 1)! }; return true }
            if dy > 0, detent != .collapsed, contentAtTop || detent != .large {
                withAnimation(.smooth(duration: 0.32)) { detent = PanelDetent(rawValue: detent.rawValue - 1)! }; return true
            }
            return false
        }
        if !e.momentumPhase.isEmpty { return drag != 0 || growing }   // swallow the coast after a resize
        drag -= dy
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            // Settle at the next size beyond where the swipe left the drawer, in the direction
            // it was going: a short swipe steps once, a long one goes all the way.
            let reached = height(detent) + drag
            let sizes: [PanelDetent] = [.collapsed, .medium, .large]
            let target: PanelDetent
            if drag > 40 { target = sizes.first { height($0) >= reached - 24 && $0.rawValue > detent.rawValue } ?? .large }
            else if drag < -40 { target = sizes.reversed().first { height($0) <= reached + 24 && $0.rawValue < detent.rawValue } ?? .collapsed }
            else { target = detent }
            withAnimation(.smooth(duration: 0.32)) { detent = target; drag = 0 }
        }
        return true
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { v in drag = -v.translation.height }
            .onEnded { v in
                // Snap to the detent nearest where a flick would land.
                let projected = height(detent) - v.predictedEndTranslation.height
                let best = [PanelDetent.collapsed, .medium, .large].min { abs(height($0) - projected) < abs(height($1) - projected) }!
                withAnimation(.smooth(duration: 0.32)) { detent = best; drag = 0 }
            }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(indexer.connect != nil ? "Search sample notes" : "Search notes", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    let hits = searchResults
                    if hits.indices.contains(highlighted) { selection = hits[highlighted].id }
                }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, searchResults.count - 1)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.escape) {
                    if search.isEmpty { searchFocused = false } else { search = "" }
                    return .handled
                }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).frame(height: 38)
        .glassSurface(Capsule(), lit: searchFocused)
        .onTapGesture { if detent == .collapsed { detent = .large } }
    }

    private struct Hit: Identifiable { let id: String; let title: String; let subtitle: String; let type: String }

    private var searchResults: [Hit] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let topics = indexer.tags.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(5)
            .map { Hit(id: $0.id, title: $0.name, subtitle: "\($0.kind == "tag" ? "Tag" : "Topic") · \($0.count) notes", type: "topic") }
        let titleHits = indexer.notes.filter { $0.title.localizedCaseInsensitiveContains(q) }
        let bodyHits = indexer.notes.filter { !$0.title.localizedCaseInsensitiveContains(q) && $0.text.localizedCaseInsensitiveContains(q) }
        let notes = (titleHits.sorted { $0.modified > $1.modified } + bodyHits.sorted { $0.modified > $1.modified }).prefix(30)
            .map { Hit(id: $0.id, title: $0.title.isEmpty ? "Untitled" : $0.title, subtitle: subtitle($0), type: indexer.categories[$0.id] ?? "note") }
        return topics + notes
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            let hits = searchResults
            if hits.isEmpty {
                Text("No matches").foregroundStyle(.secondary).padding(20)
            } else {
                GroupBox16 {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
                        if i > 0 { Divider().padding(.leading, 42) }
                        Row(title: hit.title, subtitle: hit.subtitle, type: hit.type, selected: i == highlighted) { selection = hit.id }
                    }
                }
            }
        }
        .padding(16)
    }

    // MARK: Home

    // No GlassEffectContainer here: it blends its glass as one group, and cards moving with the
    // scroll then interpolate into each other. Each card is its own lens instead.
    private var home: some View { homeContent }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            if indexer.connect != nil { ConnectCard() }
            // Islands refresh as the layout settles; they just appear, rather than sliding about.
            if !graph.islands.isEmpty { islandsSection.transaction { $0.animation = nil } }
            let people = profiles("person"), entities = profiles("entity")
            if !people.isEmpty { profileGrid("People", people, type: "person", expanded: $showAllPeople) }
            if !entities.isEmpty { profileGrid("Organisations", entities, type: "entity", expanded: $showAllEntities) }

            let topics = indexer.tags.filter { $0.kind == "topic" }.prefix(18)
            if !topics.isEmpty {
                section("Topics") {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(topics)) { t in
                            Chip(text: t.name, count: t.count, tint: Color(MeshTheme.make(dark: scheme == .dark).color(forType: "topic"))) { selection = t.id }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Self.pillInset).padding(.top, 4).padding(.bottom, 28)
    }

    /// Islands as little maps: each card draws its community from the real layout.
    private var islandsSection: some View {
        let all = graph.islands
        let shown = showAllIslands ? all : Array(all.prefix(4))
        return section("Islands", count: all.count, expanded: all.count > 4 ? $showAllIslands : nil) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(shown) { island in
                    IslandCard(island: island) { selection = "island:\(island.id)" }
                }
            }
        }
    }

    /// People / entities as an avatar grid (no sideways scrolling inside the drawer).
    private func profileGrid(_ title: String, _ notes: [Note], type: String, expanded: Binding<Bool>) -> some View {
        let shown = expanded.wrappedValue ? notes : Array(notes.prefix(8))
        return section(title, count: notes.count, expanded: notes.count > 8 ? expanded : nil) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), alignment: .center, spacing: 14) {
                ForEach(shown) { n in
                    Button { selection = n.id } label: {
                        VStack(spacing: 5) {
                            Avatar(name: n.title, type: type, size: 50)
                            Text(n.title).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.tail)
                            Text("\(indexer.adjacency[n.id]?.count ?? 0) links").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPressStyle())
                    .hoverRaise()
                    .help(n.title)
                }
            }
        }
    }

    // MARK: Sections

    /// Profiles of one kind, most connected first; several notes with the same title show once.
    private func profiles(_ type: String) -> [Note] {
        var seen = Set<String>()
        return indexer.notes.filter { indexer.categories[$0.id] == type }
            .sorted { (indexer.adjacency[$0.id]?.count ?? 0) > (indexer.adjacency[$1.id]?.count ?? 0) }
            .filter { seen.insert($0.title.lowercased().trimmingCharacters(in: .whitespaces)).inserted }
    }

    /// A Maps-style section: bold title, count, and a "Show All" toggle when there's more.
    private func section<C: View>(_ title: String, count: Int? = nil, expanded: Binding<Bool>? = nil,
                                  @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Like Maps: "Places ›". The title itself expands the section; the chevron turns.
            Button {
                if let expanded { withAnimation(.smooth) { expanded.wrappedValue.toggle() } }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.title3.weight(.bold))
                    if expanded != nil {
                        Image(systemName: "chevron.right").font(.callout.weight(.bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded?.wrappedValue == true ? 90 : 0))
                    }
                    Spacer()
                    // Counts live in the Apple Intelligence panel's stats, not here.
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(expanded == nil)
            .help(expanded == nil ? "" : (expanded!.wrappedValue ? "Show fewer" : "Show all"))
            content()
        }
    }

    private func subtitle(_ n: Note) -> String {
        "\(n.folder) · \(n.modified.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - Island card

/// A tiny map of one island in its own colour, on a surface that catches the light: a soft
/// highlight follows the pointer across it, the way Liquid Glass reflects what moves near it.
struct IslandCard: View {
    let island: IslandSummary
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var light: CGPoint?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                IslandMap(island: island, tint: island.colour)
                    .frame(height: 78)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Circle().fill(island.colour).frame(width: 7, height: 7)
                        Text(island.title).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    Text(island.people > 0 ? "\(island.count) notes · \(island.people) people" : "\(island.count) notes")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            // One glow for the whole card, brightest behind the map, fading towards the edges.
            // A soft glow behind the map, inside the island's tinted glass.
            .background(
                shape.fill(RadialGradient(colors: [island.colour.opacity(scheme == .dark ? 0.22 : 0.16), island.colour.opacity(0)],
                                          center: UnitPoint(x: 0.5, y: 0.36), startRadius: 0, endRadius: 120))
            )
            .glassSurface(shape, lit: hovering, tint: island.colour)
            .overlay {
                // The moving reflection.
                if let light {
                    GeometryReader { geo in
                        RadialGradient(colors: [.white.opacity(scheme == .dark ? 0.16 : 0.35), .clear],
                                       center: UnitPoint(x: light.x / max(1, geo.size.width), y: light.y / max(1, geo.size.height)),
                                       startRadius: 0, endRadius: 90)
                    }
                    .clipShape(shape)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(SoftPressStyle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): light = p; hovering = true
            case .ended: light = nil; hovering = false
            }
        }
        .offset(y: hovering ? -2 : 0)
        .shadow(color: island.colour.opacity(hovering ? 0.25 : 0), radius: 12, y: 5)
        .animation(.snappy(duration: 0.2), value: hovering)
        .accessibilityLabel("\(island.title) island, \(island.count) notes")
    }
}

/// The island's notes as dots: notes in the island's colour, people and entities in theirs.
struct IslandMap: View {
    let island: IslandSummary
    var tint: Color? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let theme = MeshTheme.make(dark: scheme == .dark)
            let pad: CGFloat = 8
            let w = size.width - pad * 2, h = size.height - pad * 2
            let s = min(w, h)
            let ox = pad + (w - s) / 2, oy = pad + (h - s) / 2
            for (p, t) in zip(island.points, island.types) {
                let r: CGFloat = t == "note" ? 1.7 : 2.8
                let c = CGRect(x: ox + p.x * s - r, y: oy + p.y * s - r, width: r * 2, height: r * 2)
                let color = t == "note" ? (tint.map { scheme == .dark ? $0.mix(with: .white, by: 0.45) : $0.mix(with: .black, by: 0.2) }
                                           ?? Color(theme.color(forType: t)))
                                        : Color(theme.color(forType: t))
                ctx.fill(t == "entity" ? Path(c) : Path(ellipseIn: c), with: .color(color.opacity(t == "note" ? 0.85 : 1)))
            }
        }
    }
}

// MARK: - Glass-like surfaces inside the drawer

/// Real Liquid Glass for the things that sit on the drawer: the search field, cards, grouped
/// lists and chips. Each is its own lens (Maps does the same with its search field), tinted when
/// it has a colour of its own, and a little brighter while hovered or focused.
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let lit: Bool
    let tint: Color?
    func body(content: Content) -> some View {
        content
            .glassEffect(glass, in: shape)
            .animation(.smooth(duration: 0.2), value: lit)
    }
    private var glass: Glass {
        if let tint { return .regular.tint(tint.opacity(lit ? 0.42 : 0.3)) }
        return lit ? .regular.tint(.white.opacity(0.08)) : .regular
    }
}

extension View {
    func glassSurface<S: Shape>(_ shape: S, lit: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: shape, lit: lit, tint: tint))
    }
}

// MARK: - Detail page (a selected note, person, entity or topic)

struct DetailPage: View {
    @EnvironmentObject var indexer: Indexer
    let id: String
    @Binding var selection: String?
    let collapsed: Bool
    let scrollEnabled: Bool
    @Binding var atTop: Bool
    let focus: (String?) -> Void

    @EnvironmentObject var graphController: GraphController
    @Environment(\.colorScheme) private var scheme

    private var island: IslandSummary? {
        guard id.hasPrefix("island:"), let n = Int(id.dropFirst(7)) else { return nil }
        return graphController.islands.first { $0.id == n }
    }

    /// How far the page has scrolled (0 at rest), for the slim title bar.
    @State private var scrolled: CGFloat = 0

    // Like a Maps place card: the big title block is the top of the page and scrolls away;
    // glass buttons stay pinned in the corners, and once the title has slid under them a slim
    // bar fades in with the name in small type. Content scrolls softly under that bar.
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                // Always present, so collapsing clips the page instead of animating it away.
                VStack(alignment: .leading, spacing: 20) {
                    if let note = indexer.notesByID[id] { noteBody(note) }
                    else if let island { islandBody(island) }
                    else { hubBody }
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .drawerScroll(enabled: scrollEnabled && !collapsed, atTop: $atTop)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
            scrolled = y
        }
        .id(id)   // a new page starts at the top
    }

    private var title: String { island?.title ?? indexer.label(id) }
    private var hasAvatar: Bool { type == "person" || type == "entity" }

    /// 0 while the big title is visible, 1 once it has scrolled under the bar.
    private var compact: Double {
        let start: CGFloat = hasAvatar ? 70 : 8
        return Double(min(1, max(0, (scrolled - start) / 26)))
    }

    private var topBar: some View {
        ZStack {
            Text(title)
                .font(.headline).lineLimit(1)
                .padding(.horizontal, 58)
                .opacity(compact)
                .offset(y: (1 - compact) * 6)
            HStack {
                if indexer.notesByID[id] != nil {
                    circleButton("note.text", help: "Open in Notes (⌘↩)") { indexer.open(id) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
                Spacer()
                circleButton("xmark", help: "Close") { selection = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, SidePanel.pillInset)   // the grabber rides in this gap
        .padding(.bottom, 6)
        // Once the title has slid under, a frosted backing fades in behind the bar so the small
        // title never sits on top of the page; it softens away at its lower edge.
        .background {
            Rectangle().fill(.regularMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .padding(.bottom, -14)
                .opacity(compact)
                .allowsHitTesting(false)
        }
        .animation(.smooth(duration: 0.2), value: compact > 0.5)
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .glassEffect(.regular, in: .circle)
        .help(help)
    }

    @ViewBuilder private func islandBody(_ island: IslandSummary) -> some View {
        IslandMap(island: island)
            .frame(height: 180).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(.primary.opacity(0.05)))
        let notes = island.noteIDs.compactMap { indexer.notesByID[$0] }
            .sorted { (indexer.adjacency[$0.id]?.count ?? 0) > (indexer.adjacency[$1.id]?.count ?? 0) }
        block("Notes") {
            GroupBox16 {
                ForEach(Array(notes.enumerated()), id: \.element.id) { i, n in
                    if i > 0 { Divider().padding(.leading, 42) }
                    Row(title: n.title, subtitle: n.folder, type: indexer.categories[n.id] ?? "note",
                        onOpen: { indexer.open(n.id) }) { selection = n.id }
                }
            }
        }
    }

    private var type: String {
        if indexer.notesByID[id] != nil { return indexer.categories[id] ?? "note" }
        return id.hasPrefix("tag:") ? "tag" : "topic"
    }

    // Title block, centred like a Maps place card.
    private var header: some View {
        VStack(spacing: 6) {
            if hasAvatar { Avatar(name: indexer.label(id), type: type, size: 64) }
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center).lineLimit(3)
                .padding(.horizontal, 48)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            if indexer.notesByID[id] != nil {
                Button { indexer.open(id) } label: {
                    Label("Open in Notes", systemImage: "note.text").padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .padding(.top, 6)
            }
        }
        // Tucked up between the corner buttons, as in Maps.
        .padding(.top, hasAvatar ? -30 : -34)
        .padding(.bottom, collapsed ? 14 : 6)
    }

    private var subtitle: String {
        if let island { return "Island · \(island.count) notes" + (island.people > 0 ? " · \(island.people) people" : "") }
        if let n = indexer.notesByID[id] { return "\(NoteTypes.name(type, singular: true)) · \(n.folder)" }
        let members = indexer.adjacency[id]?.count ?? 0
        return "\(type == "tag" ? "Your tag" : "Topic") · \(members) notes"
    }

    @ViewBuilder private func noteBody(_ note: Note) -> some View {
        let edges = indexer.adjacency[note.id] ?? []
        let links = edges.filter { $0.kind == "link" || $0.kind == "notelink" }
        let similar = edges.filter { $0.kind == "similar" }.sorted { $0.w > $1.w }
        let topics = edges.filter { $0.kind == "topic" || $0.kind == "tag" }

        // Stats row, like Maps' ratings / distance.
        HStack {
            stat("Links", "\(links.count)")
            Divider().frame(height: 30)
            stat("Topics", "\(topics.count)")
            Divider().frame(height: 30)
            stat("Edited", note.modified.formatted(.dateTime.day().month(.abbreviated)))
        }
        .frame(maxWidth: .infinity)

        if !note.snippet.isEmpty {
            Text(note.snippet).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(.primary.opacity(0.05)))
        }
        if !topics.isEmpty {
            block("Topics") {
                FlowLayout(spacing: 6) {
                    ForEach(topics, id: \.other) { e in Chip(text: indexer.label(e.other), count: nil) { selection = e.other } }
                }
            }
        }
        let person = type == "person" || type == "entity"
        let alsoNotes = (indexer.merged[note.id] ?? []).compactMap { indexer.notesByID[$0] }
        if !alsoNotes.isEmpty {
            // Same-titled profile notes live in this one node; each still opens on its own.
            block("Also Titled “\(note.title)”") {
                GroupBox16 {
                    ForEach(Array(alsoNotes.enumerated()), id: \.element.id) { i, n in
                        if i > 0 { Divider().padding(.leading, 42) }
                        Row(title: n.snippet.isEmpty ? "Empty note" : String(n.snippet.prefix(60)),
                            subtitle: "\(n.folder) · edited \(n.modified.formatted(.dateTime.day().month(.abbreviated).year()))",
                            type: type, onOpen: { indexer.open(n.id) }) { indexer.open(n.id) }
                    }
                }
            }
        }
        list(person ? "Mentioned In" : "Linked", links)
        list("Similar Notes", similar)
    }

    @ViewBuilder private var hubBody: some View {
        let members = (indexer.adjacency[id] ?? []).compactMap { indexer.notesByID[$0.other] }.sorted { $0.modified > $1.modified }
        block("Notes") {
            GroupBox16 {
                ForEach(Array(members.enumerated()), id: \.element.id) { i, n in
                    if i > 0 { Divider().padding(.leading, 42) }
                    Row(title: n.title, subtitle: n.folder, type: indexer.categories[n.id] ?? "note") { selection = n.id }
                }
            }
        }
    }

    @ViewBuilder private func list(_ title: String, _ edges: [Edge]) -> some View {
        let ids = edges.map(\.other).filter { indexer.notesByID[$0] != nil }
        if !ids.isEmpty {
            block(title) {
                GroupBox16 {
                    ForEach(Array(ids.prefix(25).enumerated()), id: \.element) { i, other in
                        if i > 0 { Divider().padding(.leading, 42) }
                        Row(title: indexer.label(other), subtitle: indexer.notesByID[other].map { $0.folder } ?? "",
                            type: indexer.categories[other] ?? "note", onOpen: { indexer.open(other) }) { selection = other }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func block<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

// MARK: - Small pieces (content inside the glass card uses fills, never more glass)

/// Grouped rows on a soft fill, like Maps' Recents box.
struct GroupBox16<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct Row: View {
    let title: String, subtitle: String, type: String
    var selected = false
    var onOpen: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            // A real button: works with VoiceOver, the keyboard and background clicks.
            Button(action: action) {
                HStack(spacing: 10) {
                    Avatar(name: title, type: type, size: 26, initials: type == "person" || type == "entity")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).lineLimit(1)
                        if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen?() })
            if let onOpen, hovering {
                Button(action: onOpen) { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).help("Open in Notes")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background((hovering || selected) ? RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(selected ? 0.09 : 0.05)) : nil)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint(onOpen != nil ? "Double-click to open in Notes" : "")
    }
}

extension View {
    /// Drawer scroll views: scroll only at full height (before that, scrolling grows the
    /// drawer), report whether they're at the top, fade content under the pinned header, and
    /// show overlay scrollers as the system decides.
    func drawerScroll(enabled: Bool, atTop: Binding<Bool>) -> some View {
        self
            .scrollDisabled(!enabled)
            // No scrollers in the drawer (Maps has none; with a mouse attached macOS draws thick
            // always-on bars that flicker as the drawer switches between growing and scrolling).
            .scrollIndicators(.never)
            .scrollEdgeEffectStyle(.soft, for: .top)
            // At the top means at its resting position, which sits above zero by the height of
            // whatever floats over the list (the search bar).
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top <= 1 } action: { _, top in atTop.wrappedValue = top }
    }
}

struct Chip: View {
    let text: String
    let count: Int?
    var tint: Color? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(text)
                if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassSurface(Capsule(), lit: hovering, tint: tint)
            .contentShape(Capsule())
        }
        .buttonStyle(SoftPressStyle())
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
    @State private var hovering = false
}

/// Content-layer buttons (cards, avatars, chips): a gentle dip while pressed.
struct SoftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

private struct HoverRaise: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .animation(.snappy(duration: 0.2), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Rises 2pt under the pointer, like a linked card.
    func hoverRaise() -> some View { modifier(HoverRaise()) }
}

/// A coloured circle (people) or rounded square (entities) with initials; a small type mark otherwise.
struct Avatar: View {
    let name: String
    let type: String
    let size: CGFloat
    var initials = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = Color(MeshTheme.make(dark: scheme == .dark).color(forType: type))
        // Like Maps' Home and Work icons: a lit gradient body with a bright upper rim.
        let body = LinearGradient(colors: [color.mix(with: .white, by: 0.22), color, color.mix(with: .black, by: 0.18)],
                                  startPoint: .top, endPoint: .bottom)
        let rim = LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.05), .white.opacity(0.2)],
                                 startPoint: .top, endPoint: .bottom)
        ZStack {
            if type == "entity" {
                let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                shape.fill(body).overlay(shape.strokeBorder(rim, lineWidth: 1))
                    .shadow(color: color.opacity(0.35), radius: size * 0.12, y: size * 0.06)
            } else if type == "person" {
                Circle().fill(body).overlay(Circle().strokeBorder(rim, lineWidth: 1))
                    .shadow(color: color.opacity(0.35), radius: size * 0.12, y: size * 0.06)
            } else {
                Circle().fill(.primary.opacity(0.07))
                Image(systemName: NoteTypes.symbol(type)).font(.system(size: size * 0.42)).foregroundStyle(.secondary)
            }
            if (type == "person" || type == "entity") && initials {
                Text(Self.initials(name)).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    static func initials(_ s: String) -> String {
        let words = s.split(whereSeparator: { !$0.isLetter }).prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
