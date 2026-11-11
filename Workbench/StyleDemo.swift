import Foundation
import SXCore

struct StyleDemo {
    let name: String
    let description: String
    let draft: Draft

    init(entry: StyleEntry, style: Style) {
        let profile = DemoProfile.select(entry)
        name = profile.name
        description = profile.description
        let key = profile.key
        let writtenIn = SongKey(fifths: 0, minor: key.minor)
        let tonic = key.tonicName + (key.minor ? "m" : "")
        let available = Set(style.sections.map(\.name))
        let mains = style.sections.map(\.name).filter { $0.hasPrefix("Main ") }
        var blocks: [Draft.Block] = []
        if available.contains("Intro A") {
            blocks.append(.init(name: "前奏", pattern: "Intro A", bars: [tonic]))
        }
        for (index, phrase) in profile.phrases.enumerated() {
            let pattern = available.contains(phrase.pattern) ? phrase.pattern : mains.first ?? "Main A"
            let chords = phrase.bars.map { key.transpose($0, from: writtenIn) }
            let following = profile.phrases.indices.contains(index + 1) ? profile.phrases[index + 1].pattern : ""
            let fill = following.last.map { "Fill In " + String(repeating: String($0), count: 2) } ?? ""
            let shortFill = style.sections.contains { $0.name == fill && $0.length == style.ticksPerBar }
            if phrase.fill && shortFill && chords.count > 1, let last = chords.last {
                blocks.append(.init(name: phrase.name, pattern: pattern, bars: Array(chords.dropLast())))
                blocks.append(.init(name: "过门", pattern: fill, bars: [last]))
            } else {
                blocks.append(.init(name: phrase.name, pattern: pattern, bars: chords))
            }
        }
        if available.contains("Ending A") {
            blocks.append(.init(name: "尾奏", pattern: "Ending A", bars: [tonic]))
        }
        draft = Draft(title: entry.name + " · " + profile.name,
                      stylePath: entry.path, bpm: String(format: "%.1f", style.bpm),
                      key: key, meter: nil, blocks: blocks)
    }
}

private struct DemoProfile {
    struct Phrase {
        let name: String
        let pattern: String
        let bars: [String]
        let fill: Bool

        init(_ name: String, _ variation: String, _ chords: String, fill: Bool = false) {
            self.name = name
            pattern = "Main " + variation
            bars = chords.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            self.fill = fill
        }
    }

    let name: String
    let description: String
    let key: SongKey
    let phrases: [Phrase]

    init(_ name: String, _ description: String, _ fifths: Int, minor: Bool = false, _ phrases: Phrase...) {
        self.name = name
        self.description = description
        self.key = SongKey(fifths: fifths, minor: minor)
        self.phrases = phrases
    }

