import CoreGraphics

/// The arithmetic behind dragging a tab sideways to reorder it, like browser tabs.
/// Slots are tab positions in the bar, left to right.
enum TabReorder {
    /// The slot a dragged tab would drop into: the number of *other* tabs whose centre lies to the left
    /// of the dragged tab's centre.
    static func targetSlot(centers: [CGFloat], dragged: Int, draggedCenter: CGFloat) -> Int {
        var slot = 0
        for (index, center) in centers.enumerated() where index != dragged && center < draggedCenter {
            slot += 1
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
