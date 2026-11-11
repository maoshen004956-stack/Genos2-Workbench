import Foundation

struct PreviewTimeline {
    struct Position: Equatable {
        let sectionID: UUID
        let barNumber: Int
        let barIndex: Int
        let chord: String?
        let chordIndex: Int?
    }

    private struct ChordChange {
        let tick: Int
        let symbol: String
        let indexInBar: Int
    }

    private let sections: [(tick: Int, id: UUID)]
    private let changes: [ChordChange]
    private let ticksPerBar: Int
    private let totalTicks: Int
    private let secondsPerTick: Double

    var duration: Double { Double(totalTicks) * secondsPerTick }

    init(arrangement: ArrangementResult, chart: Chart, sectionIDs: [UUID]) {
        let barLength = arrangement.ticksPerBar
        ticksPerBar = barLength
        totalTicks = arrangement.duration
        let microsecondsPerQuarter = (60_000_000 / arrangement.bpm).rounded()
        secondsPerTick = microsecondsPerQuarter / (1_000_000 * Double(arrangement.style.ticksPerQuarter))
        sections = zip(arrangement.markers, sectionIDs).map { ($0.0.tick, $0.1) }

        // The renderer preserves the order of the written chord tokens, including repetitions.
        let written = chart.segments.flatMap(\.bars).flatMap { bar in
            bar.split(whereSeparator: \.isWhitespace).map { String($0.prefix { $0 != ":" }) }
        }
        var previousBar = -1
        var indexInBar = 0
        changes = arrangement.harmony.enumerated().map { index, event in
            let bar = event.tick / barLength
            indexInBar = bar == previousBar ? indexInBar + 1 : 0
            previousBar = bar
            let symbol = written.indices.contains(index) ? written[index] : event.chord.name
            return ChordChange(tick: event.tick, symbol: symbol, indexInBar: indexInBar)
        }
    }

    func position(at seconds: Double) -> Position? {
        let tick = min(totalTicks - 1, Int(min(duration, max(0, seconds)) / secondsPerTick))
        guard let section = Self.latest(in: sections, at: tick, tick: { $0.tick }) else { return nil }
        let bar = tick / ticksPerBar
        let change = Self.latest(in: changes, at: tick, tick: \.tick)
        // An unwritten bar sustains the last chord, including tails of intros and endings.
        let chordIndex = change.flatMap { $0.tick / ticksPerBar == bar ? $0.indexInBar : nil }
        return Position(sectionID: section.id, barNumber: bar + 1, barIndex: (tick - section.tick) / ticksPerBar,
                        chord: change?.symbol, chordIndex: chordIndex)
    }

    private static func latest<T>(in events: [T], at position: Int, tick: (T) -> Int) -> T? {
        var low = 0
        var high = events.count
        while low < high {
            let middle = low + (high - low) / 2
            if tick(events[middle]) <= position { low = middle + 1 }
            else { high = middle }
        }
        return low > 0 ? events[low - 1] : nil
    }
}
