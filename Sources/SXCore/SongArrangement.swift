import Foundation

public struct SongArrangement: Codable {
    public struct Cue: Codable, Identifiable {
        public enum Action: String, CaseIterable, Codable, Identifiable {
            case chord = "和弦", tempo = "速度", section = "段落", ots = "OTS", pad = "Pad", memory = "注册记忆"
            public var id: Self { self }
        }

        public let id: UUID
        public var beat: Double
        public var action: Action
        public var value: String

        public init(beat: Double, action: Action, value: String) {
            id = UUID()
            self.beat = beat
            self.action = action
            self.value = value
        }

        public func chordValue() -> Chord? {
            let input = value.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭")
            for root in 0..<12 {
                for quality in Chord.Quality.allCases {
                    let chord = Chord(root: root, quality: quality)
                    if input == chord.name { return chord }
                    for bass in 0..<12 where bass != root {
                        let inverted = Chord(root: root, quality: quality, bass: bass)
                        if input == inverted.name { return inverted }
                    }
                }
            }
            return nil
        }
    }

    public var title: String
    public var cues: [Cue]

    public init(title: String = "新歌曲", cues: [Cue] = []) {
        self.title = title
        self.cues = cues
    }

    public func ordered(for style: Style) throws -> [Cue] {
        for cue in cues {
            guard cue.beat.isFinite, (0...100_000).contains(cue.beat) else {
                throw StyleError.invalid("歌曲拍号位置无效")
            }
            let valid: Bool
            switch cue.action {
            case .chord: valid = cue.chordValue() != nil
            case .tempo: valid = Double(cue.value).map { (20...400).contains($0) } ?? false
            case .section: valid = style.sections.contains { $0.name == cue.value }
            case .ots: valid = Int(cue.value).map { $0 >= 1 && $0 <= style.oneTouchSettings.count } ?? false
            case .pad: valid = Int(cue.value).map { (1...4).contains($0) } ?? false
            case .memory: valid = Int(cue.value).map { (1...16).contains($0) } ?? false
            }
            guard valid else { throw StyleError.invalid("第 \(cue.beat) 拍的\(cue.action.rawValue)「\(cue.value)」无效") }
        }
        return cues.sorted { $0.beat < $1.beat }
    }
}
