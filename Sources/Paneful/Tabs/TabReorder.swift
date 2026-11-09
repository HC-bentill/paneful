import CoreGraphics

/// The arithmetic behind dragging a tab sideways to reorder it, like browser tabs.
/// Slots are tab positions in the bar, left to right.
enum TabReorder {
    /// The slot a dragged tab would drop into, given where its left and right edges are now.
    ///
    /// Like browser tabs, the dragged tab passes a neighbour once its leading edge crosses that neighbour's
    /// centre: a tab on the left is passed when the dragged tab's left edge goes past its centre, a tab on
    /// the right when the dragged tab's right edge does. The dragged tab can slide as far as the first or
    /// last slot, which puts that edge half a tab past the end tab's centre, so both ends are reachable even
    /// when tab widths differ by a fraction of a point. (Comparing centres made the end slots a tie that
    /// rounding often lost.)
    static func targetSlot(centers: [CGFloat], dragged: Int, draggedMinX: CGFloat, draggedMaxX: CGFloat) -> Int {
        var slot = 0
        for (index, center) in centers.enumerated() where index != dragged {
            if index < dragged ? center <= draggedMinX : center < draggedMaxX {
                slot += 1
            }
        }
        return slot
    }

    /// How many slots tab `index` moves aside while tab `from` is held over slot `to` (-1, 0 or +1).
    static func slotShift(of index: Int, from: Int, to: Int) -> Int {
        if from < to, index > from, index <= to { return -1 }
        if to < from, index >= to, index < from { return 1 }
        return 0
    }

    /// The tabs in the order they appear while tab `from` is held over slot `to`.
    static func visualOrder(count: Int, from: Int, to: Int) -> [Int] {
        var order = Array(0..<count)
        guard order.indices.contains(from), order.indices.contains(to) else { return order }
        order.remove(at: from)
        order.insert(from, at: to)
        return order
    }
}

extension Array {
    /// Moves the `from`-th element that `isLive` accepts so that it becomes the `to`-th such element.
    /// Every other element, live or not, keeps its relative order. Returns nil if an index is out of range
    /// or nothing would change.
    ///
    /// Tab groups use this because their tabs are only the live members: closed or minimized members
    /// keep their place in the remembered order but have no tab.
    func movingLive(from: Int, to: Int, isLive: (Element) -> Bool) -> [Element]? {
        let live = indices.filter { isLive(self[$0]) }
        guard from != to, live.indices.contains(from), live.indices.contains(to) else { return nil }
        var result = self
        let moved = result.remove(at: live[from])
        let remaining = result.indices.filter { isLive(result[$0]) }
        let insertAt = to < remaining.count ? remaining[to] : (remaining.last.map { $0 + 1 } ?? result.count)
        result.insert(moved, at: insertAt)
        return result
    }
}