    static func select(_ entry: StyleEntry) -> Self {
        let name = entry.originalName.lowercased()
        func has(_ fragments: String...) -> Bool { fragments.contains { name.contains($0) } }
        if has("flamenc", "spanishpaso", "pasodoble") { return flamenco }
        if has("tango") { return tango }
        if has("boss") { return has("fast", "rio", "brazil") ? brightBossa : bossa }
        if has("samba") { return has("jazz") ? sambaJazz : samba }
        if has("bachata", "zouk") { return bachata }
        if has("salsa", "cubanson", "afrocuban", "guaguanco", "guajira", "mambo", "cubanpop") { return montuno }
        if has("bolero") { return bolero }
        if has("cumbia", "merengue", "bomba", "soca") { return caribbean }
        if has("reggaeton", "dancehall", "riddim", "reggae") { return reggae }
        if has("baroque", "hymn", "choral") { return chorale }
        if has("christmas") { return has("swing") ? swing : chorale }
        if has("march", "military", "brassband") { return march }
        if has("polka", "krainer", "mazurka", "volks") { return has("waltz") ? waltz : polka }
        if has("celtic", "irishdance", "scottish", "reel", "jig", "sirtaki", "tarantella") { return folkDance }
        if has("waltz") { return entry.category == "jazz" ? jazzWaltz : waltz }
        if has("ragtime", "saloonpiano", "dixieland", "charleston") { return ragtime }
        if has("bluegrass", "pickin", "hoedown") { return bluegrass }
        if has("gospel") { return gospel }
        if has("blues") {
            if entry.category == "jazz" { return jazzBlues }
            if has("rock") { return bluesRock }
            if has("ballad", "slow") { return slowBlues }
            return blues
        }
        if has("boogie", "rock&roll", "rockabilly", "twist", "jive") { return rockRoll }
        if has("fivefour") && entry.category == "jazz" { return fiveFourJazz }
        if has("jazzfusion", "jazzfunk", "drawbargroove", "fusion") { return fusion }
        if has("bigband", "broadway", "quickstep") { return has("ballad") ? jazzBallad : bigBand }
        if has("cha-cha", "rumba", "beguine") { return rumba }
        if has("foxtrot", "swing") {
            if entry.category == "country" { return westernSwing }
            return has("ballad", "slow", "cool") ? jazzBallad : swing
        }
        if has("hiphop", "beatbox") { return hipHop }
        if has("trance", "dreamhouse", "dreamdance", "hardclub", "bigroom") { return trance }
        if has("house", "club", "edm", "electronica", "synthpop", "synthduo", "synthballad") && entry.category != "jazz" {
            return has("ballad") ? minorPop : house
        }
        if has("disco", "funk") { return disco }
        if has("soul", "r&b", "motorcity", "detroit") { return has("ballad", "slow", "smooth") ? soulBallad : soul }
        if has("grunge", "hardrock", "powerrock", "edgyrock") { return hardRock }
        if has("psychedelic", "raga", "progressive", "fivefour") { return modalRock }
        if has("stadium", "anthem", "epic", "blockbuster") { return entry.category == "country" ? countryBallad : anthem }
        if has("western", "gunslinger", "desert", "mariachi") { return western }
        if has("mystery", "icy", "scifi", "sci-fi", "ethereal", "wildwest", "secretservice", "fantasia") { return cinematicMinor }
        if has("songwriter", "unplugged", "acousticfolk", "folksong", "folkpop", "hawaiian", "ukulele") { return folkPop }
        if has("crooner", "lounge", "easyorchestra", "easylistening") { return jazzBallad }
        if has("britpop", "britrock", "britsoft", "altrock") { return britPop }
        if has("ballad", "lovesong", "romantic", "6-8", "12-8") {
            if entry.category == "country" { return countryBallad }
            if entry.category == "jazz" { return jazzBallad }
            if entry.category == "latin" { return bolero }
            if entry.category == "movie-show" { return cinematic }
            if entry.category == "rock" { return rockBallad }
            return has("piano", "organ") ? pianoBallad : ballad
        }
        switch entry.category {
        case "jazz": return swing
        case "latin": return latinPop
        case "country": return country
        case "dance": return dancePop
        case "r-b": return soul
        case "rock": return classicRock
        case "oldies": return has("50s", "vintage", "bubblegum", "love", "oldies") ? dooWop : oldPop
        case "retropop": return has("synth", "analog", "electro", "dx") ? minorPop : oldPop
        case "ballroom": return waltz
        case "classic-events": return chorale
        case "entertainer": return schlager
        case "movie-show": return cinematic
        case "trad-folk": return folkDance
        case "easylistening": return pianoBallad
        default: return has("dance", "electro") ? dancePop : modernPop
        }
    }

