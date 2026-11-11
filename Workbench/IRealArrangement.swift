import Foundation
import SXCore

struct IRealImportBatch: Identifiable {
    let id = UUID()
    let songs: [IRealSong]
}

enum IRealArrangement {
    static func draft(song: IRealSong, entry: StyleEntry, style: Style) throws -> Draft {
        let mains = style.sections.map(\.name).filter { $0.hasPrefix("Main ") }.sorted()
        guard !mains.isEmpty else { throw invalid("这个风格没有可用的主奏段落。") }
        var patterns: [String: String] = [:]
        let blocks = try song.sections.map { section -> Draft.Block in
            let label = section.name
            if patterns[label] == nil { patterns[label] = mains[patterns.count % mains.count] }
            for (index, bar) in section.bars.enumerated() {
                _ = try chordChanges(in: bar, style: style, meter: song.meter,
                                     context: "\(song.title) · \(label) 第 \(index + 1) 小节")
            }
            return Draft.Block(name: label, pattern: patterns[label]!, bars: section.bars)
        }
        guard !blocks.isEmpty else { throw invalid("歌曲没有可播放的小节。") }
        return Draft(title: song.title, stylePath: entry.path,
                     bpm: song.bpm.map { String(format: "%g", $0) } ?? String(format: "%g", style.bpm),
                     key: song.key, meter: song.meter ?? SongMeter(style), blocks: blocks)
    }
}
