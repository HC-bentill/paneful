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
