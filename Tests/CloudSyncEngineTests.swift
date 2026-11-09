import CloudKit
import XCTest
@testable import ItsypadCore

final class CloudSyncEngineTests: XCTestCase {

    // MARK: - CloudTabRecord

    func testCloudTabRecordStoresAllFields() {
        let id = UUID()
        let date = Date()
        let record = CloudTabRecord(
            id: id,
            name: "Test tab",
            content: "hello world",
            language: "swift",
            languageLocked: true,
            lastModified: date
        )
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.name, "Test tab")
        XCTAssertEqual(record.content, "hello world")
        XCTAssertEqual(record.language, "swift")
        XCTAssertTrue(record.languageLocked)
        XCTAssertEqual(record.lastModified, date)
        XCTAssertNil(record.headVersionID)
    }

    // MARK: - ScratchTab record parsing

    private func scratchTabRecord(id: UUID, content: String, head: String?, name: String = "Remote") -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: CKRecordZone.ID(zoneName: "ItsypadData"))
        let record = CKRecord(recordType: CloudSyncEngine.RecordType.scratchTab.rawValue, recordID: recordID)
        record["name"] = name as CKRecordValue
        record["content"] = content as CKRecordValue
        record["language"] = "plain" as CKRecordValue
        record["languageLocked"] = 0 as CKRecordValue
        record["lastModified"] = Date() as CKRecordValue
        record["headVersionID"] = head.map { $0 as CKRecordValue }
        return record
    }

    func testTabRecordParsesHeadVersionID() {
        let id = UUID()
        let parsed = CloudSyncEngine.tabRecord(from: scratchTabRecord(id: id, content: "text", head: "abc"))
        XCTAssertEqual(parsed?.id, id)
        XCTAssertEqual(parsed?.content, "text")
        XCTAssertEqual(parsed?.headVersionID, "abc")
        XCTAssertNil(parsed?.deletedAt)
        XCTAssertNil(parsed?.deletedOn)
        XCTAssertNil(CloudSyncEngine.tabRecord(from: scratchTabRecord(id: id, content: "text", head: nil))?.headVersionID)
    }

    func testScratchTabRecordRoundTripKeepsFastForwardFromID() {
        let id = UUID()
        let tab = TabData(id: id, name: "Mine", content: "ours", headVersionID: "head", pendingFastForwardID: "parked")
        let record = scratchTabRecord(id: id, content: "", head: nil)
        CloudSyncEngine.fill(record, from: tab)
        XCTAssertEqual(record["fastForwardFromID"] as? String, "parked")

        let parsed = CloudSyncEngine.tabRecord(from: record)
        XCTAssertEqual(parsed?.content, "ours")
        XCTAssertEqual(parsed?.headVersionID, "head")
        XCTAssertEqual(parsed?.fastForwardFromID, "parked")

        CloudSyncEngine.fill(record, from: TabData(id: id, name: "Mine", content: "ours", headVersionID: "head"))
        XCTAssertNil(CloudSyncEngine.tabRecord(from: record)?.fastForwardFromID)
    }

    func testTabRecordParsesTombstone() {
        let record = scratchTabRecord(id: UUID(), content: "text", head: nil)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        record["deletedAt"] = when as CKRecordValue
        record["deletedOn"] = "Mac" as CKRecordValue
        let parsed = CloudSyncEngine.tabRecord(from: record)
        XCTAssertEqual(parsed?.deletedAt, when)
        XCTAssertEqual(parsed?.deletedOn, "Mac")
    }

    // MARK: - resolveTabConflict

    private func makeStore() -> (TabStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = TabStore(sessionURL: dir.appendingPathComponent("session.json"))
        let versionStore = VersionStore(baseURL: dir)
        versionStore.cloudHooks = VersionStore.CloudHooks(versionChanged: { _ in }, versionDeleted: { _ in })
        store.versionStore = versionStore
        store.versionSyncPolicy = { _ in false }
        store.historySettings = { (true, 200, 90) }
        return (store, dir)
    }

    func testResolveTabConflictMergesServerTextAndRePushesWhenItDiffers() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = CloudSyncEngine(directoryURL: dir)
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "a\nb\nc\nd")
        store.fireIdleTimer(id: tabID)
        let baseID = store.versionStore.latest(for: tabID)!.id
        store.updateContent(id: tabID, content: "A\nb\nc\nd")

        let local = scratchTabRecord(id: tabID, content: "A\nb\nc\nd", head: baseID)
        let server = scratchTabRecord(id: tabID, content: "a\nb\nc\nD", head: baseID)

        XCTAssertTrue(engine.resolveTabConflict(local: local, server: server, tabStore: store))
        XCTAssertEqual(store.tabs.first?.content, "A\nb\nc\nD")
        XCTAssertEqual(store.tabs.first?.name, "Remote")
        XCTAssertFalse(store.tabs.first!.hasConflict)

        // Server already has exactly our merged text: nothing to push back
        let settled = scratchTabRecord(id: tabID, content: "A\nb\nc\nD", head: store.tabs.first?.headVersionID)
        XCTAssertFalse(engine.resolveTabConflict(local: local, server: settled, tabStore: store))
        XCTAssertEqual(store.tabs.first?.content, "A\nb\nc\nD")
    }

    func testResolveTabConflictFindsBaseThroughSyncedRemoteVersion() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = CloudSyncEngine(directoryURL: dir)
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "a\nb\nc")
        store.fireIdleTimer(id: tabID)
        let baseID = store.versionStore.latest(for: tabID)!.id

        // The server descends from our base and edited the last line
        let theirs = TabVersion(tabID: tabID, parentID: baseID, device: "Mac", text: "a\nb\nC", source: .edit)
        store.versionStore.applyCloud(theirs)
        // We edited the first line meanwhile
        store.updateContent(id: tabID, content: "A\nb\nc")
        store.fireIdleTimer(id: tabID)

        let server = scratchTabRecord(id: tabID, content: theirs.text, head: theirs.id)
        let local = CKRecord(recordType: "ScratchTab", recordID: server.recordID)
        XCTAssertTrue(engine.resolveTabConflict(local: local, server: server, tabStore: store))
        XCTAssertEqual(store.tabs.first?.content, "A\nb\nC")
        XCTAssertFalse(store.tabs.first!.hasConflict)
    }

    func testResolveTabConflictKeepsLocalWhenServerHasNoHead() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = CloudSyncEngine(directoryURL: dir)
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "ours")
        store.fireIdleTimer(id: tabID)

        let server = scratchTabRecord(id: tabID, content: "theirs", head: nil)
        let local = CKRecord(recordType: "ScratchTab", recordID: server.recordID)
        XCTAssertTrue(engine.resolveTabConflict(local: local, server: server, tabStore: store))
        XCTAssertEqual(store.tabs.first?.content, "ours")
        XCTAssertTrue(store.tabs.first!.hasConflict)
        XCTAssertTrue(store.versionStore.versions(for: tabID).contains { $0.text == "theirs" && $0.source == .conflict })
    }

    func testResolveTabConflictDoesNotRePushWhenServerTextWins() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = CloudSyncEngine(directoryURL: dir)
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "base")
        store.fireIdleTimer(id: tabID)
        let localID = store.versionStore.latest(for: tabID)!.id

        let local = scratchTabRecord(id: tabID, content: "base", head: localID)
        let server = scratchTabRecord(id: tabID, content: "base and more", head: localID)

        XCTAssertFalse(engine.resolveTabConflict(local: local, server: server, tabStore: store))
        XCTAssertEqual(store.tabs.first?.content, "base and more")
    }

    func testResolveTabConflictKeepsLocalAndRePushesOnOverlap() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = CloudSyncEngine(directoryURL: dir)
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "a\nb")
        store.fireIdleTimer(id: tabID)
        let baseID = store.versionStore.latest(for: tabID)!.id
        store.updateContent(id: tabID, content: "a\nX")

        let local = scratchTabRecord(id: tabID, content: "a\nX", head: baseID)
        let server = scratchTabRecord(id: tabID, content: "a\nY", head: baseID)

        XCTAssertTrue(engine.resolveTabConflict(local: local, server: server, tabStore: store))
        XCTAssertEqual(store.tabs.first?.content, "a\nX")
        XCTAssertTrue(store.tabs.first!.hasConflict)
        XCTAssertTrue(store.versionStore.versions(for: tabID).contains { $0.text == "a\nY" && $0.source == .conflict })
    }

    func testResolveTabConflictAppliesServerTombstoneWithoutRePush() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = CloudSyncEngine(directoryURL: dir)
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "ours")

        let server = scratchTabRecord(id: tabID, content: "ours", head: nil)
        server["deletedAt"] = Date() as CKRecordValue
        server["deletedOn"] = "Mac" as CKRecordValue
        let local = CKRecord(recordType: "ScratchTab", recordID: server.recordID)
        XCTAssertFalse(engine.resolveTabConflict(local: local, server: server, tabStore: store))
        XCTAssertEqual(store.trashedTabs.map(\.id), [tabID])
        XCTAssertEqual(store.trashedTabs.first?.deletedOn, "Mac")
        XCTAssertFalse(store.tabs.contains { $0.id == tabID })
    }

    func testCloudTabRecordMutability() {
        var record = CloudTabRecord(
            id: UUID(),
            name: "Original",
            content: "original",
            language: "plain",
            languageLocked: false,
            lastModified: Date()
        )
        record.name = "Updated"
        record.content = "updated"
        record.language = "swift"
        record.languageLocked = true
        XCTAssertEqual(record.name, "Updated")
        XCTAssertEqual(record.content, "updated")
        XCTAssertEqual(record.language, "swift")
        XCTAssertTrue(record.languageLocked)
    }

    // MARK: - CloudClipboardRecord

    func testCloudClipboardRecordStoresAllFields() {
        let id = UUID()
        let date = Date()
        let record = CloudClipboardRecord(id: id, text: "clipboard text", timestamp: date)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.text, "clipboard text")
        XCTAssertEqual(record.timestamp, date)
    }

    func testCloudClipboardRecordMutability() {
        var record = CloudClipboardRecord(id: UUID(), text: "original", timestamp: Date())
        record.text = "updated"
        XCTAssertEqual(record.text, "updated")
    }

    // MARK: - RecordType

    func testRecordTypeRawValues() {
        XCTAssertEqual(CloudSyncEngine.RecordType.scratchTab.rawValue, "ScratchTab")
        XCTAssertEqual(CloudSyncEngine.RecordType.clipboardEntry.rawValue, "ClipboardEntry")
        XCTAssertEqual(CloudSyncEngine.RecordType.tabVersion.rawValue, "TabVersion")
    }
}
