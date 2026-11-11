import Foundation

/// Run with the application sources and SXCore; optionally pass an exported HTML
/// path to verify the user's Afro Blue fixture without checking that file into Git.
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
        rejectsMusic("T44{C|N1G}Z", containing: "缺少第二结尾")
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

        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let song = try IRealImport.parse(data: data)[0]
            expect(song.title == "Afro Blue", "Afro Blue title")
            expect(song.key == SongKey(fifths: -4, minor: true) && song.meter == SongMeter(3, 4), "Afro Blue metadata")
            expect(barList(song) == ["Fm7", "Gm7", "Abmaj7 Gm7", "Fm7", "Fm7", "Gm7", "Abmaj7 Gm7", "Fm7",
                                     "Eb", "Eb", "Db Eb", "Fm7", "Eb", "Eb", "Db Eb", "Fm7"], "Afro Blue exact 16-bar form")
        }
        print("iReal Pro importer: \(assertions) assertions passed")
    }
}
