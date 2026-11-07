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

    @Test func targetSlotFollowsTheDraggedTabsCentre() {
        #expect(TabReorder.targetSlot(centers: centers, dragged: 3, draggedCenter: 350) == 3)   // not moved
        #expect(TabReorder.targetSlot(centers: centers, dragged: 3, draggedCenter: 240) == 2)   // past tab 2's centre
        #expect(TabReorder.targetSlot(centers: centers, dragged: 3, draggedCenter: 10) == 0)
        #expect(TabReorder.targetSlot(centers: centers, dragged: 0, draggedCenter: 160) == 1)
        #expect(TabReorder.targetSlot(centers: centers, dragged: 0, draggedCenter: 140) == 0)   // not past yet
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
