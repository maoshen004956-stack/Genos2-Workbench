import Foundation
import SXCore

@main
struct VerifyMix {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) {
        checks += 1
        precondition(value, label)
    }

    static func syntheticStyle() throws -> Style {
        func be(_ value: Int, _ count: Int) -> [UInt8] {
            (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        func chunk(_ name: String, _ body: [UInt8]) -> [UInt8] { Array(name.utf8) + be(body.count, 4) + body }
        func vlq(_ value: Int) -> [UInt8] {
            var value = value, bytes = [UInt8(value & 127)]
            value >>= 7
            while value > 0 { bytes.insert(UInt8(value & 127) | 128, at: 0); value >>= 7 }
            return bytes
        }
        var track: [UInt8] = []
        var cursor = 0
        func event(_ tick: Int, _ bytes: [UInt8]) { track += vlq(tick - cursor) + bytes; cursor = tick }
        func marker(_ name: String) { event(0, [0xff, 6, UInt8(name.utf8.count)] + Array(name.utf8)) }
        marker("SFF2")
        for (channel, program, volume, expression, pan, reverb): (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) in [
            (8, 0, 64, 100, 16, 20), (9, 40, 100, 127, 112, 80), (11, 1, 50, 80, 10, 32)
        ] {
            let bank: UInt8 = channel < 10 ? 127 : 8
            event(0, [0xb0 | channel, 0, bank])
            event(0, [0xb0 | channel, 32, 0])
            event(0, [0xc0 | channel, program])
            for (control, value): (UInt8, UInt8) in [(7, volume), (11, expression), (10, pan), (91, reverb), (93, 24)] {
                event(0, [0xb0 | channel, control, value])
            }
        }
        marker("Main A")
        event(0, [0xbB, 0, 0])
        event(0, [0xcB, 4])
        event(0, [0x98, 36, 100])
        event(0, [0x9b, 60, 100])
        event(120, [0x99, 36, 100])
        event(180, [0xbB, 7, 30])
        event(180, [0xbB, 10, 80])
        event(180, [0xbB, 91, 70])
        event(240, [0x88, 36, 0])
        event(360, [0x89, 36, 0])
        event(480, [0x8b, 60, 0])
        event(1920, [0xff, 0x2f, 0])
        return try Style(data: Data(chunk("MThd", [0, 0, 0, 1, 1, 224]) + chunk("MTrk", track) + chunk("CASM", [])), name: "Mix fixture")
    }

    static func main() throws {
        let style = try syntheticStyle()
        expect(style.initialControllers[11]?[7] == 50, "Keep initial volume")
        expect(style.initialControllers[11]?[10] == 10, "Keep initial pan")
        expect(style.initialControllers[11]?[11] == 80, "Keep initial expression")
        expect(style.initialControllers[11]?[91] == 32, "Keep initial reverb")
        expect(style.initialControllers[11]?[93] == 24, "Keep initial chorus")
        let segment = Chart.Segment(styleSection: "Main A", name: "A", bars: ["C"], lengthInBars: nil)
        var chart = Chart(style: "fixture", bpm: 120, segments: [segment])
        let rendered = try renderArrangement(chart, style: style)
        let chord = rendered.tracks.first { $0.part == .chord1 }!
        func controls(_ track: PerformanceTrack, _ cc: UInt8) -> [UInt8] {
            track.events.filter { $0.midi.kind == 0xb0 && $0.midi.data1 == cc }.map { $0.midi.data2 }
        }
        func programs(_ track: PerformanceTrack) -> [UInt8] { track.events.filter { $0.midi.kind == 0xc0 }.map { $0.midi.data1 } }
        expect(Array(programs(chord).prefix(2)) == [25, 4], "Initial MegaVoice and section voice map through active bank")
        expect(controls(chord, 7) == [50, 30], "Initial and dynamic source volume preserved")
        expect(controls(chord, 10) == [10, 80], "Initial and dynamic source pan preserved")
        expect(controls(chord, 11) == [80], "Source expression preserved")
        expect(controls(chord, 91) == [32, 70], "Source reverb preserved")
        let drums = rendered.tracks.filter(\.isDrum)
        expect(drums.count == 2 && drums.map(\.program) == [0, 40], "Independent source drum kits retained for audio")
        expect(controls(drums[0], 7) == [64] && controls(drums[1], 7) == [100], "Independent drum volumes retained for audio")
        let portable = portableMIDIEvents(rendered.tracks)
        let drumIndices = rendered.tracks.indices.filter { rendered.tracks[$0].isDrum }
        let drumEvents = drumIndices.flatMap { portable[$0] }
        expect(drumEvents.filter { $0.midi.kind == 0xc0 }.map { $0.midi.data1 } == [0], "GM exports one shared standard kit")
        expect(drumEvents.filter { $0.midi.kind == 0xb0 && $0.midi.data1 == 7 }.map { $0.midi.data2 } == [127], "GM drum controllers never conflict")
        expect(drumEvents.filter { $0.midi.kind == 0x90 }.map { $0.midi.data2 } == [40, 79], "GM note velocity includes each drum volume/expression")
        expect(drumEvents.filter { $0.midi.kind == 0x80 }.map(\.tick) == [360], "Shared channel does not release another rhythm part's overlapping note")
        let single = portableMIDIEvents([drums[1]])[0]
        expect(single.map(\.midi) == drums[1].events.map(\.midi), "Single drum export retains full kit and mix")
        expect(rendered.midi.starts(with: Array("MThd".utf8)), "Encoded MIDI remains valid")

        chart.mix = [.chord1: .init(program: 65, volume: 85, pan: 64, reverb: 10), .rhythm1: .init(program: 16, volume: 0)]
        let mixed = try renderArrangement(chart, style: style)
        let changed = mixed.tracks.first { $0.part == .chord1 }!
        expect(changed.program == 65 && programs(changed) == [65], "Manual voice locks out source program changes")
        expect(controls(changed, 7) == [85, 85], "Manual volume survives dynamic CC7")
        expect(controls(changed, 10) == [64, 64], "Manual pan survives dynamic CC10")
        expect(controls(changed, 91) == [10, 10], "Manual reverb survives dynamic CC91")
        expect(controls(changed, 11) == [80], "Manual volume does not remove musical expression")
        let silentDrum = mixed.tracks.first { $0.part == .rhythm1 }!
        expect(silentDrum.program == 16 && controls(silentDrum, 7) == [0], "Drum override retained")
        let silentIndex = mixed.tracks.firstIndex { $0.part == .rhythm1 }!
        expect(portableMIDIEvents(mixed.tracks)[silentIndex].allSatisfy { $0.midi.kind != 0x90 }, "Zero-volume drum emits no ghost notes")
        chart.mix[.bass] = .init(volume: 255)
        do { _ = try renderArrangement(chart, style: style); preconditionFailure("Accepted invalid mix") }
        catch { expect(error.localizedDescription.contains("0–127"), "Reject invalid MIDI control values") }
        print("Mix/render regression: \(checks) checks passed")
    }
}
