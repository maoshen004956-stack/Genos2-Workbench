import SXCore

struct PartMix: Codable, Equatable {
    var program: UInt8? = nil
    var volume: UInt8? = nil
    var pan: UInt8? = nil
    var reverb: UInt8? = nil

    var isValid: Bool { [program, volume, pan, reverb].compactMap { $0 }.allSatisfy { $0 < 128 } }
    var isDefault: Bool { program == nil && volume == nil && pan == nil && reverb == nil }
}

let generalMIDIDrumKits: [(program: UInt8, name: String)] = [
    (0, "标准鼓组"), (8, "房间鼓组"), (16, "强力鼓组"), (24, "电子鼓组"), (25, "808 鼓组"),
    (32, "爵士鼓组"), (40, "鼓刷鼓组"), (48, "管弦打击乐"), (56, "音效打击乐")
]

enum AccompanimentPart: UInt8, CaseIterable, Codable, Identifiable {
    case rhythm1 = 8, rhythm2, bass, chord1, chord2, pad, phrase1, phrase2

    var id: Self { self }
    var isDrum: Bool { self == .rhythm1 || self == .rhythm2 }
    var channel: UInt8 { isDrum ? 9 : rawValue }

    var name: String {
        switch self {
        case .rhythm1: return "节奏 1"
        case .rhythm2: return "节奏 2"
        case .bass: return "贝斯"
        case .chord1: return "和弦 1"
        case .chord2: return "和弦 2"
        case .pad: return "铺底"
        case .phrase1: return "乐句 1"
        case .phrase2: return "乐句 2"
        }
    }

    func voice(in style: Style) -> Style.VoiceAddress {
        style.voices[rawValue] ?? .init(msb: 0, lsb: 0, program: self == .bass ? 33 : 0)
    }

    func program(in style: Style) -> UInt8 {
        isDrum ? YamahaVoices.drumProgram(voice(in: style)) : YamahaVoices.melodicProgram(voice(in: style),
                                                  guitar: style.guitarChannels.contains(rawValue), bass: self == .bass)
    }

    func instrumentName(in style: Style) -> String {
        if isDrum { return voice(in: style).msb == 126 ? "打击乐" : "鼓组" }
        return generalMIDIInstrumentNames[Int(program(in: style))]
    }
}

// General MIDI Level 1 program order, zero-based as stored in MIDI messages.
let generalMIDIInstrumentNames = [
    "三角钢琴", "明亮钢琴", "电三角钢琴", "酒吧钢琴", "电钢琴 1", "电钢琴 2", "羽管键琴", "击弦古钢琴",
    "钢片琴", "钟琴", "八音盒", "颤音琴", "马林巴", "木琴", "管钟", "扬琴",
    "拉杆风琴", "打击式风琴", "摇滚风琴", "教堂管风琴", "簧风琴", "手风琴", "口琴", "探戈手风琴",
    "尼龙弦吉他", "钢弦吉他", "爵士电吉他", "清音电吉他", "闷音电吉他", "过载吉他", "失真吉他", "吉他泛音",
    "原声贝斯", "指弹电贝斯", "拨片电贝斯", "无品贝斯", "拍弦贝斯 1", "拍弦贝斯 2", "合成贝斯 1", "合成贝斯 2",
    "小提琴", "中提琴", "大提琴", "低音提琴", "弦乐颤弓", "弦乐拨奏", "竖琴", "定音鼓",
    "弦乐合奏 1", "弦乐合奏 2", "合成弦乐 1", "合成弦乐 2", "人声合唱", "人声哼唱", "合成人声", "管弦重击",
    "小号", "长号", "大号", "弱音小号", "圆号", "铜管合奏", "合成铜管 1", "合成铜管 2",
    "高音萨克斯", "中音萨克斯", "次中音萨克斯", "上低音萨克斯", "双簧管", "英国管", "巴松", "单簧管",
    "短笛", "长笛", "竖笛", "排箫", "吹瓶声", "尺八", "哨笛", "陶笛",
    "方波主音", "锯齿波主音", "风琴式主音", "吹管式主音", "铜管式主音", "人声式主音", "五度主音", "贝斯与主音",
    "新世纪铺底", "温暖铺底", "复音铺底", "合唱铺底", "弓弦铺底", "金属铺底", "光环铺底", "扫频铺底",
    "雨滴音效", "电影音效", "水晶音效", "氛围音效", "明亮音效", "精灵音效", "回声音效", "科幻音效",
    "西塔琴", "班卓琴", "三味线", "日本筝", "卡林巴", "风笛", "民谣提琴", "唢呐",
    "叮当铃", "阿戈戈铃", "钢鼓", "木鱼", "太鼓", "旋律鼓", "合成鼓", "反向镲",
    "吉他滑弦声", "呼吸声", "海浪声", "鸟鸣", "电话铃声", "直升机声", "掌声", "枪声"
]
