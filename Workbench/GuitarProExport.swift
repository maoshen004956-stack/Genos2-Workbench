import Foundation
import JavaScriptCore
import SXCore

enum NotationExport {
    private struct Input: Encodable {
        struct Track: Encodable {
            let name: String
            let program: UInt8
            let channel: UInt8
            let drum: Bool
            let bass: Bool
            let notes: [[Int]]
        }
        struct Label: Encodable {
            let tick: Int
            let text: String
            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                try container.encode(tick)
                try container.encode(text)
            }
        }

        let title: String
        let numerator: Int
        let denominator: Int
        let fifths: Int
        let minor: Bool
        let bpm: Double
        let ppq: Int
        let bars: Int
        let markers: [Label]
        let harmony: [Label]
        let tracks: [Track]
    }

    private static func render(_ arrangement: ArrangementResult, title: String, guitarPro: Bool) throws -> (JSContext, JSValue) {
        let format = guitarPro ? "Guitar Pro" : "MusicXML"
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("GuitarPro") else {
            throw invalid("找不到 \(format) 导出组件。")
        }
        let key = arrangement.key ?? .cMajor
        let names = ["节奏 1", "节奏 2", "贝斯", "和弦 1", "和弦 2", "铺底", "乐句 1", "乐句 2"]
        let tracks = arrangement.tracks.map { track in
            let program = track.events.first(where: { $0.midi.kind == 0xc0 })?.midi.data1 ?? 0
            let notes = track.events.compactMap { event -> [Int]? in
                let midi = event.midi
                guard midi.kind == 0x80 || midi.kind == 0x90 else { return nil }
                return [event.tick, Int(midi.data1), midi.kind == 0x80 ? 0 : Int(midi.data2)]
            }
            return Input.Track(name: names[Int(track.part) - 8], program: program, channel: track.channel,
                               drum: track.isDrum, bass: track.part == 10, notes: notes)
        }
        let input = Input(title: title, numerator: arrangement.meter.beats, denominator: arrangement.meter.unit,
                          fifths: key.fifths, minor: key.minor, bpm: arrangement.bpm, ppq: arrangement.style.ticksPerQuarter,
                          bars: arrangement.barCount,
                          markers: arrangement.markers.map { .init(tick: $0.tick, text: $0.name) },
                          harmony: arrangement.harmony.map {
                              let chord = $0.chord
                              let suffix = Chord(root: 0, quality: chord.quality).name.dropFirst()
                              let bass = chord.bass.map { "/" + key.spell($0) } ?? ""
                              return .init(tick: $0.tick, text: key.spell(chord.root) + suffix + bass)
                          },
                          tracks: tracks)
        let json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        guard let context = JSContext() else { throw invalid("无法启动 \(format) 导出组件。") }
        let scripts = guitarPro ? ["Headless.js", "alphaTab.min.js", "Export.js"] : ["Export.js", "MusicXML.js"]
        for name in scripts {
            let url = resources.appendingPathComponent(name)
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
            if let error = context.exception { throw invalid("无法加载 \(format) 导出组件：\(error.toString() ?? name)") }
        }
        let result = context.objectForKeyedSubscript(guitarPro ? "exportGuitarPro" : "exportMusicXML").call(withArguments: [json])
        if let error = context.exception { throw invalid("\(format) 导出失败：\(error.toString() ?? "")") }
        guard let result, !result.isUndefined else { throw invalid("\(format) 导出未返回文件。") }
        return (context, result)
    }

    static func musicXML(_ arrangement: ArrangementResult, title: String) throws -> Data {
        let (_, result) = try render(arrangement, title: title, guitarPro: false)
        guard let xml = result.toString(), xml.hasPrefix("<?xml") else { throw invalid("未能生成有效的 MusicXML 乐谱。") }
        return Data(xml.utf8)
    }

    static func write(_ arrangement: ArrangementResult, title: String, to destination: URL) throws {
        let (context, result) = try render(arrangement, title: title, guitarPro: true)
        var exception: JSValueRef?
        let size = JSObjectGetTypedArrayByteLength(context.jsGlobalContextRef, result.jsValueRef, &exception)
        guard exception == nil, size > 4,
              let bytes = JSObjectGetTypedArrayBytesPtr(context.jsGlobalContextRef, result.jsValueRef, &exception),
              exception == nil else { throw invalid("Guitar Pro 导出未返回有效数据。") }
        let data = Data(bytes: bytes, count: size)
        guard data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw invalid("导出的 Guitar Pro 文件无效。")
        }
        try data.write(to: destination, options: .atomic)
    }
}
