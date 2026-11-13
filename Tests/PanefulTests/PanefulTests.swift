import ApplicationServices
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
        #expect(decoded[0].restoreFrame == nil)
    }

    @Test func filledGroupKeepsItsRestoreFrame() throws {
        var group = StoredGroup(
            id: UUID(),
            members: [WindowSignature(bundleID: "com.apple.finder", appName: "Finder", titleHint: nil)],
            contentFrame: CGRect(x: 60, y: 71, width: 1740, height: 1098))
        group.restoreFrame = CGRect(x: 200, y: 150, width: 1000, height: 700)
        let decoded = try JSONDecoder().decode([StoredGroup].self, from: JSONEncoder().encode([group]))
        #expect(decoded[0].restoreFrame == group.restoreFrame)
    }

    /// groups.json files written before "fill the screen" existed have no restoreFrame.
    @Test func olderFilesWithoutRestoreFrameStillLoad() throws {
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","contentFrame":[[10,57],[1200,800]],
          "members":[{"bundleID":"com.apple.finder","appName":"Finder","titleChanges":0}]}]
        """
        let decoded = try JSONDecoder().decode([StoredGroup].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].restoreFrame == nil)
        #expect(decoded[0].contentFrame == CGRect(x: 10, y: 57, width: 1200, height: 800))
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

@Suite("Saved layouts")
struct SavedLayoutTests {
    typealias W = LayoutMatcher.Window

    @Test func sameTitleWinsOverPosition() {
        let saved = [W(bundleID: "com.apple.finder", title: "Downloads", frame: CGRect(x: 0, y: 0, width: 500, height: 400)),
                     W(bundleID: "com.apple.finder", title: "Documents", frame: CGRect(x: 600, y: 0, width: 500, height: 400))]
        // Each open window sits where the *other* one was saved.
        let open = [W(bundleID: "com.apple.finder", title: "Documents", frame: CGRect(x: 0, y: 0, width: 500, height: 400)),
                    W(bundleID: "com.apple.finder", title: "downloads", frame: CGRect(x: 600, y: 0, width: 500, height: 400))]
        #expect(LayoutMatcher.match(saved: saved, open: open) == [1, 0])
    }

    @Test func similarTitleThenNearestWindow() {
        let saved = [W(bundleID: "com.apple.TextEdit", title: "Notes.txt", frame: nil),
                     W(bundleID: "com.brave.Browser", title: "GitHub", frame: CGRect(x: 800, y: 40, width: 600, height: 800))]
        let open = [W(bundleID: "com.brave.Browser", title: "Inbox", frame: CGRect(x: 0, y: 40, width: 600, height: 800)),
                    W(bundleID: "com.apple.TextEdit", title: "Notes.txt — Edited", frame: nil),
                    W(bundleID: "com.brave.Browser", title: "Hacker News", frame: CGRect(x: 790, y: 50, width: 600, height: 800))]
        #expect(LayoutMatcher.match(saved: saved, open: open) == [1, 2])
    }

    @Test func onlySameAppAndEachWindowOnce() {
        let saved = [W(bundleID: "a", title: "One", frame: nil), W(bundleID: "a", title: "Two", frame: nil),
                     W(bundleID: "b", title: "One", frame: nil)]
        let open = [W(bundleID: "a", title: "One", frame: nil)]
        #expect(LayoutMatcher.match(saved: saved, open: open) == [0, nil, nil])
    }

    @Test func sameDisplayKeepsTheFrameExactly() {
        let screen = CGRect(x: 0, y: 25, width: 1512, height: 919)
        let frame = CGRect(x: -20, y: 25, width: 800, height: 950)   // partly off screen on purpose
        #expect(LayoutGeometry.place(frame, savedScreen: screen, screens: [screen]) == frame)
    }

    @Test func otherDisplaySizeKeepsTheRelativePlace() {
        let big = CGRect(x: 0, y: 25, width: 2560, height: 1390)
        let laptop = CGRect(x: 0, y: 25, width: 1512, height: 919)
        let rightHalf = CGRect(x: 1280, y: 25, width: 1280, height: 1390)
        #expect(LayoutGeometry.place(rightHalf, savedScreen: big, screens: [laptop])
                == CGRect(x: 756, y: 25, width: 756, height: 919))
    }

    @Test func missingDisplayFallsBackToTheFirstOne() {
        let main = CGRect(x: 0, y: 25, width: 1512, height: 919)
        let gone = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
        let placed = LayoutGeometry.place(CGRect(x: 1600, y: 100, width: 900, height: 700), savedScreen: gone, screens: [main])
        #expect(main.contains(placed))
    }

    @Test func clampKeepsTheFrameOnScreen() {
        let screen = CGRect(x: 0, y: 25, width: 1000, height: 800)
        #expect(LayoutGeometry.clamp(CGRect(x: 900, y: -50, width: 300, height: 2000), to: screen)
                == CGRect(x: 700, y: 25, width: 300, height: 800))
    }

    @Test func summaryListsAppsFrontMostFirst() {
        func item(_ apps: String...) -> SavedLayout.Item {
            .init(windows: apps.map { .init(bundleID: $0, appName: $0, title: nil) }, frame: .zero, screen: .zero)
        }
        let layout = SavedLayout(number: 1, savedAt: Date(), items: [item("Safari", "Notes"), item("Safari"), item("Xcode"), item("Mail"), item("Music")])
        #expect(layout.summary == "Safari, Notes, Xcode +2")
        #expect(layout.windowCount == 6)
    }

    @Test func layoutsSurviveARoundTrip() throws {
        let layout = SavedLayout(number: 3, savedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                 items: [.init(windows: [.init(bundleID: "a", appName: "A", title: "T")],
                                               frame: CGRect(x: 1, y: 2, width: 3, height: 4),
                                               screen: CGRect(x: 0, y: 25, width: 10, height: 10), activeTab: 0)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(SavedLayout.self, from: encoder.encode(layout)) == layout)
    }
}

@Suite("Tab groups across desktops")
struct DesktopHomeTests {
    @Test func theDesktopWithMostWindowsWins() {
        // Two of three windows were dragged to desktop 2 in Mission Control: the group moves there.
        #expect(Spaces.home(of: [1, 2, 2], visibleTab: 1) == 2)
    }

    @Test func aTieKeepsTheVisibleTabsDesktop() {
        // One of two windows moved away: the group stays with its visible tab.
        #expect(Spaces.home(of: [1, 2], visibleTab: 1) == 1)
        #expect(Spaces.home(of: [1, 2], visibleTab: 2) == 2)
        // Two moved, two stayed: still where the visible tab is, so moving one by one doesn't flip early.
        #expect(Spaces.home(of: [1, 1, 2, 2], visibleTab: 1) == 1)
    }

    @Test func aTieWithoutAVisibleTabIsStable() {
        #expect(Spaces.home(of: [7, 3], visibleTab: nil) == 3)
        #expect(Spaces.home(of: [3, 7], visibleTab: 9) == 3)
    }

    @Test func noWindowsNoHome() {
        #expect(Spaces.home(of: [], visibleTab: 1) == nil)
    }
}

@Suite("Moving a tab group to another desktop")
@MainActor
struct DesktopMoveTests {
    /// Display A: Desktop 1 (4), Desktop 2 (8, on screen), a full-screen app (20), Desktop 3 (9).
    /// Display B: Desktop 4 (30, on screen), Desktop 5 (31).
    static let raw: [[String: Any]] = [
        ["Display Identifier": "A",
         "Current Space": ["ManagedSpaceID": NSNumber(value: 8), "uuid": "U8"],
         "Spaces": [
             ["ManagedSpaceID": NSNumber(value: 4), "uuid": "U4", "type": NSNumber(value: 0)],
             ["ManagedSpaceID": NSNumber(value: 8), "uuid": "U8", "type": NSNumber(value: 0)],
             ["ManagedSpaceID": NSNumber(value: 20), "uuid": "U20", "type": NSNumber(value: 4)],
             ["ManagedSpaceID": NSNumber(value: 9), "uuid": "U9", "type": NSNumber(value: 0)],
         ]],
        ["Display Identifier": "B",
         "Current Space": ["ManagedSpaceID": NSNumber(value: 30)],
         "Spaces": [
             ["ManagedSpaceID": NSNumber(value: 30), "uuid": "U30", "type": NSNumber(value: 0)],
             ["ManagedSpaceID": NSNumber(value: 31), "uuid": "U31", "type": NSNumber(value: 0)],
         ]],
    ]
    let layout = DesktopLayout(raw: DesktopMoveTests.raw)

    // MARK: Desktops

    @Test func layoutReadsDisplaysAndDesktops() {
        #expect(layout.displays.map(\.id) == ["A", "B"])
        #expect(layout.displays.map(\.current) == [8, 30])
        #expect(layout.space(20)?.isDesktop == false)
        #expect(layout.current(onDisplayOf: 31) == 30)
        #expect(layout.displayIndex(of: 9) == 0)
        #expect(layout.displayIndex(of: 99) == nil)
    }

    @Test func desktopsAreNumberedLikeMissionControl() {
        // Full-screen apps aren't numbered; the next display carries on counting.
        #expect([4, 8, 9, 30, 31].map { layout.desktopNumber(of: $0) } == [1, 2, 3, 4, 5])
        #expect(layout.desktopNumber(of: 20) == nil)
    }

    @Test func stepsCountEverySpaceOfTheSameDisplay() {
        // "Move right a space" also stops at full-screen apps.
        #expect(layout.steps(from: 4, to: 9) == 3)
        #expect(layout.steps(from: 9, to: 8) == -2)
        #expect(layout.steps(from: 8, to: 8) == 0)
        #expect(layout.steps(from: 8, to: 30) == nil)   // other display
        #expect(layout.steps(from: 8, to: 99) == nil)
    }

    @Test func savedDesktopsAreFoundByUUIDThenNumber() {
        #expect(layout.stored(9) == StoredDesktop(uuid: "U9", number: 3))
        #expect(layout.stored(20) == nil)   // a full-screen app's space isn't a group's desktop
        #expect(layout.space(matching: StoredDesktop(uuid: "U9", number: 1)) == 9)   // UUID wins
        #expect(layout.space(matching: StoredDesktop(uuid: "", number: 2)) == 8)
        #expect(layout.space(matching: StoredDesktop(uuid: "gone", number: 2)) == nil)
        #expect(layout.space(matching: StoredDesktop(uuid: "", number: 9)) == nil)
    }

    // MARK: Decisions

    @Test func aBarDraggedAwayIsToldApartFromWindowsMovingAway() {
        typealias Check = DesktopMovePlan.BarCheck
        #expect(DesktopMovePlan.barCheck(barSpace: 8, lastBarSpace: 8, home: 8) == Check.together)
        // The bar stayed on 8 and the windows went to 9: the bar follows them as usual.
        #expect(DesktopMovePlan.barCheck(barSpace: 8, lastBarSpace: 8, home: 9) == Check.windowsMoved)
        // A bar never seen with its windows hasn't been dragged anywhere.
        #expect(DesktopMovePlan.barCheck(barSpace: 8, lastBarSpace: nil, home: 9) == Check.windowsMoved)
        // The bar went from 8 to 9 while the windows stayed on 8: the group follows the bar.
        #expect(DesktopMovePlan.barCheck(barSpace: 9, lastBarSpace: 8, home: 8) == Check.barMoved(to: 9))
    }

    @Test func aGroupCanBeCarriedToAnyDesktopOfItsDisplay() {
        typealias Plan = DesktopMovePlan
        #expect(Plan.decide(home: 8, target: 9, layout: layout) == .carry)
        #expect(Plan.decide(home: 9, target: 4, layout: layout) == .carry)   // past a full-screen app
        #expect(Plan.decide(home: 8, target: 77, layout: layout) == .impossible(.desktopGone))
        #expect(Plan.decide(home: 8, target: 20, layout: layout) == .impossible(.fullScreenSpace))
        #expect(Plan.decide(home: 8, target: 31, layout: layout) == .impossible(.otherDisplay))
    }

    // MARK: Mission Control

    /// Checked on macOS 27.2: Desktop 2's button once the top row had opened.
    static let desktop2 = CGRect(x: 899, y: 101.5, width: 168.6, height: 129)

    @Test func windowsAreLetGoJustInsideTheTopOfADesktop() {
        typealias MC = MissionControlGeometry
        let first = MC.dropPoint(on: Self.desktop2, attempt: 0)
        let second = MC.dropPoint(on: Self.desktop2, attempt: 1)
        for point in [first, second] {
            #expect(Self.desktop2.contains(point))
            // The middle of the frame (where a drop made a full-screen space) is never used.
            #expect(point.y < Self.desktop2.minY + 20)
        }
        #expect(first != second)
    }

    @Test func dragsComeUpIntoTheTopRowFromBelow() {
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let below = MissionControlGeometry.approachPoint(under: Self.desktop2, display: display)
        #expect(below.x == Self.desktop2.midX)
        #expect(below.y > Self.desktop2.maxY)
        // The top row before it opens: still well below it.
        let closed = CGRect(x: 943.5, y: 5.5, width: 168.6, height: 129)
        #expect(MissionControlGeometry.approachPoint(under: closed, display: display).y > 200)
        // Never off the bottom of a short display.
        #expect(MissionControlGeometry.approachPoint(under: Self.desktop2, display: CGRect(x: 0, y: 0, width: 800, height: 300)).y <= 260)
    }

    @Test func theTopRowIsOpenOnceItsButtonsMoveDown() {
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        #expect(MissionControlGeometry.rowIsOpen(Self.desktop2, display: display))
        #expect(!MissionControlGeometry.rowIsOpen(CGRect(x: 943.5, y: 5.5, width: 168.6, height: 129), display: display))
        // A display below the main one: measured from its own top.
        let lower = CGRect(x: 0, y: 1169, width: 1800, height: 1169)
        #expect(!MissionControlGeometry.rowIsOpen(CGRect(x: 943.5, y: 1174.5, width: 168.6, height: 129), display: lower))
    }

    @Test func picturesSettleWhenTwoReadsAgree() {
        let a = CGRect(x: 10, y: 10, width: 200, height: 100)
        #expect(MissionControlGeometry.isSettled(a, a.offsetBy(dx: 0.5, dy: 0)))
        #expect(!MissionControlGeometry.isSettled(a, a.offsetBy(dx: 12, dy: 0)))
        #expect(!MissionControlGeometry.isSettled(a, nil))
    }

    @Test func theTopRowOfTheRightDisplayIsUsed() {
        let left = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let right = CGRect(x: 1800, y: 0, width: 2560, height: 1440)
        typealias MC = MissionControlGeometry
        #expect(MC.displayRow(frames: [left], counts: [4], bounds: nil, spaceCount: 4) == 0)
        #expect(MC.displayRow(frames: [left], counts: [3], bounds: nil, spaceCount: 4) == nil)
        #expect(MC.displayRow(frames: [left, right], counts: [4, 2], bounds: right, spaceCount: 2) == 1)
        // The display's bounds aren't known: the one row with the right number of spaces.
        #expect(MC.displayRow(frames: [left, right], counts: [4, 2], bounds: nil, spaceCount: 4) == 0)
        #expect(MC.displayRow(frames: [left, right], counts: [2, 2], bounds: nil, spaceCount: 2) == nil)
    }

    @Test func whereADroppedWindowEndedUp() {
        typealias MC = MissionControlGeometry
        #expect(MC.drop(space: 9, source: 8, target: 9, layout: layout) == .moved)
        #expect(MC.drop(space: 8, source: 8, target: 9, layout: layout) == .stayed)
        #expect(MC.drop(space: nil, source: 8, target: 9, layout: layout) == .unknown)
        #expect(MC.drop(space: 4, source: 8, target: 9, layout: layout) == .otherDesktop(4))
        // A full-screen app's space, or one so new the layout doesn't list it yet.
        #expect(MC.drop(space: 20, source: 8, target: 9, layout: layout) == .fullScreen(20))
        #expect(MC.drop(space: 47, source: 8, target: 9, layout: layout) == .fullScreen(47))
    }

    @Test func aWindowMovedAwayTakesTheGroupAlong() {
        // Code was dragged from desktop 8 to 9 in Mission Control: the group follows it.
        #expect(DesktopMovePlan.movedAway(["brave", "code"], before: ["brave": 8, "code": 8],
                                          now: ["brave": 8, "code": 9], home: 8) == "code")
        // Nothing moved, or no earlier look at the group: nothing to follow.
        #expect(DesktopMovePlan.movedAway(["brave", "code"], before: ["brave": 8, "code": 8],
                                          now: ["brave": 8, "code": 8], home: 8) == nil)
        #expect(DesktopMovePlan.movedAway(["code"], before: [:], now: ["code": 9], home: 8) == nil)
        #expect(DesktopMovePlan.movedAway(["code"], before: ["code": 8], now: ["code": 9], home: nil) == nil)
        // A window that was already elsewhere (left behind earlier) doesn't pull the group.
        #expect(DesktopMovePlan.movedAway(["brave"], before: ["brave": 4], now: ["brave": 9], home: 8) == nil)
        // macOS doesn't say where it is now (minimized, hidden): not a move.
        #expect(DesktopMovePlan.movedAway(["code"], before: ["code": 8], now: [:], home: 8) == nil)
    }

    @Test func theVisibleTabIsCarriedLast() {
        #expect(DesktopMovePlan.carryOrder(["a", "b", "c"], active: "a") == ["b", "c", "a"])
        #expect(DesktopMovePlan.carryOrder(["a", "b", "c"], active: nil) == ["a", "b", "c"])
    }

    // MARK: Group state

    static func window(_ pid: pid_t) -> AXWindow {
        AXWindow(element: AXUIElementCreateApplication(pid), pid: pid)
    }

    static func member(_ app: String, _ window: AXWindow?) -> TabGroup.Member {
        TabGroup.Member(signature: WindowSignature(bundleID: "test.\(app)", appName: app, titleHint: nil),
                        window: window)
    }

    @Test func awayTabsStayInTheBar() {
        var away = Self.member("Messages", Self.window(901))
        away.elsewhere = true
        var fullScreen = Self.member("Brave", Self.window(902))
        fullScreen.fullScreen = true
        var minimized = Self.member("Notes", Self.window(903))
        minimized.minimized = true
        let closed = Self.member("Mail", nil)
        let live = Self.member("Code", Self.window(904))
        let group = TabGroup(members: [away, fullScreen, minimized, closed, live], contentFrame: .zero)

        #expect(group.members.map(\.away) == [.otherDesktop, .fullScreen, nil, nil, nil])
        #expect(group.barMembers == [0, 1, 4])   // minimized and closed members have no tab
        #expect(group.windows.count == 1)
        #expect(group.keepsBar)                  // one window here + two away tabs
    }

    @Test func aGroupWithNoWindowHereLosesItsBar() {
        var a = Self.member("Messages", Self.window(911))
        a.elsewhere = true
        var b = Self.member("Code", Self.window(912))
        b.elsewhere = true
        #expect(!TabGroup(members: [a, b], contentFrame: .zero).keepsBar)
        let single = TabGroup(members: [Self.member("Code", Self.window(913)), Self.member("Mail", nil)],
                              contentFrame: .zero)
        #expect(!single.keepsBar)
    }

    @Test func afterAMoveWindowsLeftBehindAreAway() {
        let messages = Self.window(921), code = Self.window(922), brave = Self.window(923)
        var full = Self.member("Notes", Self.window(924))
        full.fullScreen = true
        var wasAway = Self.member("Brave", brave)
        wasAway.elsewhere = true
        let group = TabGroup(members: [Self.member("Messages", messages), Self.member("Code", code), wasAway, full],
                             contentFrame: .zero)
        // Messages refused to move; Code and the formerly away Brave window arrived on 9.
        let spaces: [AXWindow: UInt64] = [messages: 8, code: 9, brave: 9]
        let leftBehind = group.settle(on: 9) { spaces[$0] }
        #expect(leftBehind == ["Messages"])
        #expect(group.members.map(\.elsewhere) == [true, false, false, false])
        #expect(group.members.map(\.away) == [.otherDesktop, nil, nil, .fullScreen])
        #expect(group.windows == [code, brave])
    }

    @Test func reorderingCountsAwayTabs() {
        var away = Self.member("Messages", Self.window(931))
        away.elsewhere = true
        let members = [Self.member("Code", Self.window(932)), Self.member("Mail", nil), away]
        // Bar shows Code, Messages (away). Drag Messages to the front; closed Mail keeps its place.
        let moved = members.movingLive(from: 1, to: 0, isLive: \.isShownInBar)
        #expect(moved?.map(\.signature.appName) == ["Messages", "Code", "Mail"])
    }

    // MARK: Saving

    @Test func theGroupsDesktopIsSavedInGroupsJSON() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paneful-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = GroupStore(url: folder.appendingPathComponent("groups.json"))
        let group = TabGroup(members: [Self.member("Code", nil), Self.member("Messages", nil)],
                             contentFrame: CGRect(x: 0, y: 70, width: 900, height: 600),
                             desktop: StoredDesktop(uuid: "U9", number: 3))
        store.saveNow([group.stored])

        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("\"uuid\" : \"U9\""))
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].desktop == StoredDesktop(uuid: "U9", number: 3))
        #expect(loaded[0].members.map(\.appName) == ["Code", "Messages"])
    }

    /// groups.json files written before this feature have no desktop.
    @Test func olderFilesWithoutADesktopStillLoad() throws {
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","contentFrame":[[10,57],[1200,800]],
          "members":[{"bundleID":"com.apple.finder","appName":"Finder","titleChanges":0}]}]
        """
        let decoded = try JSONDecoder().decode([StoredGroup].self, from: Data(json.utf8))
        #expect(decoded[0].desktop == nil)
    }
}
