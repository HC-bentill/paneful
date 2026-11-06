import AppKit
import SwiftUI

struct TabItem: Identifiable, Equatable {
    let id: Int          // index in the group
    let title: String
    let icon: NSImage?
    let isActive: Bool
}

@MainActor
final class TabBarModel: ObservableObject {
    @Published var tabs: [TabItem] = []
}

/// The floating tab strip drawn just above a tab group's windows.
@MainActor
final class TabBarPanel {
    static let height: CGFloat = 32

    let model = TabBarModel()
    private let panel: NSPanel

    init(onSelect: @escaping @MainActor (Int) -> Void,
         onClose: @escaping @MainActor (Int) -> Void,
         onUngroup: @escaping @MainActor () -> Void) {
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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let root = TabBarView(model: model, onSelect: onSelect, onClose: onClose, onUngroup: onUngroup)
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

    func show() {
        if !panel.isVisible { panel.orderFrontRegardless() }
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
    let onSelect: @MainActor (Int) -> Void
    let onClose: @MainActor (Int) -> Void
    let onUngroup: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { tab in
                TabButton(tab: tab,
                          onSelect: { onSelect(tab.id) },
                          onClose: { onClose(tab.id) },
                          onUngroup: onUngroup)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TabButton: View {
    let tab: TabItem
    let onSelect: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    let onUngroup: @MainActor () -> Void
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
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Remove from group")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tab.isActive ? Color.primary.opacity(0.14)
                                   : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove from Group") { onClose() }
            Button("Ungroup All") { onUngroup() }
        }
        .help(tab.title)
    }
}
