import XCTest
@testable import ItsypadCore

/// Records what the store would have queued for CloudKit.
final class VersionHookLog {
    var changed: [String] = []
    var deleted: [String] = []

    var hooks: VersionStore.CloudHooks {
        VersionStore.CloudHooks(
            versionChanged: { [unowned self] in self.changed.append($0) },
            versionDeleted: { [unowned self] in self.deleted.append($0) }
        )
    }
}

final class VersionStoreTests: XCTestCase {
    private var baseURL: URL!
    private var store: VersionStore!
    private var log: VersionHookLog!
    private let tabA = UUID()
    private let tabB = UUID()
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        log = VersionHookLog()
        store = VersionStore(baseURL: baseURL)
        store.cloudHooks = log.hooks
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: baseURL)
        store = nil
        super.tearDown()
    }

    private func version(
        _ text: String,
        tab: UUID? = nil,
        parent: String? = nil,
        at: Date? = nil,
        label: String? = nil,
        source: TabVersion.Source = .edit
    ) -> TabVersion {
        TabVersion(
            tabID: tab ?? tabA,
            parentID: parent,
            createdAt: at ?? noon,
            device: "Test device",
            label: label,
            text: text,
            source: source
        )
    }

    // MARK: - Identity

    func testIDIsStableForSameTabAndText() {
        let a = TabVersion.makeID(tabID: tabA, text: "hello")
        let b = TabVersion.makeID(tabID: tabA, text: "hello")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a, a.lowercased())
        XCTAssertEqual(version("hello").id, a)
    }

    func testIDIsScopedPerTab() {
        XCTAssertNotEqual(TabVersion.makeID(tabID: tabA, text: "same"), TabVersion.makeID(tabID: tabB, text: "same"))
        XCTAssertNotEqual(TabVersion.makeID(tabID: tabA, text: "a"), TabVersion.makeID(tabID: tabA, text: "b"))
    }

    // MARK: - Append / dedupe / ordering

    func testAppendDedupesByID() {
        XCTAssertTrue(store.append(version("one")))
        XCTAssertFalse(store.append(version("one", at: noon.addingTimeInterval(60))))
        XCTAssertEqual(store.versions(for: tabA).count, 1)
    }

    func testAppendQueuesCloudChangeOnlyWhenSyncable() {
        store.append(version("one"))
        XCTAssertTrue(log.changed.isEmpty)
        let v = version("two")
        store.append(v, syncable: true)
        XCTAssertEqual(log.changed, [v.id])
    }

    func testParentChainAndNewestFirst() {
        let first = version("a", at: noon)
        store.append(first)
        let second = version("ab", parent: store.latest(for: tabA)?.id, at: noon.addingTimeInterval(10))
        store.append(second)
        let third = version("abc", parent: store.latest(for: tabA)?.id, at: noon.addingTimeInterval(20))
        store.append(third)

        let list = store.versions(for: tabA)
        XCTAssertEqual(list.map(\.text), ["abc", "ab", "a"])
        XCTAssertNil(first.parentID)
        XCTAssertEqual(second.parentID, first.id)
        XCTAssertEqual(third.parentID, second.id)
        XCTAssertEqual(store.latest(for: tabA)?.id, third.id)
        XCTAssertTrue(store.versions(for: tabB).isEmpty)
    }

    func testChangeCounterBumpsOnMutation() {
        let before = store.changeCounter
        store.append(version("x"))
        XCTAssertGreaterThan(store.changeCounter, before)
    }

    // MARK: - Persistence

    func testPersistenceRoundTrip() {
        store.append(version("persisted", label: "Keep"))
        store.append(version("again", at: noon.addingTimeInterval(5)))

        let reopened = VersionStore(baseURL: baseURL)
        let list = reopened.versions(for: tabA)
        XCTAssertEqual(list.map(\.text), ["again", "persisted"])
        XCTAssertEqual(list.last?.label, "Keep")
        XCTAssertEqual(list.last?.device, "Test device")
        XCTAssertEqual(list.last?.source, .edit)
    }

    func testCorruptFileIsBackedUp() throws {
        let dir = baseURL.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(tabA.uuidString).appendingPathExtension("json")
        let garbage = Data("{{not json".utf8)
        try garbage.write(to: file)

        let reopened = VersionStore(baseURL: baseURL)
        XCTAssertTrue(reopened.versions(for: tabA).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("bak")), garbage)

        reopened.append(version("fresh"))
        XCTAssertEqual(VersionStore(baseURL: baseURL).versions(for: tabA).count, 1)
    }

    func testVersionWithIDResolvesAcrossStoresViaIndex() {
        let v = version("find me", tab: tabB)
        store.append(v)

        let reopened = VersionStore(baseURL: baseURL)
        XCTAssertEqual(reopened.version(withID: v.id)?.tabID, tabB)
        XCTAssertNil(reopened.version(withID: "nope"))
    }

    func testVersionWithIDRebuildsMissingIndex() throws {
        let v = version("indexed")
        store.append(v)
        try? FileManager.default.removeItem(at: baseURL.appendingPathComponent("versions/index.json"))

        let reopened = VersionStore(baseURL: baseURL)
        XCTAssertEqual(reopened.version(withID: v.id)?.text, "indexed")
    }

    // MARK: - Label / delete

    func testSetLabelUpdatesAndQueuesCloud() {
        let v = version("label me")
        store.append(v)
        store.setLabel("  Draft 1 ", versionID: v.id, tabID: tabA, syncable: true)
        XCTAssertEqual(store.versions(for: tabA).first?.label, "Draft 1")
        XCTAssertEqual(log.changed, [v.id])

        store.setLabel("", versionID: v.id, tabID: tabA)
        XCTAssertNil(store.versions(for: tabA).first?.label)
    }

    func testDeleteAndDeleteAllQueueCloudDeletes() {
        let a = version("a")
        let b = version("b", at: noon.addingTimeInterval(1))
        let c = version("c", at: noon.addingTimeInterval(2))
        store.append(a)
        store.append(b)
        store.append(c)

        store.delete(versionID: b.id, tabID: tabA, syncable: true)
        XCTAssertEqual(store.versions(for: tabA).map(\.id), [c.id, a.id])
        XCTAssertEqual(log.deleted, [b.id])

        store.deleteAll(tabID: tabA, syncable: true)
        XCTAssertTrue(store.versions(for: tabA).isEmpty)
        XCTAssertEqual(Set(log.deleted), [a.id, b.id, c.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseURL.appendingPathComponent("versions/\(tabA.uuidString).json").path))
    }

    // MARK: - Cloud apply

    func testApplyCloudInsertsWithoutReupload() {
        let v = version("from cloud", source: .paste)
        store.applyCloud(v)
        XCTAssertEqual(store.versions(for: tabA).first, v)
        XCTAssertTrue(log.changed.isEmpty)
    }

    func testApplyCloudDedupesAndNewerLabelWins() {
        let local = version("shared text")
        store.append(local)
        var cloud = version("shared text", at: noon.addingTimeInterval(99))
        cloud.label = "Named on Mac"
        store.applyCloud(cloud)

        let list = store.versions(for: tabA)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.label, "Named on Mac")
        XCTAssertEqual(list.first?.createdAt, noon)

        store.applyCloud(version("shared text"))
        XCTAssertEqual(store.versions(for: tabA).first?.label, "Named on Mac")
        XCTAssertTrue(log.changed.isEmpty)
    }

    func testRemoveCloudWithAndWithoutTabID() {
        let a = version("a")
        let b = version("b", at: noon.addingTimeInterval(1))
        store.append(a)
        store.append(b)

        store.removeCloud(versionID: a.id, tabID: tabA)
        XCTAssertEqual(store.versions(for: tabA).map(\.id), [b.id])
        store.removeCloud(versionID: b.id)
        XCTAssertTrue(store.versions(for: tabA).isEmpty)
        XCTAssertTrue(log.deleted.isEmpty)
    }

    // MARK: - Prune policy

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testPruneKeepsEverythingFromLastHour() {
        let versions = (0..<30).map { i in
            version("v\(i)", at: noon.addingTimeInterval(-Double(i) * 60))
        }
        XCTAssertTrue(VersionPrunePolicy.idsToDrop(versions: versions, now: noon, calendar: utc).isEmpty)
    }

    func testPruneKeepsOnePerTenMinuteBucketBetweenOneAndTwentyFourHours() {
        // Three versions inside the same 10-minute bucket, 2 h ago, plus
        // first/latest anchors
        let first = version("first", at: noon.addingTimeInterval(-20 * 3600))
        let b1 = version("b1", at: noon.addingTimeInterval(-7200 - 60))
        let b2 = version("b2", at: noon.addingTimeInterval(-7200 - 180))
        let b3 = version("b3", at: noon.addingTimeInterval(-7200 - 300))
        let other = version("other", at: noon.addingTimeInterval(-3 * 3600))
        let latest = version("latest", at: noon)

        let drop = VersionPrunePolicy.idsToDrop(versions: [first, b1, b2, b3, other, latest], now: noon, calendar: utc)
        XCTAssertEqual(Set(drop), [b2.id, b3.id])
    }

    func testPruneKeepsOnePerCalendarDayBeyondTwentyFourHours() {
        let day = 86_400.0
        let first = version("first", at: noon.addingTimeInterval(-10 * day))
        let d3a = version("d3a", at: noon.addingTimeInterval(-3 * day - 3600))
        let d3b = version("d3b", at: noon.addingTimeInterval(-3 * day))
        let d3c = version("d3c", at: noon.addingTimeInterval(-3 * day + 3600))
        let d2 = version("d2", at: noon.addingTimeInterval(-2 * day))
        let latest = version("latest", at: noon)

        let drop = VersionPrunePolicy.idsToDrop(versions: [first, d3a, d3b, d3c, d2, latest], now: noon, calendar: utc)
        XCTAssertEqual(Set(drop), [d3a.id, d3b.id])
    }

    func testPruneNeverDropsFirstLatestOrLabelled() {
        let day = 86_400.0
        let first = version("first", at: noon.addingTimeInterval(-5 * day - 7200))
        let labelled = version("labelled", at: noon.addingTimeInterval(-5 * day - 3600), label: "Keep")
        let plain = version("plain", at: noon.addingTimeInterval(-5 * day))
        let latest = version("latest", at: noon.addingTimeInterval(-5 * day + 3600))

        let drop = VersionPrunePolicy.idsToDrop(versions: [first, labelled, plain, latest], now: noon, calendar: utc)
        XCTAssertEqual(drop, [plain.id])
    }

    func testPruneHardCapDropsOldestUnprotected() {
        // 250 versions one second apart, all within the last hour, so only
        // the cap applies; the first and the latest survive
        let versions = (0..<250).map { i in
            version("v\(i)", at: noon.addingTimeInterval(-Double(249 - i)))
        }
        let drop = VersionPrunePolicy.idsToDrop(versions: versions, now: noon, calendar: utc)
        XCTAssertEqual(drop.count, 50)
        XCTAssertFalse(drop.contains(versions.first!.id))
        XCTAssertFalse(drop.contains(versions.last!.id))
        XCTAssertEqual(Set(drop), Set(versions[1...50].map(\.id)))
    }

    func testPruneOnStoreDeletesLocallyAndQueuesCloud() {
        let day = 86_400.0
        let first = version("first", at: noon.addingTimeInterval(-6 * day))
        let dupA = version("dupA", at: noon.addingTimeInterval(-3 * day))
        let dupB = version("dupB", at: noon.addingTimeInterval(-3 * day + 60))
        let latest = version("latest", at: noon)
        for v in [first, dupA, dupB, latest] { store.append(v) }

        store.prune(tabID: tabA, now: noon, syncable: true)
        XCTAssertEqual(Set(store.versions(for: tabA).map(\.id)), [first.id, dupB.id, latest.id])
        XCTAssertEqual(log.deleted, [dupA.id])
    }
}
