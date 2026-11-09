import XCTest
@testable import ItsypadCore

final class LineDiffTests: XCTestCase {
    private func kinds(_ lines: [LineDiff.Line]) -> [LineDiff.Line.Kind] {
        lines.map(\.kind)
    }

    func testEmptyInputs() {
        XCTAssertEqual(LineDiff.diff(old: "", new: ""), [])
        XCTAssertEqual(LineDiff.diff(old: "", new: "a\nb"), [
            .init(kind: .added, text: "a"), .init(kind: .added, text: "b"),
        ])
        XCTAssertEqual(LineDiff.diff(old: "a\nb", new: ""), [
            .init(kind: .removed, text: "a"), .init(kind: .removed, text: "b"),
        ])
    }

    func testIdenticalTextIsAllSame() {
        let text = "one\ntwo\nthree"
        let result = LineDiff.diff(old: text, new: text)
        XCTAssertEqual(kinds(result), [.same, .same, .same])
        XCTAssertEqual(result.map(\.text), ["one", "two", "three"])
    }

    func testInsertion() {
        let result = LineDiff.diff(old: "a\nc", new: "a\nb\nc")
        XCTAssertEqual(result, [
            .init(kind: .same, text: "a"),
            .init(kind: .added, text: "b"),
            .init(kind: .same, text: "c"),
        ])
    }

    func testDeletion() {
        let result = LineDiff.diff(old: "a\nb\nc", new: "a\nc")
        XCTAssertEqual(result, [
            .init(kind: .same, text: "a"),
            .init(kind: .removed, text: "b"),
            .init(kind: .same, text: "c"),
        ])
    }

    func testReplacement() {
        let result = LineDiff.diff(old: "a\nb\nc", new: "a\nX\nc")
        XCTAssertEqual(kinds(result), [.same, .removed, .added, .same])
        XCTAssertEqual(result[1].text, "b")
        XCTAssertEqual(result[2].text, "X")
    }

    func testTrailingNewlineDoesNotCreateAnEmptyLine() {
        XCTAssertEqual(LineDiff.lines("a\nb\n"), ["a", "b"])
        XCTAssertEqual(LineDiff.lines("a\nb"), ["a", "b"])
        XCTAssertEqual(LineDiff.lines("\n"), [""])
        XCTAssertEqual(LineDiff.lines(""), [])

        let result = LineDiff.diff(old: "a\nb\n", new: "a\nb\nc")
        XCTAssertEqual(result, [
            .init(kind: .same, text: "a"),
            .init(kind: .same, text: "b"),
            .init(kind: .added, text: "c"),
        ])
        XCTAssertEqual(kinds(LineDiff.diff(old: "a\nb", new: "a\nb\n")), [.same, .same])
    }

    func testBlankLinesInsideTextArePreserved() {
        let result = LineDiff.diff(old: "a\n\nb", new: "a\n\nb")
        XCTAssertEqual(result.map(\.text), ["a", "", "b"])
    }

    func testOversizedInputFallsBackToRemoveAllAddAll() {
        let big = (0...LineDiff.maxLines).map(String.init).joined(separator: "\n")
        let result = LineDiff.diff(old: big, new: "0\n1")
        XCTAssertEqual(result.filter { $0.kind == .removed }.count, LineDiff.maxLines + 1)
        XCTAssertEqual(result.filter { $0.kind == .added }.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.kind != .same })
    }

    // MARK: - merge3

    private let base = "one\ntwo\nthree\nfour\nfive\nsix"

    func testMerge3AppliesEditsInDifferentRegions() {
        let ours = "ONE\ntwo\nthree\nfour\nfive\nsix"
        let theirs = "one\ntwo\nthree\nfour\nfive\nSIX"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: ours, theirs: theirs), .clean("ONE\ntwo\nthree\nfour\nfive\nSIX"))
    }

    func testMerge3CombinesInsertionAndDeletion() {
        let ours = "one\ntwo\nthree\nfour\nfive\nsix\nseven"
        let theirs = "one\nthree\nfour\nfive\nsix"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: ours, theirs: theirs), .clean("one\nthree\nfour\nfive\nsix\nseven"))
    }

    func testMerge3SameLinesConflict() {
        let ours = "one\ntwo\nTHREE\nfour\nfive\nsix"
        let theirs = "one\ntwo\n3\nfour\nfive\nsix"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: ours, theirs: theirs), .conflicted)
    }

    func testMerge3AdjacentEditsConflict() {
        let ours = "one\nTWO\nthree\nfour\nfive\nsix"
        let theirs = "one\ntwo\nTHREE\nfour\nfive\nsix"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: ours, theirs: theirs), .conflicted)
    }

    func testMerge3InsertionsAtSamePointConflict() {
        let ours = "one\ntwo\nours\nthree\nfour\nfive\nsix"
        let theirs = "one\ntwo\ntheirs\nthree\nfour\nfive\nsix"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: ours, theirs: theirs), .conflicted)
    }

    func testMerge3IdenticalSidesAreClean() {
        let both = "one\nTWO\nthree"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: both, theirs: both), .clean(both))
        XCTAssertEqual(LineDiff.merge3(base: base, ours: base, theirs: base), .clean(base))
    }

    func testMerge3OneSideUnchangedTakesTheOther() {
        let edited = "one\ntwo\nthree\nfour\nfive\nsix\nseven"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: base, theirs: edited), .clean(edited))
        XCTAssertEqual(LineDiff.merge3(base: base, ours: edited, theirs: base), .clean(edited))
        XCTAssertEqual(LineDiff.merge3(base: "", ours: "", theirs: "new"), .clean("new"))
    }

    func testMerge3SameChangeOnBothSidesPlusOneMore() {
        // Theirs already contains our change (it merged our push) and adds one
        let ours = "ONE\ntwo\nthree\nfour\nfive\nsix"
        let theirs = "ONE\ntwo\nthree\nfour\nfive\nSIX"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: ours, theirs: theirs), .clean(theirs))
    }

    func testMerge3KeepsTrailingNewlineOfTheSideThatChangedIt() {
        XCTAssertEqual(LineDiff.merge3(base: "a\nb", ours: "A\nb", theirs: "a\nb\n"), .clean("A\nb\n"))
        XCTAssertEqual(LineDiff.merge3(base: "a\nb\n", ours: "a\nb", theirs: "a\nB\n"), .clean("a\nB"))
        XCTAssertEqual(LineDiff.merge3(base: "a\nb\nc\n", ours: "A\nb\nc\n", theirs: "a\nb\nC\n"), .clean("A\nb\nC\n"))
    }

    func testMerge3OversizedInputIsConflicted() {
        let big = (0...LineDiff.maxLines).map(String.init).joined(separator: "\n")
        XCTAssertEqual(LineDiff.merge3(base: big, ours: big + "\nx", theirs: "y\n" + big), .conflicted)
    }
}