    static let modernPop = Self("流行主副歌", "主歌从关系小调展开，副歌回到大调，用转位低音连起和弦。", 0,
        .init("主歌", "A", "Am7 | Fadd9 | C | G/B | Am7 | Fadd9 | Dm7 | G7", fill: true),
        .init("副歌", "C", "C | G/B | Am7 | Fadd9 | C/E | F | Gsus4 G | C"))
    static let ballad = Self("流行抒情", "主歌用下行低音，副歌加强主和弦与下属和弦的对比。", 0,
        .init("主歌", "A", "C | G/B | Am7 | C/G | Fmaj7 | C/E | Dm7 | G7", fill: true),
        .init("副歌", "C", "Fadd9 | G | Em7 | Am7 | F | C/E | Dm7 G7 | C"))
    static let pianoBallad = Self("钢琴抒情", "用转位低音和大七和弦串联长句，结尾用 ii–V–I 收束。", -1,
        .init("主题", "A", "Cmaj7 | G/B | Am7 | C/G | Fmaj7 | C/E | Dm7 | G7"),
        .init("展开", "B", "Em7 | Am7 | Dm7 | G7 | Cmaj7 | Fmaj7 | Dm7 G7 | C"))
    static let minorPop = Self("小调流行", "主段使用 i–VI–III–VII，副段加入属七和弦明确回到小调。", 1, minor: true,
        .init("主段", "A", "Am | F | C | G | Am | F | C | G", fill: true),
        .init("副段", "C", "F | G | Am | Am | Dm | F | E7 | Am"))
    static let britPop = Self("英伦流行", "在大调里借用降七级，配合挂留和弦和开放吉他式进行。", 1,
        .init("主歌", "A", "C | B♭ | F | C | Am | G | F | Gsus4", fill: true),
        .init("副歌", "C", "C | G | Am | F | C | B♭ | F G | C"))
    static let oldPop = Self("复古流行", "八拍主段采用主、关系小调和下属和声，副段用副属和弦转回主调。", 0,
        .init("主歌", "A", "C | Am | F | G | C | Em | F | G7", fill: true),
        .init("副歌", "B", "F | G | Em | A7 | Dm | G7 | C | C"))
    static let dooWop = Self("早期流行四和弦", "I–vi–IV–V 是早期流行与嘟哇人声常见的循环，桥段暂向下属和声展开。", -2,
        .init("主题 A", "A", "C | Am | F | G7 | C | Am | F | G7"),
        .init("桥段 B", "B", "F | F | C | C7 | F | D7 | G7 | G7"),
        .init("主题再现", "A", "C | Am | F | G7 | C | Am | F G7 | C"))
    static let dancePop = Self("流行舞曲", "四小节小调循环作主段，逐步提高风格变奏的能量，落点回到主和弦。", 0, minor: true,
        .init("铺垫", "A", "Am | F | C | G | Am | F | C | G", fill: true),
        .init("主舞段", "C", "Am | G | F | G | Am | G | F | Am"))
    static let house = Self("浩室循环", "主和弦保持律动，第二句用下属和声拉开张力。结构是铺垫、渐强、主舞段。", -3, minor: true,
        .init("铺垫", "A", "Am7 | Am7 | Am7 | Am7"),
        .init("渐强", "B", "Am7 | Fmaj7 | C | G | Am7 | Fmaj7 | C | G", fill: true),
        .init("主舞段", "D", "Am7 | Am7 | Dm7 | Fmaj7 | Am7 | G | Fmaj7 | Am7"))
    static let trance = Self("迷幻舞曲", "小调 i–VI–III–VII 的持续循环，用主奏变奏完成渐强与落拍。", 3, minor: true,
        .init("渐强", "A", "Am | F | C | G | Am | F | C | G", fill: true),
        .init("主舞段", "D", "Am | F | C | G | Am | F | C | Am"))
    static let hipHop = Self("嘻哈循环", "以小七、挂留和弦和较少的换和弦保留说唱或即兴的空间。", 1, minor: true,
        .init("主循环", "A", "Am7 | Am7 | Dm7 | Dm7 | Am7 | Am7 | Fmaj7 | Gsus4"),
        .init("钩句", "C", "Am7 | Fmaj7 | Dm7 | E7sus4 | Am7 | Fmaj7 | G | Am7"))
    static let disco = Self("迪斯科与放克", "主段以 i7–IV7 的多利亚色彩支撑律动，副段加入属七形成回归。", 0, minor: true,
        .init("律动", "A", "Am7 | D9 | Am7 | D9 | Am7 | D9 | Am7 | D9", fill: true),
        .init("副段", "C", "Fmaj7 | G | Am7 | Am7 | D9 | Fmaj7 | E7 | Am7"))
    static let reggae = Self("雷鬼律动", "四小节循环保持和声简单，把反拍与低音交给风格声部。", 0, minor: true,
        .init("主循环", "A", "Am | G | F | G | Am | G | F | G"),
        .init("副段", "C", "F | C | G | Am | F | C | E7 | Am"))
    static let country = Self("纳什维尔乡村", "以 I、IV、V 为骨架，副段用关系小调制造短暂对比。", 2,
        .init("主歌", "A", "C | C | F | C | G7 | G7 | C | C", fill: true),
        .init("副歌", "C", "F | C | Am | G | F | C | G7 | C"))
    static let countryBallad = Self("乡村抒情", "主歌以主属功能为底，副歌加上斜杠低音与下属和弦。", 1,
        .init("主歌", "A", "C | C | F | C | Am | F | G7 | G7", fill: true),
        .init("副歌", "B", "F | C/E | Dm | C | F | C | G7 | C"))
    static let bluegrass = Self("蓝草两段式", "两段八小节，以 I–IV–V7 和属七回转配合拨弦与行进低音。", 1,
        .init("乐句 A", "A", "C | C | F | C | G7 | G7 | C | C"),
        .init("乐句 B", "B", "F | F | C | C | D7 | G7 | C G7 | C"),
        .init("乐句再现", "A", "C | C | F | C | G7 | G7 | C | C"))
    static let westernSwing = Self("西部摇摆", "在乡村主属骨架中插入连续属七与 ii–V，适合摇摆节奏。", 1,
        .init("主段", "A", "C6 | A7 | Dm7 | G7 | C6 | E7 | A7 | D7 G7"),
        .init("副段", "C", "F6 | Fm6 | C6 | A7 | Dm7 | G7 | C6 | C6"))
    static let folkPop = Self("民谣流行", "开放和弦与持续低音适合原声吉他，副段用下属–主和声回归。", 1,
        .init("主歌", "A", "Cadd9 | G/B | Am7 | Fadd9 | C | G | F | G"),
        .init("副歌", "B", "Fadd9 | C | G | Am7 | F | C/E | Gsus4 G | C"))
    static let folkDance = Self("民间舞曲两段式", "八小节 AABB 舞曲句式；小调主段与关系大调副段交替。", -1, minor: true,
        .init("舞段 A", "A", "Am | G | Am | Am | C | G | E7 | Am"),
        .init("舞段 A 再奏", "A", "Am | G | Am | Am | C | G | E7 | Am"),
        .init("舞段 B", "B", "C | G | C | F | Dm | Am | E7 | Am"),
        .init("舞段 B 再奏", "B", "C | G | C | F | Dm | Am | E7 | Am"))
    static let polka = Self("波尔卡两段式", "用短句的 I–V7 交替强调舞步，副段转向下属区后回主调。", -2,
        .init("舞段 A", "A", "C | G7 | G7 | C | C | F | G7 | C"),
        .init("舞段 B", "B", "F | F | C7 | F | F | C | G7 | C"))
    static let waltz = Self("华尔兹", "两组八小节，主段建立主属，第二段转向下属，保留风格自己的三拍或复合拍律动。", -1,
        .init("主题 A", "A", "C | C | G7 | G7 | G7 | G7 | C | C"),
        .init("主题 B", "B", "F | F | C | C | Dm | G7 | C | C"),
        .init("主题再现", "A", "C | C | G7 | G7 | F | C/G | G7 | C"))
    static let march = Self("进行曲与三重奏段", "先用方整八小节主部，再用下属调区的三重奏段形成对比。", -2,
        .init("进行曲主部", "A", "C | C | G7 | C | F | C | G7 | C"),
        .init("三重奏段", "B", "F | C7 | F | F | B♭ | F | C7 | F"),
        .init("主部再现", "C", "C | C | G7 | C | F | C | G7 | C"))
    static let chorale = Self("圣咏式终止", "用主属和声写问答句，低音转位后以正格终止收束。", -1,
        .init("问句", "A", "C | G/B | Am | Em/G | F | C/E | Dm | G"),
        .init("答句", "B", "C | C7 | F | Dm/F | C/G | G7 | C | C"))
    static let schlager = Self("德语流行舞曲", "明快的主属骨架配四小节副歌循环，适合舞厅风格变奏。", 1,
        .init("主歌", "A", "C | C | G | G | F | C | Dm | G7", fill: true),
        .init("副歌", "C", "C | G | Am | F | C | G | F G7 | C"))
    static let ragtime = Self("拉格泰姆两段式", "用属七链与主属跳进配切分，第二段暂以 IV 作新的支点。", -1,
        .init("乐段 A", "A", "C | G7 | C | A7 | D7 | G7 | C G7 | C"),
        .init("乐段 B", "C", "F | C7 | F | D7 | G7 | G7 | C7 | F"))
    static let swing = Self("摇摆爵士进行", "用大六、大七和弦与 ii–V 回转，连续属七形成桥段。", -2,
        .init("主题 A", "A", "C6 | A7 | Dm7 | G7 | Em7 | A7 | Dm7 G7 | C6"),
        .init("桥段", "B", "E7 | E7 | A7 | A7 | D7 | D7 | G7 | G7"),
        .init("主题再现", "C", "C6 | A7 | Dm7 | G7 | Fmaj7 | Fm6 | Dm7 G7 | C6"))
    static let bigBand = Self("大乐队 AABA", "两段相同的八小节 A，桥段用连续属七推进，最后回到主题。", -2,
        .init("主题 A1", "A", "C6 A7 | Dm7 G7 | C6 A7 | Dm7 G7 | C7 | F6 Fm6 | Em7 A7 | Dm7 G7"),
        .init("主题 A2", "A", "C6 A7 | Dm7 G7 | C6 A7 | Dm7 G7 | C7 | F6 Fm6 | Dm7 G7 | C6"),
        .init("桥段 B", "B", "E7 | E7 | A7 | A7 | D7 | D7 | G7 | G7"),
        .init("主题 A3", "D", "C6 A7 | Dm7 G7 | C6 A7 | Dm7 G7 | C7 | F6 Fm6 | Dm7 G7 | C6"))
    static let jazzBallad = Self("爵士抒情", "把 ii–V–I 与小下属和弦穿插在八小节长句里。", -3,
        .init("主题", "A", "Cmaj7 | Cmaj7 | Dm7 | G7 | Em7 | A7♭9 | Dm7 G7 | Cmaj7"),
        .init("桥段", "B", "Fmaj7 | Fm6 | Em7 | A7 | Dm7 | G7 | Cmaj7 | Cmaj7"))
    static let jazzWaltz = Self("爵士华尔兹", "在三拍律动中每小节只换一次和弦，用 ii–V–I 串联两个八小节。", -2,
        .init("主题", "A", "Cmaj7 | Am7 | Dm7 | G7 | Cmaj7 | A7 | Dm7 | G7"),
        .init("展开", "C", "Fmaj7 | Fm6 | Em7 | A7 | Dm7 | G7 | Cmaj7 | C6"))
    static let fiveFourJazz = Self("五拍调式爵士", "用小七和弦的固定低音突出五拍律动，桥段短暂进入关系大调，再用小调 ii–V 回到主题。", -1, minor: true,
        .init("调式主题", "A", "Am7 | Am7 | D9/A | Am7 | Am7 | Am7 | D9/A | Am7"),
        .init("桥段", "B", "Dm7 | G13 | Cmaj7 | Cmaj7 | Fmaj7 | Bm7♭5 | E7♭9 | Am7"),
        .init("主题再现", "C", "Am7 | Am7 | D9/A | Am7 | Am7 | Fmaj7 | E7♭9 | Am7"))
    static let jazzBlues = Self("十二小节爵士布鲁斯", "以 I7 和 IV7 为支点，第九与第十小节用 ii–V，末两小节作回转。", -1,
        .init("布鲁斯主题", "A", "C7 | F7 | C7 | C7 | F7 | F♯dim7 | C7 | A7 | Dm7 | G7 | C7 A7 | Dm7 G7"),
        .init("即兴轮奏", "C", "C7 | F7 | C7 | C7 | F7 | F♯dim7 | C7 | A7 | Dm7 | G7 | C7 | C7"))
    static let blues = Self("十二小节布鲁斯", "两个十二小节轮次用 I7、IV7、V7；第一轮留下属七回转，第二轮收束。", 4,
        .init("第一轮", "A", "C7 | C7 | C7 | C7 | F7 | F7 | C7 | C7 | G7 | F7 | C7 | G7"),
        .init("第二轮", "C", "C7 | F7 | C7 | C7 | F7 | F7 | C7 | C7 | G7 | F7 | C7 | C7"))
    static let slowBlues = Self("慢布鲁斯", "保留十二小节骨架，在回转中加入九和弦与快速换到 IV。", -2,
        .init("主题", "A", "C9 | F9 | C9 | C9 | F9 | F9 | C9 | C9 | G9 | F9 | C9 | G7"),
        .init("回应", "B", "C9 | F9 | C9 | C9 | F9 | F9 | C9 | A7 | Dm7 | G7 | C9 | C9"))
    static let bluesRock = Self("布鲁斯摇滚", "吉他用十二小节 I–IV–V 为骨架，最后用属七回转。", 4,
        .init("主段", "A", "C5 | C5 | C5 | C5 | F5 | F5 | C5 | C5 | G5 | F5 | C5 | G7"),
        .init("独奏轮次", "D", "C7 | C7 | C7 | C7 | F7 | F7 | C7 | C7 | G7 | F7 | C7 | C5"))
    static let rockRoll = Self("早期摇滚十二小节", "十二小节主属骨架与强拍反拍结合，过渡处保持属七色彩。", 3,
        .init("主题", "A", "C | C | C | C | F | F | C | C | G7 | F7 | C | G7"),
        .init("轮奏", "C", "C7 | C7 | C7 | C7 | F7 | F7 | C7 | C7 | G7 | F7 | C | C"))
    static let fusion = Self("融合爵士", "用小七与属九建立多利亚律动，桥段用延伸和弦扩大色彩。", 0, minor: true,
        .init("律动", "A", "Am9 | D9 | Am9 | D9 | Am9 | D9 | Fmaj7 | E7♯9"),
        .init("展开", "C", "Dm9 | G13 | Cmaj9 | Fmaj7♯11 | Bm7♭5 | E7♯9 | Am9 | Am9"))
    static let gospel = Self("福音应答", "下属–主的阿门终止是句尾支点，次属和弦与斜杠低音推动问答。", -3,
        .init("领唱", "A", "C | C/E | F | C/G | Am7 | D7 | Dm7 | G7", fill: true),
        .init("应答", "D", "C | C7 | F | Fm6 | C/E | Dm7 | F C | C"))
    static let soul = Self("灵魂乐主副段", "主段用主和弦与下属色彩交替，副段用属七与小下属收束。", -2,
        .init("主段", "A", "C6 | C6 | Fmaj7 | Fmaj7 | C6 | A7 | Dm7 | G7", fill: true),
        .init("副段", "C", "Fmaj7 | Em7 Am7 | Dm7 | G7 | Fmaj7 | Fm6 | C6 | C6"))
    static let soulBallad = Self("灵魂乐抒情", "大七和小七延续歌唱性，副段靠斜杠低音与延迟解决回到主和弦。", -3,
        .init("主歌", "A", "Cmaj7 | G/B | Am9 | Em7 | Fmaj7 | C/E | Dm9 | G7sus4"),
        .init("副歌", "C", "Fmaj7 | G13 | Em7 | Am9 | Dm9 | G7sus4 G7 | Cmaj7 | Cmaj7"))
    static let hardRock = Self("硬摇滚强力和弦", "五度和弦保留失真音色的清晰度，小调与降七级构成吉他式反复。", 1, minor: true,
        .init("主奏反复", "A", "A5 | A5 | G5 | D5 | A5 | A5 | F5 | G5", fill: true),
        .init("副段", "D", "F5 | G5 | A5 | A5 | D5 | F5 | E5 | A5"))
    static let classicRock = Self("经典摇滚", "大调主和弦、降七级与下属形成摇滚反复，副段用属和弦收束。", 2,
        .init("吉他主段", "A", "C | B♭ | F | C | C | B♭ | F | C", fill: true),
        .init("副段", "C", "F | C | G | Am | F | C | G | C"))
    static let modalRock = Self("调式摇滚", "用 i 与大 IV 的多利亚色彩形成固定反复，桥段用降七级打开空间。", -1, minor: true,
        .init("调式主段", "A", "Am7 | D | Am7 | D | Am7 | D | Am7 | D"),
        .init("对比段", "C", "G | D | Am7 | Am7 | G | D | E7 | Am7"))
    static let rockBallad = Self("摇滚抒情", "安静主段用挂留和弦，高潮进入全乐队和五度骨架。", 1,
        .init("主歌", "A", "Cadd9 | G/B | Am | Fadd9 | C | G | F | Gsus4", fill: true),
        .init("高潮", "D", "C5 | G5 | A5 | F5 | C5 | B♭5 | F5 G5 | C5"))
    static let anthem = Self("颂歌式高潮", "小编制主歌渐强后转进开阔副歌，结尾用挂留解决突出主和弦。", 2,
        .init("主歌", "A", "Am | F | C | G | Am | F | Dm | G", fill: true),
        .init("高潮", "D", "C | G | Am | F | C/E | F | Gsus4 G | C"))
    static let bossa = Self("波萨诺瓦", "以大七、小七和弦和 ii–V–I 写两组八小节，保留巴西风格自己的伴奏节奏。", -1,
        .init("主题", "A", "Cmaj7 | C6/9 | Dm9 | G13 | Em7 | A7♭9 | Dm9 | G13"),
        .init("展开", "B", "Fmaj7 | Fm6 | Em7 | A7 | Dm9 | G13 | Cmaj7 | C6/9"))
    static let brightBossa = Self("快速波萨诺瓦", "用带延伸音的 ii–V 依次转向下属与关系小调，让轻快的巴西律动保持流动。", -2,
        .init("主题", "A", "C6/9 | Em7 A7 | Dm9 | G13 | Cmaj7 | Gm7 C7 | Fmaj7 | Fm6"),
        .init("副段", "C", "Em7 | A7♭9 | Dm9 | G13 | Bm7♭5 E7 | Am7 | Dm9 G13 | C6/9"))
    static let sambaJazz = Self("爵士桑巴", "用连续 ii–V 和短循环配合桑巴律动，保留延伸和弦色彩。", -2,
        .init("主题", "A", "C6/9 | A7 | Dm7 | G13 | C6/9 | A7 | Dm7 | G13"),
        .init("副段", "C", "Fmaj7 | Fm6 | Em7 | A7 | Dm7 | G13 | C6/9 | C6/9"))
    static let samba = Self("桑巴主副段", "快速舞步配方整和声，用副属和弦推动换段。", 0,
        .init("主段", "A", "C6 | C6 | G7 | G7 | Dm7 | G7 | C6 | C6"),
        .init("副段", "C", "F6 | F6 | C6 | A7 | Dm7 | G7 | C6 | C6"))
    static let montuno = Self("古巴颂乐与蒙图诺", "主段建立主属和声，后段用短循环给合唱应答或即兴留空间；节奏由原风格给出。", -1, minor: true,
        .init("主歌", "A", "Am | Am | E7 | E7 | Dm | Am | E7 | Am"),
        .init("蒙图诺循环", "C", "Am | Dm | E7 | Am | Am | Dm | E7 | Am"))
    static let bolero = Self("波莱罗抒情", "浪漫长句使用 I–vi–ii–V，副段以小下属和弦增加色彩。", -1,
        .init("主歌", "A", "Cmaj7 | Am7 | Dm7 | G7 | Cmaj7 | Am7 | Dm7 | G7"),
        .init("副歌", "B", "Fmaj7 | Fm6 | Em7 | A7 | Dm7 | G7 | Cmaj7 | Cmaj7"))
    static let rumba = Self("拉丁舞厅小品", "采用主、下属与属七，和声短句适合恰恰、伦巴等舞步。", 0,
        .init("主舞段", "A", "C | C | G7 | G7 | F | G7 | C | C"),
        .init("对比舞段", "B", "F | F | C | A7 | Dm | G7 | C | C"))
    static let tango = Self("小调探戈", "小调 i–iv–V7 形成明确重音，副段转到关系大调后回归。", -1, minor: true,
        .init("探戈 A", "A", "Am | Am | E7 | E7 | Dm | Am | E7 | Am"),
        .init("探戈 B", "C", "C | G7 | C | F | Dm | Am/E | E7 | Am"))
    static let flamenco = Self("安达卢西亚终止", "小调下行 i–VII–VI–V7 保留弗拉门戈的终止色彩，留出舞段反复。", 0, minor: true,
        .init("舞段 A", "A", "Am | G | F | E7 | Am | G | F | E7"),
        .init("舞段 B", "C", "Dm | Am | F | E7 | Am | G | F E7 | Am"))
    static let bachata = Self("巴恰塔情歌", "用小调 i–VI–III–VII 建立吉他循环，答句回到小调属七。", 1, minor: true,
        .init("主歌", "A", "Am | F | C | G | Am | F | C | G"),
        .init("副歌", "C", "Am | G | F | E7 | Am | G | F | Am"))
    static let caribbean = Self("加勒比循环舞曲", "主属轮替维持舞步，副段短暂进入关系小调后回到主和弦。", 0,
        .init("第一舞段", "A", "C | G7 | C | G7 | C | F | G7 | C"),
        .init("应答舞段", "C", "Am | G | F | G | Am | F | G7 | C"))
    static let latinPop = Self("拉丁流行", "主歌围绕小调与下属，副歌使用关系大调和四和弦循环。", 0, minor: true,
        .init("主歌", "A", "Am | Dm | E7 | Am | Am | F | Dm | E7", fill: true),
        .init("副歌", "C", "C | G | Am | F | C | G | E7 | Am"))
    static let western = Self("西部叙事", "小调属七与开放五度形成西部配乐色彩，中段暂转关系大调。", 1, minor: true,
        .init("行进主题", "A", "Am | Am | G | Am | Dm | Am | E7 | Am"),
        .init("远景", "C", "C | G | F | C | Dm | Am | E7 | Am"))
    static let cinematic = Self("电影主题", "从主调与转位低音出发，中段铺陈下属区，再以挂留属和弦收束。", 2,
        .init("主题", "A", "Cadd9 | G/B | Am7 | Fmaj7 | C/E | F | Dm7 | Gsus4"),
        .init("展开", "D", "Fmaj7 | Am7 | C | G | Fadd9 | Dm7 | Gsus4 G | C"))
    static let cinematicMinor = Self("小调电影配乐", "小调主和弦与降六级制造悬念，对比段用关系大调短暂提亮。", -1, minor: true,
        .init("铺陈", "A", "Am | Am | Fmaj7 | E7sus4 | Am | G | Dm | E7"),
        .init("高潮", "D", "F | C | G | Am | Dm | F | E7 | Am"))
}
