import Foundation

/// Run with the application sources and SXCore; optionally pass an exported HTML
/// paths to verify user-provided fixtures without checking those files into Git.
@main
struct IRealImportTests {
    static var assertions = 0

    static func expect(_ condition: Bool, _ message: String) {
        assertions += 1
        precondition(condition, message)
    }

    static func read(_ value: String) throws -> [IRealSong] {
        try IRealImport.parse(data: Data(value.utf8))
    }

    static func legacy(_ music: String, title: String = "Fixture", key: String = "C") throws -> IRealSong {
        try read("irealbook://\(title)=Test Composer=Swing=\(key)=n=\(music)")[0]
    }

    static func barList(_ song: IRealSong) -> [String] { song.sections.flatMap(\.bars) }

    static func rejects(_ text: String, containing: String) {
        assertions += 1
        do {
            _ = try read(text)
            preconditionFailure("Expected rejection: \(text.prefix(100))")
        } catch {
            precondition(error.localizedDescription.contains(containing), error.localizedDescription)
        }
    }

    static func rejectsMusic(_ text: String, containing: String) {
        rejects("irealbook://Invalid=Composer=Swing=C=n=\(text)", containing: containing)
    }

    static func modernRecord(title: String = "Modern", composer: String = "Composer", style: String = "Swing",
                             key: String = "C", bpm: String = "120", choruses: Int = 1, music: String) -> String {
        var symbols = Array(music)
        var offset = 0
        while symbols.count - offset > 51 {
            for position in Array(0..<5) + Array(10..<24) { symbols.swapAt(offset + position, offset + 49 - position) }
            offset += 50
        }
        return [title, composer, "", style, key, "", "1r34LbKcu7" + String(symbols), "", bpm, String(choruses)].joined(separator: "=")
    }

    static func uri(_ record: String) -> String {
        "irealb://" + record.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }

