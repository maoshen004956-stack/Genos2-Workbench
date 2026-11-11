struct GuitarFingering {
    private static let slots = [2, 4, 5, 7, 9, 11]
    private static let tuning = [40, 45, 50, 55, 59, 64]
    private static let openMajor: [Int: [Int?]] = [
        0: [nil, 3, 2, 0, 1, 0], 2: [nil, 0, 0, 2, 3, 2],
        4: [0, 2, 2, 1, 0, 0], 7: [3, 2, 0, 0, 0, 3], 9: [nil, 0, 2, 2, 2, 0]
    ]
    private static let openMinor: [Int: [Int?]] = [
        2: [nil, 0, 0, 2, 3, 1], 4: [0, 2, 2, 0, 0, 0], 9: [nil, 0, 2, 2, 1, 0]
    ]

    private let strings: [Int?]
    private let arpeggio: [Int]
    private let root: Int

    init(chord: Chord) {
        root = chord.root
        let minor = chord.quality.isMinor
        let e = (chord.root + 8) % 12
        let a = (chord.root + 3) % 12
        let eShape: [Int?] = [e, e + 2, e + 2, e + (minor ? 0 : 1), e, e]
        let aShape: [Int?] = [nil, a, a + 2, a + 2, a + (minor ? 1 : 2), a]
        let open = minor ? Self.openMinor[chord.root] : Self.openMajor[chord.root]
        let fitted = [open, eShape, aShape].compactMap { $0 }.map { Self.fit($0, to: chord) }
        let selected = fitted.min { $0.score < $1.score }?.notes ?? eShape
        strings = selected
        arpeggio = selected.compactMap { $0 }
    }

    func note(for trigger: Int, table: UInt8, bassRoot: Int) -> Int? {
        let slot = trigger % 12
        if slot == 0 { return 40 + (bassRoot + 8) % 12 }
        if slot == 1 {
            guard strings.first == .some(nil) else { return nil }
            return 60 + (root + 7) % 12
        }
        guard let string = Self.slots.firstIndex(of: slot) else { return nil }
        if table == 2 {
            // Factory parts use a lower and an upper trigger register. Each selects four chord tones.
            let indices = trigger < 60 ? Array(arpeggio.prefix(4)) : Array(arpeggio.suffix(4))
            let index = string >= 2 ? string - 2 : string
            return indices.indices.contains(index) ? indices[index] : nil
        }
        return strings[string]
    }

    private static func fit(_ frets: [Int?], to chord: Chord) -> (score: Int, notes: [Int?]) {
        let intervals = Set(chord.quality.intervals)
        let start = frets.compactMap { $0 }.min() ?? 0
        let first = frets.firstIndex { $0 != nil }
        let candidates = zip(tuning, frets).enumerated().map { index, string -> [Int?] in
            let (open, fret) = string
            guard let fret else { return [nil] }
            return (-2...2).compactMap { offset -> Int? in
                let position = fret + offset
                let note = open + position
                let interval = (note - chord.root + 120) % 12
                guard position >= max(0, start - 1), position <= start + 4,
                      intervals.contains(interval), index != first || interval == 0
                        || (chord.root == 2 && index == 1 && position == 0) else { return nil }
                return note
            }.map(Optional.some) + [nil]
        }

        var best = (score: Int.max, notes: frets)
        func choose(_ notes: [Int?], score: Int) {
            let index = notes.count
            if index == tuning.count {
                let present = Set(notes.compactMap { $0 }.map { ($0 - chord.root + 120) % 12 })
                let total = score + 16 * intervals.subtracting(present).count
                if total < best.score { best = (total, notes) }
                return
            }
            for candidate in candidates[index] {
                let cost = candidate.map { abs($0 - tuning[index] - (frets[index] ?? 0)) }
                    ?? (frets[index] == nil ? 0 : 4)
                if score + cost < best.score { choose(notes + [candidate], score: score + cost) }
            }
        }
        choose([], score: start)
        return best
    }
}
