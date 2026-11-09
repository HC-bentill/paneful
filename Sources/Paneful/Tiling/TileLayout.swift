import CoreGraphics

/// The arithmetic of auto-tiling's "main + stack" layout. Everything is in AX coordinates (y grows down).
///
/// One tile fills the screen. With more, the first tile (the main one) takes the left part of the screen,
/// `mainRatio` of its width, and the others share the right column top to bottom, in proportion to their
/// weights. Weights are relative: only their ratios matter.
enum TileLayout {
    static let minRatio: CGFloat = 0.2
    static let maxRatio: CGFloat = 0.8
    /// The shortest a stack tile gets when the user drags a border between two of them.
    static let minStackHeight: CGFloat = 120

    static func frames(in area: CGRect, mainRatio: CGFloat, weights: [CGFloat]) -> [CGRect] {
        guard weights.count > 1 else { return weights.isEmpty ? [] : [area] }
        let ratio = min(max(mainRatio, minRatio), maxRatio)
        let mainWidth = (area.width * ratio).rounded()
        var frames = [CGRect(x: area.minX, y: area.minY, width: mainWidth, height: area.height)]

        let stack = weights.dropFirst().map { max($0, 0.01) }
        let total = stack.reduce(0, +)
        var y = area.minY
        for (index, weight) in stack.enumerated() {
            let isLast = index == stack.count - 1
            let height = isLast ? area.maxY - y : (area.height * weight / total).rounded()
            frames.append(CGRect(x: area.minX + mainWidth, y: y, width: area.width - mainWidth, height: height))
            y += height
        }
        return frames
    }

    /// The user dragged an edge of tile `index` so that it now has `frame`. Returns the main ratio and
    /// weights that give it that size, moving only the border that was dragged (its neighbour on the other
    /// side of that border grows or shrinks to match).
    static func resized(index: Int, to frame: CGRect, in area: CGRect,
                        mainRatio: CGFloat, weights: [CGFloat]) -> (mainRatio: CGFloat, weights: [CGFloat]) {
        let current = frames(in: area, mainRatio: mainRatio, weights: weights)
        guard current.count > 1, current.indices.contains(index), area.width > 0 else { return (mainRatio, weights) }
        let old = current[index]
        let slack: CGFloat = 4
        func clampRatio(_ r: CGFloat) -> CGFloat { min(max(r, minRatio), maxRatio) }

        if index == 0 {
            // The main tile's right edge is the border with the stack.
            return (clampRatio((frame.maxX - area.minX) / area.width), weights)
        }
        if abs(frame.minX - old.minX) > slack {
            // A stack tile's left edge is the border with the main tile.
            return (clampRatio((frame.minX - area.minX) / area.width), weights)
        }

        // Borders between stack tiles. Work in heights (points); they're valid weights as they are.
        var heights = current.map(\.height)
        let first = 1, last = current.count - 1
        if abs(frame.minY - old.minY) > slack, index > first {
            // Top edge: shared with the tile above.
            let pair = heights[index - 1] + heights[index]
            let newHeight = min(max(old.maxY - frame.minY, minStackHeight), pair - minStackHeight)
            heights[index - 1] = pair - newHeight
            heights[index] = newHeight
        } else if abs(frame.maxY - old.maxY) > slack, index < last {
            // Bottom edge: shared with the tile below.
            let pair = heights[index] + heights[index + 1]
            let newHeight = min(max(frame.maxY - old.minY, minStackHeight), pair - minStackHeight)
            heights[index] = newHeight
            heights[index + 1] = pair - newHeight
        } else {
            return (mainRatio, weights)
        }
        heights[0] = weights.first ?? 1   // the main tile's weight isn't used
        return (mainRatio, heights)
    }

    /// Which of `frames` contains `point`, if any.
    static func index(of point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }
}