    static func main() throws {
        try navigationTests()
        let simple = try legacy("[T44*A{C^7 |A-7 |D-9 |G7#5 }")
        expect(simple.key == .cMajor && simple.meter == SongMeter(4, 4), "Key/meter")
        expect(barList(simple) == ["Cmaj7", "Am7", "Dm9", "G7#5", "Cmaj7", "Am7", "Dm9", "G7#5"], "Repeat and quality translation")
        expect(simple.sections.map(\.name) == ["A", "A"], "Repeated section keeps its name")
        let endings = try legacy("T44{*AC |A- |N1D- |G7 } |N2D- G7 |C6 Z")
        expect(barList(endings) == ["C", "Am", "Dm", "G7", "C", "Am", "Dm G7", "C6"], "First/second ending order")
        let nested = try legacy("T44{C|{D|E}|G}")
        expect(barList(nested) == ["C", "D", "E", "D", "E", "G", "C", "D", "E", "D", "E", "G"], "Nested repeats")
        let counted = try legacy("T44{*AC|G|<3x>}")
        expect(barList(counted) == ["C", "G", "C", "G", "C", "G"], "Explicit repeat count")
        let abbreviations = try legacy("T44*C|C|G|x|r|    |FZ")
        expect(barList(abbreviations) == ["C", "G", "G", "G", "G", "F"], "Single/two-bar repeats")
        let layouts = try legacy("T44[*AC||G][*BF|AmZ")
        expect(layouts.sections.map(\.name) == ["A", "B"], "Section boundaries")
        expect(barList(layouts) == ["C", "G", "F", "Am"], "Double barlines do not add bars")
        let names = try legacy("T34[*iC|G][*VF|GZ")
        expect(names.sections.map(\.name) == ["前奏", "主歌"], "Named intro/verse")
        let rhythms = try legacy("T44[Am7/GppD7|C69 W/E|C7(Ab7)ppF7Z")
        expect(barList(rhythms) == ["Am7/G:3 D7:1", "C6/9:2.666666666667 C6/9/E:1.333333333333", "C7:3 F7:1"], "Explicit relative rhythm and hidden-root inversion")
        expect(rhythms.warnings.contains { $0.contains("备选和弦") }, "Alternative harmony warning")
        let missing = try legacy("[C|Dm G7Z", key: "n")
        expect(missing.meter == nil && missing.bpm == nil, "Unspecified defaults preserved")
        expect(missing.warnings.contains { $0.contains("均分") }, "Missing meter rhythm warning")
        let expectedQualities = ["C-": "Cm", "C-7": "Cm7", "C-6": "Cm6", "C-9": "Cm9", "C-11": "Cm11",
                                "C^": "Cmaj7", "C^9": "Cmaj9", "C^7#11": "Cmaj7#11", "C^7#5": "Cmaj7#5",
                                "C-^7": "CmMaj7", "C-^9": "CmMaj9", "C-7b5": "Cm7b5", "Ch": "Cm7b5",
                                "Co": "Cdim", "Co7": "Cdim7", "C+": "Caug", "Csus": "Csus4", "C7sus": "C7sus4",
                                "C2": "Csus2", "C69": "C6/9", "C7b9": "C7b9", "Db^7/F": "Dbmaj7/F"]
        for (input, expected) in expectedQualities {
            expect(barList(try legacy("T44[\(input)Z")) == [expected], "Chord translation: \(input)")
        }
        expect(try legacy("[C]", key: "F-").key == SongKey(fifths: -4, minor: true), "Minor key")
        expect(try legacy("T12[C]").meter == SongMeter(12, 8), "12/8 shorthand")

        // The compressor placeholders and 50-character permutation are independently
        // exercised at boundary lengths rather than only round-tripping tiny charts.
        for padding in [0, 10, 49, 50, 51, 52, 99, 100, 101, 102] {
            let music = "[T34*A" + String(repeating: "C   |", count: 12) + String(repeating: "Y", count: padding) + "F-7XyQKcl LZDb Eb Z"
            let modern = try read(uri(modernRecord(key: "F-", bpm: "155.5", music: music)))[0]
            expect(modern.bpm == 155.5 && modern.key == SongKey(fifths: -4, minor: true), "Modern metadata")
            expect(barList(modern).suffix(3) == ["Fm7", "Fm7", "Db Eb"], "Modern unscramble/compressed bars at \(padding)")
        }
        let first = modernRecord(title: "中文 & Blues", composer: "", style: "", bpm: "0", music: "T44*C|C|GZ")
        let second = modernRecord(title: "Second", key: "Bb", choruses: 3, music: "T68*BC-7|F7Z")
        let playlist = try read(uri(first + "===" + second + "===My Playlist"))
        expect(playlist.map(\.title) == ["中文 & Blues", "Second"], "Modern playlist with empty metadata")
        expect(playlist[1].warnings.contains { $0.contains("3 遍") }, "Whole-song chorus warning")
        let oldPlaylist = try read("irealbook://First=One=Swing=C=n=T44[CZ=Second=Two=Bossa=D-=n=T44[D-7Z=My List")
        expect(oldPlaylist.count == 2 && oldPlaylist[1].title == "Second", "Legacy playlist")
        let link = uri(modernRecord(title: "中文 '曲名'", music: "[T44C|GZ"))
        let html = "<html><body><a href=\"\(link)\">First</a><a href='\(link)'>duplicate</a></body></html>"
        expect(try read(html).count == 1, "HTML extraction and duplicate links")
        expect(try read(html)[0].title == "中文 '曲名'", "UTF-8 title")
        let entityHTML = "<a href=\"irealbook://A&#32;&amp;&#x20;B=C=Swing=C=n=T44%5BCZ\">Song</a>"
        expect(try read(entityHTML)[0].title == "A & B", "HTML entities")

        rejects("<html>No chart here</html>", containing: "没有找到")
        rejects("irealb://broken%ZZ", containing: "百分号")
        rejects("irealb://title=composer", containing: "不完整")
        rejects("irealbook://Title=Composer=Style=C", containing: "不完整")
        rejectsMusic("T44[7|C]", containing: "符号")
        rejectsMusic("T44[C7altZ", containing: "C7alt")
        rejectsMusic("T44[CnZ", containing: "N.C.")
        rejectsMusic("T44[C|T34GZ", containing: "变为")
        rejectsMusic("T44[C|<D.C. al Fine>Z", containing: "跳转指令")
        rejectsMusic("T44[C|<D.S. al Coda>Z", containing: "跳转指令")
        rejectsMusic("T44{C|GZ", containing: "缺少")
        rejectsMusic("T44[C|N2GZ", containing: "第二结尾")
        rejectsMusic("T44{C|N1G}Z", containing: "第二结尾")
        rejectsMusic("T44{C|N3G}Z", containing: "第一、第二结尾")
        rejectsMusic("T44[x|C]", containing: "前置小节")
        rejectsMusic("T44[C|G|r|FZ", containing: "第二小节必须留空")
        rejectsMusic("T44[C|<100000x>}", containing: "反复次数")
        rejectsMusic("T44[C|<unterminated", containing: "缺少 >")
        rejectsMusic("T44[C|?Z", containing: "符号")
        rejectsMusic("T44[W/EZ", containing: "转位低音前")
        rejectsMusic("T44[   |C]", containing: "空小节")
        rejectsMusic("T44[" + String(repeating: "C|", count: 2049) + "Z", containing: "2048")
        rejectsMusic("T44{<16x>" + String(repeating: "C|", count: 300) + "}", containing: "4096")

        for path in CommandLine.arguments.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let song = try IRealImport.parse(data: data)[0]
            if song.title == "Afro Blue" {
                expect(song.key == SongKey(fifths: -4, minor: true) && song.meter == SongMeter(3, 4), "Afro Blue metadata")
                expect(barList(song) == ["Fm7", "Gm7", "Abmaj7 Gm7", "Fm7", "Fm7", "Gm7", "Abmaj7 Gm7", "Fm7",
                                         "Eb", "Eb", "Db Eb", "Fm7", "Eb", "Eb", "Db Eb", "Fm7"], "Afro Blue exact 16-bar form")
            } else if song.title == "Every Breath You Take" {
                expect(song.key == SongKey(fifths: 3, minor: false) && song.meter == SongMeter(4, 4), "Every Breath metadata")
                let ranges = [1...8, 9...16, 9...14, 17...18, 19...34, 35...38, 35...40,
                              9...16, 9...14, 17...18, 19...34, 41...44, 43...48, 45...48]
                expect(song.sections.flatMap(\.sourceBars) == ranges.flatMap(Array.init), "Exact source-bar traversal including D.S. and endings")
                expect(barList(song).count == 96, "Every Breath expands to 96 measures")
                expect(song.sections.filter(\.isReturn).flatMap(\.bars).count == 32, "Every Breath reprise is 32 measures")
                expect(song.sections.last?.name == "尾奏", "Coda is a named editable section")
            } else { preconditionFailure("Unknown local fixture: \(song.title)") }
        }
        print("iReal Pro importer: \(assertions) assertions passed")
    }
}

