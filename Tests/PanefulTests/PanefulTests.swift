import Foundation
import Testing
@testable import Paneful

@Suite("Snap zones")
struct SnapZoneTests {
    let visible = CGRect(x: 0, y: 0, width: 1001, height: 801)

    @Test func halvesCoverTheScreenWithoutGaps() {
        let left = SnapZone.leftHalf.rect(in: visible)
        let right = SnapZone.rightHalf.rect(in: visible)
        #expect(left.maxX == right.minX)
        #expect(left.width + right.width == visible.width)
        #expect(left.height == visible.height)
    }

    @Test func quartersTileTheScreen() {
        let quarters: [SnapZone] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let area = quarters.map { $0.rect(in: visible).area }.reduce(0, +)
        #expect(area == visible.area)
        // Cocoa coordinates: "top" has the larger y.
        #expect(SnapZone.topLeft.rect(in: visible).minY > SnapZone.bottomLeft.rect(in: visible).minY)
    }

    @Test func centerIsCentered() {
        let r = SnapZone.center.rect(in: visible)
        #expect(abs(r.midX - visible.midX) <= 0.5)
        #expect(abs(r.midY - visible.midY) <= 0.5)
    }
}

@Suite("Window matching")
struct TitleMatchTests {
    @Test func exactAndCaseInsensitive() {
        #expect(WindowSignature.titlesMatch("Downloads", "downloads "))
    }

    @Test func containment() {
        #expect(WindowSignature.titlesMatch("Report.pages — Edited", "Report.pages"))
    }

    @Test func shortOrEmptyTitlesDoNotMatchLoosely() {
        #expect(!WindowSignature.titlesMatch("", ""))
        #expect(!WindowSignature.titlesMatch("Doc", "Documents"))
        #expect(!WindowSignature.titlesMatch("Downloads", "Documents"))
    }
}

@Suite("Group store")
struct GroupStoreTests {
    @Test func storedGroupRoundTrips() throws {
        let group = StoredGroup(
            id: UUID(),
            members: [
                WindowSignature(bundleID: "com.brave.Browser", appName: "Brave Browser", titleHint: nil),
                WindowSignature(bundleID: "com.microsoft.teams2", appName: "Microsoft Teams",
                                titleHint: "Chat", titleChanges: 2),
            ],
            contentFrame: CGRect(x: 10, y: 57, width: 1200, height: 800))
        let data = try JSONEncoder().encode([group])
        let decoded = try JSONDecoder().decode([StoredGroup].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded[0].id == group.id)
        #expect(decoded[0].members == group.members)
        #expect(decoded[0].contentFrame == group.contentFrame)
    }
}

@Suite("Frame matching")
struct FrameMatchTests {
    @Test func roughlyAllowsSizeSlackButNotPositionDrift() {
        let target = CGRect(x: 60, y: 71, width: 1740, height: 1098)
        #expect(CGRect(x: 61, y: 72, width: 1730, height: 1090).isRoughly(target))   // size increments
        #expect(!CGRect(x: 60, y: 39, width: 1740, height: 1130).isRoughly(target))  // under the tab bar
        #expect(!CGRect(x: 90, y: 71, width: 1740, height: 1098).isRoughly(target))
    }
}

@Suite("Tab reordering")
struct TabReorderTests {
    // Four tabs, 100 pt apart.
    let centers: [CGFloat] = [50, 150, 250, 350]

    /// Where tab `index` would be if dragged by `dx` (tabs are 100 pt wide, 100 pt apart).
    func slot(_ index: Int, dx: CGFloat, centers: [CGFloat]? = nil) -> Int {
        let minX = CGFloat(index) * 100 + dx
        return TabReorder.targetSlot(centers: centers ?? self.centers, dragged: index,
                                     draggedMinX: minX, draggedMaxX: minX + 100)
    }

    @Test func targetSlotPassesANeighbourHalfwayAcrossIt() {
        #expect(slot(3, dx: 0) == 3)        // not moved
        #expect(slot(3, dx: -40) == 3)      // left edge not yet past tab 2's centre
        #expect(slot(3, dx: -60) == 2)      // past it
        #expect(slot(0, dx: 40) == 0)
        #expect(slot(0, dx: 60) == 1)
        #expect(slot(1, dx: -60) == 0)
    }

    @Test func endSlotsAreReachable() {
        // Slid as far as it can go: its edge sits exactly on the end tab's edge.
        #expect(slot(3, dx: -300) == 0)     // to the front
        #expect(slot(0, dx: 300) == 3)      // to the back
        #expect(slot(2, dx: -200) == 0)
        #expect(slot(1, dx: 200) == 3)
        // Tabs whose widths differ by a fraction of a point (pixel rounding) still reach both ends.
        let uneven: [CGFloat] = [49.75, 150.25, 249.5, 350.5]
        #expect(slot(3, dx: -300, centers: uneven) == 0)
        #expect(slot(0, dx: 300, centers: uneven) == 3)
    }

