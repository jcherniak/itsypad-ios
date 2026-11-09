# Version store, trash and conflict handling – plan

Status: approved design, not yet implemented. Written 2026-11-08.

This plan extends the feature set already in progress (undo/redo, markdown
shortcut row, auto-paste with single-button undo, launch behaviour setting).
It replaces the "version history" item of that work with a git-like
append-only store, and adds trash, hard-delete and non-destructive conflict
handling. Build it as the units below, one commit per unit, tests green
before each commit.

## Decisions (do not re-litigate)

- Live text stays as full text in `TabData.content`. It is the single source
  of the live document. No read path reconstructs text from versions.
- Versions are full, content-addressed snapshots. Record ID = SHA-256 of the
  text. Identical snapshots share one record. No deltas.
- Each version carries a `parent` version ID. Forks are detected
  structurally, never by comparing `lastModified` clocks.
- Never overwrite silently. Before any remote text replaces local text, the
  local text is written as a version first ("snapshot before overwrite").
  On a structural fork, keep local as live and keep remote as a version
  labelled with device name and time ("keep both").
- Undo/redo stays on the native `UITextView.undoManager`. It is NOT built on
  versions. The only link is the auto-paste hold described in unit 3.
- Snapshots are never per keystroke. Trigger rules are in unit 1.
- Soft-delete = tombstone (`deletedAt`, `deletedOn`), tab moves to Trash,
  all versions kept. Hard-delete = explicit user action from Trash, removes
  tab and versions locally and in CloudKit.
- Git as a library is rejected (no system git on iOS, binary dependency,
  no transport, breaks Mac sync). Git as a design is adopted.
- CloudKit is the transport. The existing `CKSyncEngine` in
  `CloudSyncEngine` gains one record type. Local store is primary; CloudKit
  is the mirror, gated by the existing iCloud sync toggle.

## Unit 1 – Local version store

Files: new `Sources/App/VersionStore.swift`, edits to `TabStore.swift`,
new `Tests/VersionStoreTests.swift`.

- `struct TabVersion: Codable, Identifiable` – `id: String` (hex SHA-256 of
  text), `tabID: UUID`, `parentID: String?`, `createdAt: Date`,
  `device: String`, `label: String?`, `text: String`, `source` enum
  (`edit`, `paste`, `conflict`, `manual`, `restore`).
- `final class VersionStore` – one JSON file per tab under
  `Application Support/Itsypad/versions/<tabID>.json`. Injectable base URL
  for tests, same pattern as `TabStore(sessionURL:)`.
  API: `versions(for:)`, `append(_:)`, `latest(for:)`, `delete(versionID:tabID:)`,
  `deleteAll(tabID:)`, `prune(tabID:policy:)`.
- Snapshot trigger, implemented in `TabStore` as a single
  `recordEdit(id:content:source:)` entry point that every content write
  goes through (`updateContent`, paste, cloud apply, restore):
  - idle: 3 s with no further edit and text differs from latest version
  - delta: UTF-16 length changed by ≥ 10 % or ≥ 200 chars since latest
  - events: tab switch, app background, tab close – always snapshot if
    text differs from latest
  - debounce timer per tab, same `DispatchWorkItem` style as `scheduleSave`
- Prune policy (settings, unit 5): keep at most N versions (default 200),
  drop versions older than D days (default 90). Never drop: first version,
  latest version, any version with a `label`. Setting has an "off" value.
- Tests: hash stability, dedupe on identical text, parent chain, idle and
  delta triggers (inject a clock), event triggers, prune keeps protected
  versions, corrupt file is backed up like `restoreSession` does.

## Unit 2 – Version history UI

Files: new `Sources/Editor/VersionHistoryView.swift`, edits to
`ContentView.swift` (file menu item "Version history…", sheet).

- List grouped by day, newest first. Row: time, device, source icon,
  label if present, first line preview, char count delta vs previous.
- Tap a row: preview the full text read-only with a simple line diff
  against the current live text (added/removed lines coloured).
  Diff helper `LineDiff.swift` (LCS on lines) with tests – it is also
  needed by unit 4.
- Actions: "Restore" (writes a new version with `source: .restore`, then
  sets live text through `recordEdit`; never rewrites history), "Name this
  version" (sets `label`), "Delete version" (unit 6 hard-delete, hidden
  until unit 6 lands).
- Localization keys under `history.*`, European-style titles, en dashes.

## Unit 3 – Auto-paste hold (links to the in-progress auto-paste work)

Files: edits to the auto-paste code owned by the editor unit, plus
`TabStore.recordEdit`.