import Foundation

// Add this file to the existing IRealImportTests compilation and call
// `try navigationTests()` from IRealImportTests.main(). All charts are synthetic.
extension IRealImportTests {
    static func navigationTests() throws {
        func check(_ music: String, _ expected: [String], _ label: String) throws -> IRealSong {
            let song = try legacy(music, title: "Navigation fixture")
            expect(barList(song) == expected, label)
            return song
        }
        func boundaries(_ song: IRealSong) -> [Int] {
            var offset = 0
            return song.sections.map { section in
                defer { offset += section.bars.count }
                return offset
            }
        }
        func invalidNavigation(_ music: String, _ label: String, contains: String? = nil) {
            assertions += 1
            do {
                _ = try legacy(music, title: "Invalid navigation")
                preconditionFailure("Accepted malformed navigation: \(label)")
            } catch {
                precondition(error.localizedDescription.contains("Invalid navigation"), "Missing chart context: \(label)")
                if let contains { precondition(error.localizedDescription.contains(contains), "\(label): \(error.localizedDescription)") }
            }
        }

        // A leading Segno belongs to the next bar, so the intro is not replayed.
        let segno = try check("T44[*iC][*ASD|E Q][*BF|<D.S. al Coda>G][QA Z",
                              ["C", "D", "E", "F", "G", "D", "E", "A"], "D.S. returns to Segno, not song start")
        expect(boundaries(segno).contains(5), "D.S. return starts a separate editable section")
        expect(boundaries(segno).contains(7), "Coda destination starts a separate editable section")

        // Both operators are attached to a shorthand repeated bar. `events.isEmpty`
        // cannot be used alone to decide whether the marker belongs to a future bar.
        let abbreviations = try check("T44[SC|D|x Q|E|<D.S. al Coda>x][QF|GZ",
                                      ["C", "D", "D", "E", "E", "C", "D", "D", "F", "G"],
                                      "D.S. above x executes after that x bar; Q after x is To Coda")
        expect(boundaries(abbreviations).contains(5), "Returned shorthand passage splits")
        expect(boundaries(abbreviations).contains(8), "Coda after shorthand splits")

        _ = try check("T44[SC|D Q|<D.S. al Coda>E|F][QGZ", ["C", "D", "E", "F", "C", "D", "G"],
                      "Jump text takes effect at closing double barline")

        // The same jump at the end of the populated bar must not be delayed by one bar.
        _ = try check("T44[SC|D Q|E|F<D.S. al Coda>][QG|AZ",
                      ["C", "D", "E", "F", "C", "D", "G", "A"], "Suffix D.S. text anchors current bar")
        _ = try check("T44[SC|<To Coda>D|E|<D.S. al Coda>F][QG|AZ",
                      ["C", "D", "E", "F", "C", "D", "G", "A"], "Explicit To Coda plus one destination symbol")

        _ = try check("T44[*AC|D Q][*BE|<D.C. al Coda>F][QG|AZ",
                      ["C", "D", "E", "F", "C", "D", "G", "A"], "D.C. al Coda has no Segno requirement")
        let fine = try check("T44[*AC|<Fine>D][*BE|<D.C. al Fine>FZ",
                             ["C", "D", "E", "F", "C", "D"], "Prefix Fine only stops after D.C. return")
        expect(boundaries(fine).contains(4), "D.C. return splits the form")
        _ = try check("T44[*iC][*ASD|E<Fine>][*BF|<D.S. al Fine>GZ",
                      ["C", "D", "E", "F", "G", "D", "E"], "D.S. al Fine skips intro and stops at Fine")
        _ = try check("T44[SC|D Q|E|<d.s. al coda>F][QGZ",
                      ["C", "D", "E", "F", "C", "D", "G"], "Navigation text is case-insensitive")

        // iReal's return pass honours repeats; this differs from some engraved-score
        // conventions. The first and second endings must be routed on both visits.
        let endings = try check("T44{*ASC|N1D}|N2E Q][*BF|<D.S. al Coda>G][QA Z",
                                ["C", "D", "C", "E", "F", "G", "C", "D", "C", "E", "A"],
                                "D.S. honours repeat and both numbered endings on return")
        expect(boundaries(endings).contains(6), "Return after numbered endings begins a new section")

        // When a To Coda point is reached inside a repeated passage on the return,
        // navigation has priority over the repeat-end that follows it.
        _ = try check("T44{SC|D Q}|E|<D.S. al Coda>F][QGZ",
                      ["C", "D", "C", "D", "E", "F", "C", "D", "G"],
                      "To Coda interrupts the returning repeat at its marked bar")
        _ = try check("T44{SC|N1D}|N2E<Fine>|F|<D.S. al 2nd ending>GZ",
                      ["C", "D", "C", "E", "F", "G", "C", "E"],
                      "Explicit al 2nd ending skips first ending on return")

        // A repeat/fade instruction has no finite duration by itself. Braces still
        // control repeat count; the importer must describe the bounded interpretation.
        let fade = try check("T44[*A{C|<Repeat and Fade>G}Z", ["C", "G", "C", "G"], "Fade loop remains bounded by braces")
        expect(fade.warnings.contains { $0.localizedCaseInsensitiveContains("fade") || $0.contains("淡出") || $0.contains("渐弱") },
               "Repeat/fade interpretation is disclosed")
        let countedFade = try check("T44[*A{C|G<3x><Repeat and Fade>}Z", ["C", "G", "C", "G", "C", "G"],
                                   "Explicit repeat count remains authoritative with fade text")
        expect(countedFade.sections.count >= 3, "Every repeat remains an editable section visit")

        invalidNavigation("T44[C|D Q|<D.S. al Coda>E][QFZ", "D.S. missing Segno")
        invalidNavigation("T44[SC|D|<D.S. al Coda>E][QFZ", "Coda destination without To Coda")
        invalidNavigation("T44[SC|D Q|<D.S. al Coda>E Z", "To Coda without destination")
        invalidNavigation("T44[C|D|<D.C. al Fine>E Z", "al Fine without Fine")
        invalidNavigation("T44[SC|SD Q|<D.S. al Coda>E][QFZ", "Ambiguous multiple Segnos")
        // Written bars stay under 2048, but repeats + return exceed the output cap.
        invalidNavigation("T44{S" + String(repeating: "C|", count: 1600) + "C<Fine>}|<D.S. al Fine>GZ",
                          "Navigation expansion is globally bounded", contains: "4096")
    }
}
