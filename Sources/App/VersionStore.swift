import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct TabVersion: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case edit, paste, conflict, manual, restore }

    let id: String
    let tabID: UUID
    let parentID: String?
    let createdAt: Date
    let device: String
    var label: String?
    let text: String
    let source: Source

    init(
        id: String? = nil,
        tabID: UUID,
        parentID: String?,
        createdAt: Date = Date(),
        device: String = TabVersion.currentDeviceName,
        label: String? = nil,
        text: String,
        source: Source
    ) {
        self.id = id ?? TabVersion.makeID(tabID: tabID, text: text)
        self.tabID = tabID
        self.parentID = parentID
        self.createdAt = createdAt
        self.device = device
        self.label = label
        self.text = text
        self.source = source
    }

    /// Content-addressed per tab: identical text in the same tab is the same
    /// version on every device, which is what makes cloud dedupe trivial.
    static func makeID(tabID: UUID, text: String) -> String {
        let digest = SHA256.hash(data: Data((tabID.uuidString + "\n" + text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static var currentDeviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}

struct VersionPrunePolicy {
    static let hardCap = 200

    /// Keep everything from the last hour, one per 10-minute bucket between
    /// 1 h and 24 h, one per calendar day beyond that, at most `hardCap`.
    /// The first, the latest and every labelled version are never dropped.
    /// `keepCount` and `keepDays` of 0 mean unlimited.
    static func idsToDrop(
        versions: [TabVersion],
        now: Date,
        keepCount: Int = hardCap,
        keepDays: Int = 0,
        calendar: Calendar = .current
    ) -> [String] {
        let ordered = versions.sorted { $0.createdAt < $1.createdAt }
        guard ordered.count > 2 else { return [] }

        var protected = Set<String>()
        protected.insert(ordered.first!.id)
        protected.insert(ordered.last!.id)
        for v in ordered where v.label?.isEmpty == false {
            protected.insert(v.id)
        }

        var drop = Set<String>()
        var seenBuckets = Set<String>()
        // Newest first so the survivor of each bucket is its newest version
        for v in ordered.reversed() {
            let age = now.timeIntervalSince(v.createdAt)
            let bucket: String?
            if age < 3600 {
                bucket = nil
            } else if age < 86_400 {
                bucket = "m\(Int(age / 600))"
            } else {
                let day = calendar.dateComponents([.year, .month, .day], from: v.createdAt)
                bucket = "d\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
            }
            guard let bucket else { continue }
            if seenBuckets.contains(bucket) {
                if !protected.contains(v.id) {
                    drop.insert(v.id)
                }
            } else {
                seenBuckets.insert(bucket)
            }
        }

        if keepDays > 0 {
            let cutoff = TimeInterval(keepDays) * 86_400
            for v in ordered where now.timeIntervalSince(v.createdAt) > cutoff && !protected.contains(v.id) {
                drop.insert(v.id)
            }
        }

        var remaining = ordered.count - drop.count
        if keepCount > 0, remaining > keepCount {
            for v in ordered where remaining > keepCount && !drop.contains(v.id) && !protected.contains(v.id) {
                drop.insert(v.id)
                remaining -= 1
            }
        }

        return ordered.map(\.id).filter { drop.contains($0) }
    }
}

final class VersionStore: ObservableObject {
    static let shared = VersionStore()

    struct CloudHooks {
        var versionChanged: (String) -> Void
        var versionDeleted: (String) -> Void

        static let cloudKit = CloudHooks(
            versionChanged: { CloudSyncEngine.shared.versionChanged($0) },
            versionDeleted: { CloudSyncEngine.shared.versionDeleted($0) }
        )
    }

    @Published private(set) var changeCounter = 0

    var cloudHooks: CloudHooks = .cloudKit

    private let directoryURL: URL
    /// Newest first, per tab. Loaded lazily from disk.
    private var cache: [UUID: [TabVersion]] = [:]
    /// Version id → tab id, so a CloudKit record name can be resolved without
    /// knowing its tab. Rebuilt by scanning the files when a lookup misses.
    private var index: [String: UUID]?

    init(baseURL: URL? = nil) {
        let base: URL
        if let baseURL {
            base = baseURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            base = appSupport.appendingPathComponent("Itsypad")
        }
        directoryURL = base.appendingPathComponent("versions")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    // MARK: - Queries

    func versions(for tabID: UUID) -> [TabVersion] {
        load(tabID)
    }

    func latest(for tabID: UUID) -> TabVersion? {
        load(tabID).first
    }

    func version(withID id: String) -> TabVersion? {
        if let tabID = loadIndex()[id], let v = load(tabID).first(where: { $0.id == id }) {
            return v
        }
        rebuildIndex()
        guard let tabID = index?[id] else { return nil }
        return load(tabID).first(where: { $0.id == id })
    }

    // MARK: - Local mutations

    @discardableResult
    func append(_ v: TabVersion, syncable: Bool = false) -> Bool {
        guard insert(v) else { return false }
        if syncable {
            cloudHooks.versionChanged(v.id)
        }
        return true
    }

    func setLabel(_ label: String?, versionID: String, tabID: UUID, syncable: Bool = false) {
        var list = load(tabID)
        guard let i = list.firstIndex(where: { $0.id == versionID }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        list[i].label = trimmed?.isEmpty == false ? trimmed : nil
        store(list, for: tabID)
        if syncable {
            cloudHooks.versionChanged(versionID)
        }
    }

    func delete(versionID: String, tabID: UUID, syncable: Bool = false) {
        guard remove(versionID: versionID, tabID: tabID) else { return }
        if syncable {
            cloudHooks.versionDeleted(versionID)
        }
    }

    func deleteAll(tabID: UUID, syncable: Bool = false) {
        let list = load(tabID)
        store([], for: tabID)
        if syncable {
            for v in list {
                cloudHooks.versionDeleted(v.id)
            }
        }
    }

    func prune(
        tabID: UUID,
        now: Date = Date(),
        keepCount: Int = VersionPrunePolicy.hardCap,
        keepDays: Int = 0,
        syncable: Bool = false
    ) {
        let list = load(tabID)
        let drop = VersionPrunePolicy.idsToDrop(versions: list, now: now, keepCount: keepCount, keepDays: keepDays)
        guard !drop.isEmpty else { return }
        let dropSet = Set(drop)
        store(list.filter { !dropSet.contains($0.id) }, for: tabID)
        if syncable {
            for id in drop {
                cloudHooks.versionDeleted(id)
            }
        }
    }

    // MARK: - Cloud mutations (never re-uploaded)

    func applyCloud(_ v: TabVersion) {
        if insert(v) { return }
        guard let label = v.label, !label.isEmpty else { return }
        var list = load(v.tabID)
        guard let i = list.firstIndex(where: { $0.id == v.id }), list[i].label != label else { return }
        list[i].label = label
        store(list, for: v.tabID)
    }

    func removeCloud(versionID: String, tabID: UUID? = nil) {
        guard let tabID = tabID ?? version(withID: versionID)?.tabID else { return }
        remove(versionID: versionID, tabID: tabID)
    }

    // MARK: - Storage

    /// Removing one version must not break the chain: its children are
    /// repointed to its parent so merge bases stay reachable.
    @discardableResult
    private func remove(versionID: String, tabID: UUID) -> Bool {
        var list = load(tabID)
        guard let removed = list.first(where: { $0.id == versionID }) else { return false }
        list.removeAll { $0.id == versionID }
        list = list.map { v in
            guard v.parentID == versionID else { return v }
            return TabVersion(
                id: v.id,
                tabID: v.tabID,
                parentID: removed.parentID,
                createdAt: v.createdAt,
                device: v.device,
                label: v.label,
                text: v.text,
                source: v.source
            )
        }
        store(list, for: tabID)
        return true
    }

    private func insert(_ v: TabVersion) -> Bool {
        var list = load(v.tabID)
        guard !list.contains(where: { $0.id == v.id }) else { return false }
        let at = list.firstIndex(where: { $0.createdAt <= v.createdAt }) ?? list.endIndex
        list.insert(v, at: at)
        store(list, for: v.tabID)
        return true
    }

    private func fileURL(for tabID: UUID) -> URL {
        directoryURL.appendingPathComponent(tabID.uuidString).appendingPathExtension("json")
    }

    private var indexURL: URL {
        directoryURL.appendingPathComponent("index.json")
    }

    private func load(_ tabID: UUID) -> [TabVersion] {
        if let cached = cache[tabID] { return cached }
        let url = fileURL(for: tabID)
        var list: [TabVersion] = []
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode([TabVersion].self, from: data) {
                list = decoded.sorted { $0.createdAt > $1.createdAt }
            } else {
                // Same rule as TabStore.restoreSession: never let one bad read
                // silently destroy the history on the next write
                let backupURL = url.appendingPathExtension("bak")
                try? data.write(to: backupURL, options: .atomic)
                NSLog("[VersionStore] decode failed for \(url.lastPathComponent), backed up to \(backupURL.lastPathComponent)")
            }
        }
        cache[tabID] = list
        return list
    }

    private func store(_ list: [TabVersion], for tabID: UUID) {
        cache[tabID] = list
        let url = fileURL(for: tabID)
        if list.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            do {
                let data = try JSONEncoder().encode(list)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[VersionStore] failed to save versions for \(tabID): \(error)")
            }
        }
        if var index {
            index = index.filter { $0.value != tabID }
            for v in list {
                index[v.id] = tabID
            }
            self.index = index
            saveIndex()
        }
        changeCounter += 1
    }

    private func loadIndex() -> [String: UUID] {
        if let index { return index }
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: UUID].self, from: data) {
            index = decoded
            return decoded
        }
        rebuildIndex()
        return index ?? [:]
    }

    private func rebuildIndex() {
        var rebuilt: [String: UUID] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let tabID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            for v in load(tabID) {
                rebuilt[v.id] = tabID
            }
        }
        index = rebuilt
        saveIndex()
    }

    private func saveIndex() {
        guard let index, let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
