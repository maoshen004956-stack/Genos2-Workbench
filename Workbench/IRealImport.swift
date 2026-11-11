import Foundation

/// A decoded iReal Pro chart. Bars use the workbench's editable chord syntax.
struct IRealSong {
    struct Section {
        var name: String
        var bars: [String]
    }

    var title: String
    var composer: String
    var style: String
    var key: SongKey
    var meter: SongMeter?
    var bpm: Double?
    var sections: [Section]
    var warnings: [String]
}

/// Native implementation of the documented chart language, without executing HTML.
/// Format reference: https://www.irealpro.com/ireal-pro-custom-chord-chart-protocol/
/// The modern URI's symmetric 50-character permutation and compressed tokens were
/// verified against https://github.com/pianosnake/ireal-reader (unscramble.js, Parser.js).
/// No third-party parser code or dependency is included.
enum IRealImport {
    static func parse(data: Data) throws -> [IRealSong] {
        guard data.count <= 10_000_000 else { throw invalid("iReal Pro 文件过大，请分批导入（最大 10 MB）。") }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw invalid("无法读取文件文字，请使用 iReal Pro 分享导出的 HTML 或 UTF-8 文本。")
        }
        let pattern = #"(?i)(?:irealb|irealbook)://[^\"'<>\r\n]+"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let plainLinks = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.lowercased().hasPrefix("irealb://") || $0.lowercased().hasPrefix("irealbook://") }
        let links = plainLinks.isEmpty ? matches.compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        } : plainLinks
        guard !links.isEmpty else {
            throw invalid("没有找到 iReal Pro 歌曲链接。请在 iReal Pro 中分享歌曲或播放列表，导出 HTML 文件后导入；也可以导入包含 irealb:// 或 irealbook:// 链接的文本。")
        }
        var seen = Set<String>()
        var songs: [IRealSong] = []
        for rawLink in links {
            let link = decodeEntities(rawLink.trimmingCharacters(in: .whitespacesAndNewlines))
            guard seen.insert(link).inserted else { continue }
            guard let divider = link.range(of: "://") else { continue }
            let encoded = String(link[divider.upperBound...])
            guard let decoded = encoded.removingPercentEncoding else {
                throw invalid("iReal Pro 链接含损坏的百分号编码，请重新从 iReal Pro 分享导出。")
            }
            let modern = String(link[..<divider.lowerBound]).lowercased() == "irealb"
            songs += try records(decoded, modern: modern)
            guard songs.count <= 1_000 else { throw invalid("一次最多导入 1000 首，请拆分播放列表。") }
        }
        guard !songs.isEmpty else { throw invalid("iReal Pro 文件中没有完整歌曲。") }
        return songs
    }

    private static func records(_ text: String, modern: Bool) throws -> [IRealSong] {
        let fields = text.components(separatedBy: "=")
        var position = 0
        var result: [IRealSong] = []
        while position < fields.count {
            if !result.isEmpty {
                // Modern playlists separate ten-field song records with ===.
                while position < fields.count && fields[position].isEmpty { position += 1 }
                if position >= fields.count || fields.count - position == 1 { break } // playlist title
            }
            guard result.count < 1_000 else { throw invalid("一次最多导入 1000 首，请拆分播放列表。") }
            let remaining = fields.count - position
            if modern {
                guard remaining >= 10, fields[position + 6].hasPrefix("1r34LbKcu7") else {
                    throw invalid("iReal Pro 歌曲资料不完整或链接版本不受支持（歌曲 \(result.count + 1)）。请重新导出 HTML。")
                }
                let title = fields[position].trimmingCharacters(in: .whitespacesAndNewlines)
                var notes: [String] = []
                let bpmValue = fields[position + 8]
                let bpm: Double?
                if bpmValue.isEmpty || bpmValue == "0" { bpm = nil }
                else if let value = Double(bpmValue), value.isFinite, (20...400).contains(value) { bpm = value }
                else { throw invalid("「\(title)」的速度「\(bpmValue)」超出 20–400 BPM，请在原谱中调整。") }
                if let choruses = Int(fields[position + 9]), choruses > 1 {
                    notes.append("iReal Pro 设定了整曲播放 \(choruses) 遍；本次导入一遍完整曲式，谱内反复已展开。可在段落编排中复制整曲。")
                }
                let music = unscramble(String(fields[position + 6].dropFirst(10)))
                result.append(try song(title: title, composer: fields[position + 1], style: fields[position + 3],
                                       key: fields[position + 4], music: music, bpm: bpm, warnings: notes))
                position += 10
            } else {
                guard remaining >= 6 else { throw invalid("旧版 iRealbook 链接不完整（每首歌曲需要六个字段）。") }
                result.append(try song(title: fields[position], composer: fields[position + 1], style: fields[position + 2],
                                       key: fields[position + 3], music: fields[position + 5], bpm: nil, warnings: []))
                position += 6
            }
        }
        return result
    }

    private static func song(title: String, composer: String, style: String, key: String,
                             music: String, bpm: Double?, warnings: [String]) throws -> IRealSong {
        let title = title.isEmpty ? "未命名歌曲" : title
        var warnings = warnings
        let songKey = try parseKey(key, warnings: &warnings)
        var parser = MusicParser(music, title: title)
        let sections = try parser.parse()
        if parser.meter == nil { warnings.append("原谱没有拍号；导入时使用所选伴奏风格的拍号。") }
        if bpm == nil { warnings.append("原谱没有指定速度；导入时使用所选伴奏风格的默认速度。") }
        warnings += parser.warnings
        return IRealSong(title: title, composer: composer, style: style, key: songKey, meter: parser.meter,
                         bpm: bpm, sections: sections, warnings: Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings)
    }

    private static func parseKey(_ source: String, warnings: inout [String]) throws -> SongKey {
        let value = source.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "♯", with: "#")
        if value.isEmpty || value == "n" {
            warnings.append("原谱未指定调号，暂用 C 大调；导入后可以调整。")
            return .cMajor
        }
        let minor = value.hasSuffix("-") || value.hasSuffix("m")
        let root = minor ? String(value.dropLast()) : value
        let major = ["Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#"]
        let minorNames = ["Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#", "G#", "D#", "A#"]
        guard let index = (minor ? minorNames : major).firstIndex(of: root) else {
            throw invalid("无法识别 iReal Pro 调号「\(source)」。")
        }
        return SongKey(fifths: index - 7, minor: minor)
    }

    private static func unscramble(_ value: String) -> String {
        let source = Array(value)
        var output = source
        var offset = 0
        // Leave the final <= 51 characters intact, exactly as the wire format requires.
        while source.count - offset > 51 {
            for slot in Array(0..<5) + Array(10..<24) {
                output.swapAt(offset + slot, offset + 49 - slot)
            }
            offset += 50
        }
        return String(output)
            .replacingOccurrences(of: "XyQ", with: "   ")
            .replacingOccurrences(of: "LZ", with: " |")
            .replacingOccurrences(of: "Kcl", with: "| x")
    }

    private static func decodeEntities(_ value: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let range = Range(match.range, in: result), let digitsRange = Range(match.range(at: 1), in: result) else { continue }
            let digits = String(result[digitsRange])
            let number = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            if let number, let scalar = UnicodeScalar(number) { result.replaceSubrange(range, with: String(scalar)) }
        }
        return result.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private struct MusicParser {
        struct Event { var chord: String; var slot: Int }
        struct Bar {
            var events: [Event]
            var slots: Int
            var name: String
            var sectionStart: Bool
            var repeatStart: Bool
            var repeatEnd: Int?
            var ending: Int?
        }
        let input: [Character]
        let title: String
        var index = 0
        var meter: SongMeter?
        var warnings: [String] = []
        var bars: [Bar] = []
        var events: [Event] = []
        var slots = 0
        var name = "主题"
        var sectionStart = true
        var repeatStart = false
        var repeatCount = 2
        var ending: Int?
        var previousChord: String?
        var repeatPrevious: Int?
        var twoBarRemainder: Bar?

        init(_ music: String, title: String) { self.input = Array(music); self.title = title }

        mutating func parse() throws -> [IRealSong.Section] {
            guard input.count <= 100_000 else { throw problem("谱面过大，请拆分歌曲") }
            while index < input.count {
                let char = input[index]
                switch char {
                case " ": slots += 1; index += 1
                case "\t", "\r", "\n", ",", "Y", "s", "l", "U": index += 1
                case "|", "]", "Z": try closeBar(); index += 1
                case "[":
                    try closeBar()
                    if !bars.isEmpty { sectionStart = true }
                    index += 1
                case "{":
                    try closeBar(); repeatStart = true; index += 1
                case "}":
                    try closeBar()
                    guard !bars.isEmpty else { throw problem("反复结束符之前没有小节") }
                    guard bars[bars.count - 1].repeatEnd == nil else { throw problem("同一小节有重复的反复结束符") }
                    bars[bars.count - 1].repeatEnd = repeatCount
                    repeatCount = 2
                    index += 1
                case "*":
                    try closeBar()
                    index += 1
                    guard index < input.count, input[index].isLetter || input[index].isNumber else { throw problem("段落标识不完整") }
                    let mark = input[index]
                    name = mark == "i" ? "前奏" : (mark == "V" ? "主歌" : String(mark))
                    sectionStart = true; index += 1
                case "T": try timeSignature()
                case "N":
                    try closeBar(); index += 1
                    guard index < input.count, let number = Int(String(input[index])), number == 1 || number == 2 else {
                        throw problem("目前支持第一、第二结尾；请先在 iReal Pro 中展开其他编号结尾")
                    }
                    ending = number; index += 1
                case "<": try annotation()
                case "(": try alternativeChord()
                case "x", "r":
                    guard events.isEmpty, repeatPrevious == nil else { throw problem("小节重复符与其他和弦重叠") }
                    repeatPrevious = char == "x" ? 1 : 2; slots = 0; index += 1
                case "p":
                    guard previousChord != nil || !events.isEmpty else { throw problem("延续和弦符号 p 前没有和弦") }
                    slots += 1; index += 1
                case "n": throw problem("第 \(bars.count + 1) 小节含 N.C.（无和弦），当前伴奏引擎尚不支持，请先为该小节选择和弦")
                case "S", "Q", "f":
                    if char == "f" { warn("延长记号按原小节长度播放；导入后可调整速度或小节。") }
                    else { warn("谱中含 Segno/Coda 跳转标记；没有跳转指令时按书写顺序导入。") }
                    index += 1
                case "A"..."G", "W": try chord()
                default:
                    throw problem("第 \(bars.count + 1) 小节包含暂不支持的谱面符号「\(char)」")
                }
                guard bars.count <= 2_048 else { throw problem("原谱超过 2048 小节，请拆分导入") }
            }
            try closeBar()
            guard !bars.isEmpty else { throw problem("没有找到可播放的和弦小节") }
            guard !repeatStart, ending == nil else { throw problem("谱尾的反复或结尾标记后没有小节") }
            guard twoBarRemainder == nil else { throw problem("双小节重复符 r 后缺少第二小节") }
            if meter == nil && bars.contains(where: { $0.events.count > 1 }) {
                warn("原谱未指定拍号，同小节的多个和弦暂按均分处理；导入后可填写拍数调整。")
            }
            let expanded = try expandRepeats()
            var sections: [IRealSong.Section] = []
            for bar in expanded {
                if sections.isEmpty || bar.sectionStart || sections.last?.name != bar.name {
                    sections.append(.init(name: bar.name, bars: []))
                }
                sections[sections.count - 1].bars.append(render(bar))
            }
            return sections
        }

        mutating func timeSignature() throws {
            index += 1
            let start = index
            while index < input.count && input[index].isNumber { index += 1 }
            let code = String(input[start..<index])
            let table = ["22": SongMeter(2, 2), "32": SongMeter(3, 2), "24": SongMeter(2, 4),
                         "34": SongMeter(3, 4), "44": SongMeter(4, 4), "54": SongMeter(5, 4),
                         "64": SongMeter(6, 4), "74": SongMeter(7, 4), "38": SongMeter(3, 8),
                         "58": SongMeter(5, 8), "68": SongMeter(6, 8), "78": SongMeter(7, 8),
                         "98": SongMeter(9, 8), "12": SongMeter(12, 8)]
            guard let value = table[code] else { throw problem("无法识别拍号 T\(code)") }
            if let meter, meter != value { throw problem("原谱中途从 \(meter.name) 变为 \(value.name)，当前整曲使用统一拍号，请先拆分变拍段落") }
            meter = value
        }

        mutating func annotation() throws {
            let start = index + 1
            guard let end = input[start...].firstIndex(of: ">") else { throw problem("谱面文字缺少 > 结束符") }
            var text = String(input[start..<end]).trimmingCharacters(in: .whitespaces)
            index = end + 1
            text = text.replacingOccurrences(of: #"^\*\d+"#, with: "", options: .regularExpression)
            let lower = text.lowercased().replacingOccurrences(of: " ", with: "")
            if lower.range(of: #"^(d\.?c\.?|d\.?s\.?|tocoda|alcoda|dacapo|dalsegno)"#, options: .regularExpression) != nil {
                throw problem("含跳转指令「\(text)」，目前请先在 iReal Pro 中展开 D.C./D.S./Coda 跳转后导入，避免段落顺序错误")
            }
            if lower.range(of: #"^[0-9]+x$"#, options: .regularExpression) != nil {
                guard let count = Int(lower.dropLast()), (2...16).contains(count) else {
                    throw problem("单段反复次数需要在 2–16 遍之间，请先减少「\(text)」")
                }
                repeatCount = count
            } else if !text.isEmpty {
                warn("谱面文字「\(text)」仅作说明，未转换为演奏动作。")
            }
        }

        mutating func alternativeChord() throws {
            let start = index + 1
            guard let end = input[start...].firstIndex(of: ")") else { throw problem("备选和弦缺少 ) 结束符") }
            let value = String(input[start..<end])
            warn("括号中的备选和弦（\(value)）未替代主和弦。")
            index = end + 1
        }

        mutating func chord() throws {
            guard repeatPrevious == nil else { throw problem("小节重复符不能和其他和弦放在同一小节") }
            let start = index
            index += 1
            let suffixChars = Set("0123456789b#♭♯-+^ø°abcdefghijklmnopqrstuvwxyz/")
            while index < input.count {
                let char = input[index]
                if let word = ["mMaj", "sus", "min", "maj", "dim", "aug", "add", "alt"].first(where: { starts($0) }) {
                    index += word.count
                    continue
                }
                if char == "/" {
                    index += 1
                    if index < input.count, ("A"..."G").contains(input[index]) {
                        index += 1
                        if index < input.count && "b#♭♯".contains(input[index]) { index += 1 }
                        break
                    }
                } else if suffixChars.contains(char) {
                    // p, s, l, n are chart operators, unless they are inside a named quality.
                    if char == "p" || char == "n" { break }
                    if char == "s" { break }
                    if char == "l" && index > start && input[index - 1] != "a" { break }
                    index += 1
                } else if char == "(", starts("(add") {
                    guard let end = input[index...].firstIndex(of: ")") else { throw problem("和弦扩展音缺少右括号") }
                    index = end + 1
                } else { break }
            }
            let raw = String(input[start..<index])
            let normalized = try normalize(raw)
            if events.isEmpty && slots > 0 {
                if let previousChord { events.append(Event(chord: previousChord, slot: 0)) }
                else { slots = 0 }
            }
            events.append(Event(chord: normalized, slot: slots))
            slots += 1
            previousChord = normalized
        }

        func starts(_ value: String) -> Bool { input[index...].starts(with: Array(value)) }

        func normalize(_ raw: String) throws -> String {
            var source = raw.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
            if source.hasPrefix("W/") {
                guard let previousChord else { throw problem("第 \(bars.count + 1) 小节的转位低音前没有和弦") }
                var harmony = previousChord
                if let slash = harmony.lastIndex(of: "/"), let first = harmony[harmony.index(after: slash)...].first,
                   ("A"..."G").contains(first) { harmony = String(harmony[..<slash]) }
                source = harmony + source.dropFirst()
            }
            let chars = Array(source)
            let rootCount = chars.count > 1 && "b#".contains(chars[1]) ? 2 : 1
            let root = String(chars.prefix(rootCount))
            var quality = String(chars.dropFirst(rootCount))
            var bass = ""
            if let slash = quality.lastIndex(of: "/"), let first = quality[quality.index(after: slash)...].first, ("A"..."G").contains(first) {
                bass = String(quality[slash...]); quality = String(quality[..<slash])
            }
            let aliases = ["-": "m", "-7": "m7", "-6": "m6", "-9": "m9", "-11": "m11",
                           "-^7": "mMaj7", "-^9": "mMaj9", "-7b5": "m7b5", "-(add9)": "m(add9)",
                           "^": "maj7", "^7": "maj7", "^9": "maj9", "^7#11": "maj7#11", "^7#5": "maj7#5",
                           "+": "aug", "o": "dim", "o7": "dim7", "°": "dim", "°7": "dim7",
                           "h": "m7b5", "h7": "m7b5", "ø": "m7b5", "ø7": "m7b5", "69": "6/9",
                           "2": "sus2", "sus": "sus4", "7sus": "7sus4"]
            let converted = root + (aliases[quality] ?? quality) + bass
            guard parseChord(Substring(converted)) != nil else {
                throw problem("第 \(bars.count + 1) 小节的和弦「\(raw)」暂不支持；请在原谱中改成可用和弦后导入（不会自动删掉变音或扩展音）")
            }
            return converted
        }

        mutating func closeBar() throws {
            if let remainder = twoBarRemainder {
                guard events.isEmpty && repeatPrevious == nil else { throw problem("双小节重复符 r 的第二小节必须留空") }
                var copied = remainder
                copied.name = name; copied.sectionStart = sectionStart; copied.repeatStart = repeatStart
                copied.repeatEnd = nil; copied.ending = ending
                bars.append(copied); twoBarRemainder = nil
                previousChord = copied.events.last?.chord
            } else if let previous = repeatPrevious {
                guard bars.count >= previous else { throw problem("第 \(bars.count + 1) 小节没有足够的前置小节可供重复") }
                if previous == 2 { twoBarRemainder = bars[bars.count - 1] }
                let template = bars[bars.count - previous]
                bars.append(Bar(events: template.events, slots: template.slots, name: name, sectionStart: sectionStart,
                                repeatStart: repeatStart, repeatEnd: nil, ending: ending))
                previousChord = template.events.last?.chord
            } else if !events.isEmpty {
                bars.append(Bar(events: events, slots: max(slots, 1), name: name, sectionStart: sectionStart,
                                repeatStart: repeatStart, repeatEnd: nil, ending: ending))
            } else if slots >= 3 {
                guard let previousChord, !bars.isEmpty else { throw problem("开头的空小节没有可延续的和弦") }
                bars.append(Bar(events: [Event(chord: previousChord, slot: 0)], slots: slots, name: name,
                                sectionStart: sectionStart, repeatStart: repeatStart, repeatEnd: nil, ending: ending))
            } else {
                slots = 0
                return
            }
            events = []; slots = 0; repeatPrevious = nil
            sectionStart = false; repeatStart = false; ending = nil
        }

        func expandRepeats() throws -> [Bar] {
            struct Frame { var start: Int; var firstEnding: Int? }
            var frames: [Frame] = []
            var output: [Bar] = []
            var expectSecondEnding = false
            for bar in bars {
                if bar.repeatStart { frames.append(Frame(start: output.count, firstEnding: nil)) }
                if bar.ending == 1 {
                    if frames.isEmpty { frames.append(Frame(start: 0, firstEnding: nil)) }
                    guard frames[frames.count - 1].firstEnding == nil else { throw problem("同一反复段有多个第一结尾") }
                    frames[frames.count - 1].firstEnding = output.count
                }
                if bar.ending == 2 {
                    guard expectSecondEnding else { throw problem("第二结尾前没有对应的第一结尾和反复结束符") }
                    expectSecondEnding = false
                } else if expectSecondEnding { throw problem("第一结尾反复后没有紧接第二结尾") }
                output.append(bar)
                if let count = bar.repeatEnd {
                    let frame = frames.popLast() ?? Frame(start: 0, firstEnding: nil)
                    guard frame.start < output.count else { throw problem("反复段没有小节") }
                    if frame.firstEnding != nil && count != 2 { throw problem("编号结尾与多次反复混用，请先在原谱中展开") }
                    var repeated = Array(output[frame.start..<(frame.firstEnding ?? output.count)])
                    if !repeated.isEmpty { repeated[0].sectionStart = true }
                    guard output.count + repeated.count * (count - 1) <= 4_096 else { throw problem("展开反复后超过 4096 小节，请减少反复次数") }
                    for _ in 1..<count { output += repeated }
                    expectSecondEnding = frame.firstEnding != nil
                }
            }
            guard frames.isEmpty else { throw problem("反复开始符 { 缺少对应的结束符 }") }
            guard !expectSecondEnding else { throw problem("第一结尾后缺少第二结尾") }
            return output
        }

        func render(_ bar: Bar) -> String {
            var events: [Event] = []
            for event in bar.events {
                if events.last?.chord != event.chord { events.append(event) }
            }
            if events.count == 1 { return events[0].chord }
            // With no declared meter, equal spacing remains editable and adapts to the chosen style.
            guard let meter else { return events.map(\.chord).joined(separator: " ") }
            let durations = events.enumerated().map { position, event in
                Double((position + 1 < events.count ? events[position + 1].slot : bar.slots) - event.slot) * Double(meter.beats) / Double(bar.slots)
            }
            // Equal changes can use the concise syntax, including 1.5 + 1.5 in 3/4.
            if durations.allSatisfy({ abs($0 - durations[0]) < 0.00001 }) { return events.map(\.chord).joined(separator: " ") }
            return zip(events, durations).map { event, duration in
                let formatted = String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), duration)
                    .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
                return "\(event.chord):\(formatted)"
            }.joined(separator: " ")
        }

        mutating func warn(_ message: String) { if !warnings.contains(message) { warnings.append(message) } }
        func problem(_ message: String) -> Error { invalid("「\(title)」：\(message)。") }
    }
}