    @Test func otherTabsSlideAsideToOpenAGap() {
        // Last tab dragged to slot 1: tabs 1 and 2 move right, tab 0 stays.
        #expect((0..<4).map { TabReorder.slotShift(of: $0, from: 3, to: 1) } == [0, 1, 1, 0])
        // First tab dragged to slot 2: tabs 1 and 2 move left.
        #expect((0..<4).map { TabReorder.slotShift(of: $0, from: 0, to: 2) } == [0, -1, -1, 0])
        #expect((0..<4).map { TabReorder.slotShift(of: $0, from: 2, to: 2) } == [0, 0, 0, 0])
    }

    @Test func visualOrderPutsTheDraggedTabInItsSlot() {
        #expect(TabReorder.visualOrder(count: 4, from: 3, to: 1) == [0, 3, 1, 2])
        #expect(TabReorder.visualOrder(count: 4, from: 0, to: 3) == [1, 2, 3, 0])
    }

    @Test func movingLiveKeepsClosedMembersInPlace() {
        // Lower case = closed/minimized member (no tab). Tabs are A, B, C.
        let members = ["A", "x", "B", "C"]
        let live: (String) -> Bool = { $0 == $0.uppercased() }
        #expect(members.movingLive(from: 0, to: 2, isLive: live) == ["x", "B", "C", "A"])
        #expect(members.movingLive(from: 2, to: 0, isLive: live) == ["C", "A", "x", "B"])
        #expect(members.movingLive(from: 0, to: 1, isLive: live) == ["x", "B", "A", "C"])
        #expect(members.movingLive(from: 1, to: 1, isLive: live) == nil)
        #expect(members.movingLive(from: 0, to: 3, isLive: live) == nil)
    }
}


@Suite("Auto-tiling layout")
struct TileLayoutTests {
    let area = CGRect(x: 0, y: 40, width: 1000, height: 800)   // AX coordinates, below a menu bar

    @Test func oneTileFillsTheScreen() {
        #expect(TileLayout.frames(in: area, mainRatio: 0.5, weights: [1]) == [area])
        #expect(TileLayout.frames(in: area, mainRatio: 0.5, weights: []).isEmpty)
    }

    @Test func secondTileSplitsLeftAndRight() {
        let frames = TileLayout.frames(in: area, mainRatio: 0.5, weights: [1, 1])
        #expect(frames == [CGRect(x: 0, y: 40, width: 500, height: 800),
                           CGRect(x: 500, y: 40, width: 500, height: 800)])
    }

    @Test func moreTilesStackInTheRightColumn() {
        let frames = TileLayout.frames(in: area, mainRatio: 0.5, weights: [1, 1, 1, 1])
        #expect(frames.count == 4)
        #expect(frames[0] == CGRect(x: 0, y: 40, width: 500, height: 800))   // main tile untouched
        #expect(frames[1...].allSatisfy { $0.minX == 500 && $0.width == 500 })
        // Top to bottom, no gaps, filling the column exactly.
        #expect(frames[1].minY == 40)
        #expect(frames[1].maxY == frames[2].minY && frames[2].maxY == frames[3].minY)
        #expect(frames[3].maxY == area.maxY)
    }

    @Test func ratioIsClamped() {
        let frames = TileLayout.frames(in: area, mainRatio: 0.95, weights: [1, 1])
        #expect(frames[0].width == 800)
    }

    @Test func draggingTheMainTilesEdgeChangesTheRatio() {
        var main = CGRect(x: 0, y: 40, width: 600, height: 800)
        var result = TileLayout.resized(index: 0, to: main, in: area, mainRatio: 0.5, weights: [1, 1])
        #expect(abs(result.mainRatio - 0.6) < 0.001)
        // The stack tile's left edge is the same border.
        main = CGRect(x: 300, y: 40, width: 700, height: 800)
        result = TileLayout.resized(index: 1, to: main, in: area, mainRatio: 0.5, weights: [1, 1])
        #expect(abs(result.mainRatio - 0.3) < 0.001)
    }

    @Test func draggingABorderInTheStackResizesBothNeighbours() {
        // Three stack tiles of 266/267 pt. Drag the middle one's bottom edge down by 100 pt.
        let before = TileLayout.frames(in: area, mainRatio: 0.5, weights: [1, 1, 1, 1])
        var middle = before[2]
        middle.size.height += 100
        let result = TileLayout.resized(index: 2, to: middle, in: area, mainRatio: 0.5, weights: [1, 1, 1, 1])
        let after = TileLayout.frames(in: area, mainRatio: result.mainRatio, weights: result.weights)
        #expect(after[1] == before[1])                                  // the tile above is untouched
        #expect(abs(after[2].height - middle.height) <= 1)
        #expect(abs(after[3].height - (before[3].height - 100)) <= 1)   // the one below gave up the space
        #expect(after[3].maxY == area.maxY)
    }

    @Test func pointsFindTheirTile() {
        let frames = TileLayout.frames(in: area, mainRatio: 0.5, weights: [1, 1, 1])
        #expect(TileLayout.index(of: CGPoint(x: 100, y: 500), in: frames) == 0)
        #expect(TileLayout.index(of: CGPoint(x: 700, y: 100), in: frames) == 1)
        #expect(TileLayout.index(of: CGPoint(x: 700, y: 700), in: frames) == 2)
        #expect(TileLayout.index(of: CGPoint(x: 700, y: 10), in: frames) == nil)
    }
}