- Paste goes through `replaceTextPreservingUndo` so it lands on the native
  undo stack and the single undo button works unchanged.
- The snapshot for the paste is NOT written immediately. `recordEdit` is
  called with `source: .paste` and a `holdUntilUndoWindowCloses` flag. The
  store keeps it in memory for the undo window (10 s, or until the next
  real edit, whichever is first).
- If the single-button undo fires inside the window, the held snapshot is
  discarded. Nothing reaches history. If the window closes, it is written.
- Test: paste → undo within window → no version; paste → wait → version
  with `source: .paste`.

## Unit 4 – Non-destructive conflict handling

Files: `TabStore.applyCloudTab`, `CloudSyncEngine.swift`.

- Tab record gains `headVersionID: String?`.
- `applyCloudTab`: if remote `headVersionID` == local latest → fast-forward,
  no snapshot needed. Else snapshot local text first (`source: .conflict`),
  then:
  - if local text has no edits since common parent → apply remote as live
  - else attempt `LineDiff` three-way merge (base = common parent version,
    which exists locally when both devices descend from a synced version)
  - if merge has overlapping hunks → keep local live, store remote as a
    version labelled "Conflict – <device> <time>", set a per-tab
    `hasConflict` flag shown as a badge in tab grid and history view
- Remove the `guard data.lastModified > local.lastModified else { return }`
  early exit. `lastModified` stays as a display hint only.
- Tests: fast-forward, clean merge of non-overlapping edits, overlapping
  edits keep both, remote never overwrites unsnapshotted local text.

## Unit 5 – Settings

Files: `SettingsStore.swift`, `SettingsView.swift`, tests.

- `versionHistoryEnabled: Bool` (default true)
- `versionKeepCount: Int` (default 200, 0 = unlimited)
- `versionKeepDays: Int` (default 90, 0 = unlimited)
- `trashAutoEmptyDays: Int` (default 30, 0 = never)
- Section "History" in `SettingsView`. Keys `settings.history.*`.

## Unit 6 – Trash and hard-delete

Files: `TabData` (+ `deletedAt: Date?`, `deletedOn: String?`), `TabStore`,
`TabGridView.swift` (Trash section or toggle), `VersionHistoryView`.

- `closeTab` on a scratch tab becomes soft-delete: set tombstone, keep tab
  and versions, remove from the visible tab list (`tabs` filtered;
  `trashedTabs` published separately). File-backed tabs keep current close
  behaviour (they are not Itsypad-owned data).
- Trash view: list, "Restore", "Delete now" (confirm alert, states versions
  are removed too), "Empty trash" (confirm).
- Hard-delete: `VersionStore.deleteAll(tabID:)`, remove tab, queue
  `CloudSyncEngine.recordDeleted`. Single-version hard-delete from history:
  remove record, repoint the child's `parentID` to the deleted version's
  parent.
- Auto-empty: on launch and on foreground, hard-delete tabs whose
  `deletedAt` is older than `trashAutoEmptyDays`.
- Concurrent edit vs tombstone: the edit is still saved as a version; the
  tab shows in Trash with the newer version intact. Restore brings it back.
- Session JSON stays backward compatible (`decodeIfPresent`, nil = live).

## Unit 7 – CloudKit mirror

Files: `CloudSyncEngine.swift`, `TabStore`.

- New record type `TabVersion`: `tabID` (reference to tab record,
  `.deleteSelf`), `parentID`, `createdAt`, `device`, `label`, `source`,
  `text` (String ≤ 1 MB, else `CKAsset`), `hash` (= record name).
- Tab record gains `headVersionID`, `deletedAt`, `deletedOn`.
- Local `VersionStore.append` queues `recordChanged` for the version record
  when sync is on. Incoming version records are inserted into the local
  store by ID (idempotent, content-addressed). Incoming tombstones move
  the tab to Trash locally.
- Promote the new record type and fields in the CloudKit dashboard from
  development to production before release – otherwise production devices
  get unknown-record-type errors. Note this in CHANGELOG and in
  `docs/cloudkit-sync.md`.
- Tests: existing `CloudSyncEngineTests` pattern; version record round-trip
  encode/decode; tombstone apply.

## Order and dependencies

1 → 2 → 3 (3 also depends on the auto-paste code from the editor unit)
1 → 4 (needs `LineDiff` from 2)
5 any time after 1
6 after 1 and 2
7 last, after 4 and 6, so the production schema is promoted once with all
fields present.

## Out of scope

- Delta storage or compression (full snapshots are the model; revisit only
  if storage is measured as a problem).
- A git library or any export to a git repository.
- Mac app changes (the record schema is designed so the Mac app can adopt
  it later without migration).
