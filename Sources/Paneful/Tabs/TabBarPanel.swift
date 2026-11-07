import AppKit
import SwiftUI

struct TabItem: Identifiable, Equatable {
    let id: Int          // index among the group's live windows
    let title: String
    let icon: NSImage?
    let isActive: Bool
}

@MainActor
final class TabBarModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    /// True while the user is working in this group. Other groups' bars are drawn slightly muted.
    @Published var isFocused = true
}

/// What the tab bar can ask the tab-group manager to do. Indices refer to `TabItem.id`.
struct TabBarActions {
    var select: @MainActor (Int) -> Void
    /// Tab dragged sideways from one position to another (both are positions among the tabs).
    var move: @MainActor (Int, Int) -> Void
    /// Take the window out of the group (and forget it there).
    var remove: @MainActor (Int) -> Void
    /// Close the window itself. The group still remembers it.
    var closeWindow: @MainActor (Int) -> Void
    /// Tab pulled out of the bar; the point is where the mouse was released (Cocoa coordinates).
    var tearOff: @MainActor (Int, CGPoint) -> Void
    var minimizeGroup: @MainActor () -> Void
    var ungroup: @MainActor () -> Void
}

/// The floating tab strip drawn just above a tab group's windows.
@MainActor
final class TabBarPanel {
    static let height: CGFloat = 32

    let model = TabBarModel()
    private let panel: NSPanel

    init(actions: TabBarActions) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false        // Paneful itself is never the active app
        panel.becomesKeyOnlyIfNeeded = true
        // Normal level, ordered directly above the group's visible window (see `show(above:)`), so the bar
        // stacks with its group: windows in front of the group also cover its bar, and every group's bar
        // can stay visible. No .canJoinAllSpaces: the bar lives on the Space where its group is.
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]

        let root = TabBarView(model: model, actions: actions) { [weak self] intent in
            self?.showDragHint(intent)
        }
        panel.contentView = FirstMouseHostingView(rootView: root)
    }

    /// Positions the bar using an AX-space rect.
    func setFrame(ax rect: CGRect) {
        let cocoa = Geometry.toCocoa(rect)
        if !panel.frame.isClose(to: cocoa, tolerance: 0.5) {
            panel.setFrame(cocoa, display: true)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// The bar's window-server number, to find it in CGWindowList.
    var windowNumber: Int { panel.windowNumber }

    /// Orders the bar directly above another app's window (its group's visible tab).
    func show(above windowID: CGWindowID) {
        panel.order(.above, relativeTo: Int(windowID))
    }

    func setFocused(_ focused: Bool) {
        if model.isFocused != focused { model.isFocused = focused }
    }

    func hide() {
        TabDragHint.shared.hide(owner: ObjectIdentifier(self))
        if panel.isVisible { panel.orderOut(nil) }
    }

    func close() {
        TabDragHint.shared.hide(owner: ObjectIdentifier(self))
        panel.orderOut(nil)
        panel.close()
    }

    /// Shows or hides the "what will letting go do" pill under this bar while a tab is dragged.
    private func showDragHint(_ intent: TabDragIntent?) {
        if let intent, panel.isVisible {
            TabDragHint.shared.show(intent, owner: ObjectIdentifier(self),
                                    barFrame: panel.frame, mouse: NSEvent.mouseLocation)
        } else {
            TabDragHint.shared.hide(owner: ObjectIdentifier(self))
        }
    }
}

/// Lets clicks land on the tab strip even though Paneful never becomes the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI

/// Where each tab sits in the strip, for working out which slot a dragged tab is over.
private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct TabBarView: View {
    /// How far (pt) a tab must be pulled up or down to take it out of the group. Well beyond the bar's
    /// own height, so a sideways drag that wanders a little still only reorders.
    static let pullOutDistance: CGFloat = 44
    private static let space = "tabStrip"

    @ObservedObject var model: TabBarModel
    let actions: TabBarActions
    let onDragIntent: @MainActor (TabDragIntent?) -> Void

    /// The tab being dragged: its starting position, the slot it's over, and whether it's pulled out.
    private struct Drag: Equatable {
        var from: Int
        var target: Int
        var pullingOut = false
        /// Released: gliding into its new slot before the order is committed.
        var settling = false
    }

    @State private var drag: Drag?
    /// Horizontal distance the dragged tab has moved. Kept apart from `drag` so following the cursor isn't
    /// animated while the other tabs' slide is.
    @State private var dragX: CGFloat = 0
    @State private var frames: [Int: CGRect] = [:]

    var body: some View {
        let order = visualOrder
        HStack(spacing: 0) {
            ForEach(model.tabs) { tab in
                if tab.id > 0 {
                    // Separator between neighbouring tabs; hidden next to the active or dragged tab, whose
                    // outline already marks its edges.
                    let left = order[tab.id - 1], right = order[tab.id]
                    let hidden = [left, right].contains { model.tabs[$0].isActive || $0 == drag?.from }
                    Rectangle()
                        .fill(Color.primary.opacity(hidden ? 0 : 0.2))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 2)
                }
                TabButton(tab: tab,
                          actions: actions,
                          isDragged: drag?.from == tab.id,
                          isPullingOut: drag?.from == tab.id && drag?.pullingOut == true,
                          anyDrag: drag != nil,
                          coordinateSpace: Self.space,
                          onDrag: { dragChanged(tab.id, $0) },
                          onDragEnd: { dragEnded(tab.id) })
                    .offset(x: offset(for: tab.id))
                    .zIndex(drag?.from == tab.id ? 1 : 0)
                    // Measured after .offset, so this is the tab's resting slot, not where it's drawn.
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: TabFramesKey.self,
                                               value: [tab.id: proxy.frame(in: .named(Self.space))])
                    })
            }
        }
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(TabFramesKey.self) { frames = $0 }
        .onChange(of: model.tabs.count) { cancelDrag() }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(model.isFocused ? 1 : 0.82)
    }

    // MARK: Dragging a tab

    /// Tab indices in the order they're drawn right now (the dragged tab already in its new slot).
    private var visualOrder: [Int] {
        guard let drag, !drag.pullingOut else { return Array(model.tabs.indices) }
        return TabReorder.visualOrder(count: model.tabs.count, from: drag.from, to: drag.target)
    }

    /// Distance between neighbouring tabs' left edges.
    private var pitch: CGFloat {
        guard let first = frames[0], let second = frames[1] else { return 0 }
        return second.minX - first.minX
    }

    private func offset(for id: Int) -> CGFloat {
        guard let drag else { return 0 }
        if id == drag.from { return dragX }
        if drag.pullingOut { return 0 }
        return CGFloat(TabReorder.slotShift(of: id, from: drag.from, to: drag.target)) * pitch
    }

    /// How far the dragged tab may slide: from the first slot to the last.
    private func clampedX(_ x: CGFloat, from: Int) -> CGFloat {
        guard let own = frames[from], let first = frames[0], let last = frames[model.tabs.count - 1] else { return x }
        return min(max(x, first.minX - own.minX), last.minX - own.minX)
    }

    private func dragChanged(_ id: Int, _ translation: CGSize) {
        if let drag, drag.from != id || drag.settling { return }
        guard model.tabs.indices.contains(id), let own = frames[id] else { return }

        var next = drag ?? Drag(from: id, target: id)
        next.pullingOut = abs(translation.height) > Self.pullOutDistance
        dragX = clampedX(translation.width, from: id)
        if !next.pullingOut {
            let centers = model.tabs.indices.map { frames[$0]?.midX ?? 0 }
            next.target = TabReorder.targetSlot(centers: centers, dragged: id, draggedCenter: own.midX + dragX)
        }
        if next != drag {
            // The other tabs slide aside to open a gap where the dragged tab will land.
            withAnimation(.easeOut(duration: 0.15)) { drag = next }
        }
        onDragIntent(next.pullingOut ? .pullOut : .reorder(moved: next.target != id))
    }

    private func dragEnded(_ id: Int) {
        guard let ended = drag, ended.from == id, !ended.settling else { return }
        onDragIntent(nil)

        if ended.pullingOut {
            withoutAnimation { drag = nil; dragX = 0 }
            actions.tearOff(id, NSEvent.mouseLocation)
            return
        }
        guard ended.target != ended.from,
              let own = frames[ended.from], let slot = frames[ended.target] else {
            withAnimation(.easeOut(duration: 0.15)) { drag = nil; dragX = 0 }   // back to where it was
            return
        }
        // Glide into the gap, then commit the new order. The bar is redrawn in the new order in the same
        // update that clears the offsets, so nothing jumps.
        let count = model.tabs.count
        drag?.settling = true
        withAnimation(.easeOut(duration: 0.12)) { dragX = slot.minX - own.minX }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            MainActor.assumeIsolated {
                guard drag?.settling == true else { return }
                withoutAnimation {
                    if model.tabs.count == count { actions.move(ended.from, ended.target) }
                    drag = nil
                    dragX = 0
                }
            }
        }
    }

    /// The tab list changed under the drag (a window closed or joined): drop the drag.
    private func cancelDrag() {
        guard drag != nil else { return }
        onDragIntent(nil)
        withoutAnimation { drag = nil; dragX = 0 }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}

