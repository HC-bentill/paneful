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
    /// Take the window out of the group (and forget it there).
    var remove: @MainActor (Int) -> Void
    /// Close the window itself. The group still remembers it.
    var closeWindow: @MainActor (Int) -> Void
    /// Tab dragged out of the bar; the point is where the mouse was released (Cocoa coordinates).
    var tearOff: @MainActor (Int, CGPoint) -> Void
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

        let root = TabBarView(model: model, actions: actions)
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
        if panel.isVisible { panel.orderOut(nil) }
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

/// Lets clicks land on the tab strip even though Paneful never becomes the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI

struct TabBarView: View {
    @ObservedObject var model: TabBarModel
    let actions: TabBarActions

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.tabs) { tab in
                if tab.id > 0 {
                    // Separator between neighbouring tabs; hidden next to the active tab, whose outline
                    // already marks its edges.
                    let besideActive = tab.isActive || model.tabs[tab.id - 1].isActive
                    Rectangle()
                        .fill(Color.primary.opacity(besideActive ? 0 : 0.2))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 2)
                }
                TabButton(tab: tab, actions: actions)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(model.isFocused ? 1 : 0.82)
    }
}

private struct TabButton: View {
    /// How far (pt) a tab must be pulled up or down out of the strip to tear it off.
    static let tearOffDistance: CGFloat = 24

    let tab: TabItem
    let actions: TabBarActions
    @State private var hovering = false
    @GestureState private var dragOffset: CGSize = .zero

    private var tearingOff: Bool { abs(dragOffset.height) > Self.tearOffDistance }

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
            if hovering && dragOffset == .zero {
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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tab.isActive ? Color.accentColor.opacity(0.16)
                                   : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            // The active tab is outlined in the system accent colour (System Settings → Appearance).
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: tab.isActive ? 1.5 : 0)
        )
        .contentShape(Rectangle())
        .offset(x: dragOffset.width)
        .opacity(tearingOff ? 0.45 : 1)
        .onTapGesture { actions.select(tab.id) }
        .gesture(
            DragGesture(minimumDistance: 6)
                .updating($dragOffset) { value, state, _ in state = value.translation }
                .onEnded { value in
                    guard abs(value.translation.height) > Self.tearOffDistance else { return }
                    actions.tearOff(tab.id, NSEvent.mouseLocation)
                }
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Move Out of Group") { actions.remove(tab.id) }
            Button("Close Window") { actions.closeWindow(tab.id) }
            Divider()
            Button("Ungroup All") { actions.ungroup() }
        }
        .help(tab.title)
    }
}
