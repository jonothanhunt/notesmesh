import SwiftUI
import AppKit

/// What the cursor is over in the graph, for the native glass hover card.
struct GraphHover: Equatable {
    let id: String, label: String, category: String, group: String, snippet: String
    let links: Int
    let point: CGPoint   // in the graph view's coordinates (points, top-left origin), just under the node
}

/// One island (a community of notes) for the drawer: its name, members and a mini map.
struct IslandSummary: Identifiable, Equatable {
    let id: Int
    let title: String
    let noteIDs: [String]
    let points: [CGPoint]      // member positions normalised to 0…1
    let types: [String]        // member types, for colouring the mini map
    var count: Int { noteIDs.count }
    var people: Int { types.filter { $0 == "person" }.count }
}

/// An island's name, floated as a glass pill over the graph when zoomed far out.
struct IslandPill: Identifiable, Equatable {
    let id: Int
    let title: String
    let count: Int
    let point: CGPoint       // view points, top-left origin
    let opacity: Double
}

/// Owns the native Metal graph view and connects it to SwiftUI.
@MainActor
final class GraphController: ObservableObject {
    let view = MetalGraphView()
    lazy var container = GraphContainerView(graph: view)
    var onSelect: ((String?) -> Void)?
    var onOpen: ((String) -> Void)?
    var onPress: (() -> Void)?
    @Published var hover: GraphHover?
    @Published var typeCounts: [String: Int] = [:]
    @Published var typeFilter: String?
    @Published var islands: [IslandSummary] = []
    var onPillClick: ((Int) -> Void)?
    @Published var pills: [IslandPill] = []

    init() {
        view.onSelect = { [weak self] in self?.onSelect?($0) }
        view.onOpen = { [weak self] in self?.onOpen?($0) }
        view.onPress = { [weak self] in self?.onPress?() }
        view.onHover = { [weak self] h in if self?.hover != h { self?.hover = h } }
        view.onIslands = { [weak self] list in if self?.islands != list { self?.islands = list } }
        view.onPillClick = { [weak self] id in self?.onPillClick?(id) }
        view.onPills = { [weak self] list in if self?.pills != list { self?.pills = list } }
        view.onTypes = { [weak self] counts, filter in
            self?.typeCounts = counts
            self?.typeFilter = filter
        }
    }

    func setData(_ payload: GraphPayload) { view.setData(payload) }
    func setLayers(_ layers: [String: Bool]) { view.setLayers(layers) }
    func setSimilar(_ k: Int) { view.setSimilar(k) }
    func setQuery(_ q: String) { view.setQuery(q) }
    func focus(_ id: String?) {
        if let id, id.hasPrefix("island:"), let n = Int(id.dropFirst(7)), let island = islands.first(where: { $0.id == n }) {
            view.focusIsland(Set(island.noteIDs))
        } else {
            view.focusIsland(nil)
            view.focusNode(id)
        }
    }
    func fit() { view.fit() }
    func zoom(by factor: Double) { view.zoomCentre(by: factor) }
    func setClustering(islands: Bool, folders: Bool) { view.setClustering(islands: islands, folders: folders) }
    func setTypeFilter(_ t: String?) { view.setTypeFilter(t) }
    func setInsets(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        view.setInsets(NSEdgeInsets(top: top, left: left, bottom: bottom, right: right))
    }
}

struct GraphCanvas: NSViewRepresentable {
    let controller: GraphController
    func makeNSView(context: Context) -> GraphContainerView { controller.container }
    func updateNSView(_ nsView: GraphContainerView, context: Context) {}
}