private struct TabButton: View {
    let tab: TabItem
    let actions: TabBarActions
    let isDragged: Bool
    let isPullingOut: Bool
    /// Some tab in this bar is being dragged: hover effects are off until it's dropped.
    let anyDrag: Bool
    /// The strip's coordinate space. Drag distances are measured in it because it stays put while the
    /// dragged tab itself moves.
    let coordinateSpace: String
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon = tab.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(tab.title)
                .font(.system(size: 12, weight: tab.isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hovering && !anyDrag {
                Button { actions.remove(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Move out of group")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                // A dragged tab is lifted: opaque, so the tabs it passes over don't show through.
                if isDragged {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                }
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tab.isActive ? Color.accentColor.opacity(0.16)
                                       : ((hovering && !anyDrag) || isDragged ? Color.primary.opacity(0.06) : Color.clear))
            }
        )
        .overlay(
            // The active tab is outlined in the system accent colour (System Settings → Appearance).
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tab.isActive ? Color.accentColor : Color.primary.opacity(0.15),
                              lineWidth: tab.isActive ? 1.5 : (isDragged ? 1 : 0))
        )
        .contentShape(Rectangle())
        .opacity(isPullingOut ? 0.45 : 1)
        .onTapGesture { actions.select(tab.id) }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(coordinateSpace))
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDragEnd() }
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Move Out of Group") { actions.remove(tab.id) }
            Button("Close Window") { actions.closeWindow(tab.id) }
            Divider()
            Button("Minimize Group  ⌃⌥M") { actions.minimizeGroup() }
            Button("Ungroup All") { actions.ungroup() }
        }
        .help("\(tab.title)\nDrag sideways to reorder. Drag down to pull it out of the group.")
    }
}
