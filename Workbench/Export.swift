import AppKit
import Foundation
import SXCore

enum ArrangementFormat: String, Identifiable, CaseIterable {
    case logic, museScore, guitarPro
    var id: Self { self }
    var title: String {
        switch self {
        case .logic: return "Logic Pro"
        case .museScore: return "MuseScore Studio"
        case .guitarPro: return "Guitar Pro 8"
        }
    }
    var extensionName: String {
        switch self {
        case .logic: return "mid"
        case .museScore: return "mscz"
        case .guitarPro: return "gp"
        }
    }
    var symbol: String {
        switch self {
        case .logic: return "waveform"
        case .museScore: return "music.note.list"
        case .guitarPro: return "guitars"
        }
    }
    var subtitle: String {
        switch self {
        case .logic: return "分轨 MIDI · 速度、调号、拍号和段落"
        case .museScore: return "MuseScore 工程 · 伴奏总谱、和弦和段落"
        case .guitarPro: return "Guitar Pro 乐谱 · 分轨五线谱、和弦和段落"
        }
    }
    var bundleID: String {
        switch self {
        case .logic: return "com.apple.logic10"
        case .museScore: return "org.musescore.MuseScore"
        case .guitarPro: return "com.arobas-music.guitarpro8"
        }
    }
}

enum ArrangementExport {
    static func write(_ chart: Chart, style: Style, title: String, format: ArrangementFormat,
                      destination: URL, museScore: URL?) throws {
        let arrangement = try renderArrangement(chart, style: style)
        if format == .guitarPro {
            try NotationExport.write(arrangement, title: title, to: destination)
            return
        }
        if format == .logic {
            try arrangement.midi.write(to: destination, options: .atomic)
            return
        }
        guard let museScore else { throw invalid("请先安装 MuseScore Studio，再导出 .mscz 工程。") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let score = directory.appendingPathComponent("score.musicxml")
        let project = directory.appendingPathComponent("score.mscz")
        let converterHome = directory.appendingPathComponent("converter-home", isDirectory: true)
        try FileManager.default.createDirectory(at: converterHome, withIntermediateDirectories: true)
        let executable = museScore.appendingPathComponent("Contents/MacOS/mscore")
        // MuseScore can infer a different meter and tempo when importing performance MIDI.
        let raw = try NotationExport.musicXML(arrangement, title: title)
        let annotated = try annotate(raw, arrangement: arrangement, title: title)
        try annotated.write(to: score)
        try convert(executable, from: score, to: project, in: directory, home: converterHome)
        let projectData = try Data(contentsOf: project)
        guard projectData.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw invalid("MuseScore 未生成有效的 .mscz 工程。")
        }
        try projectData.write(to: destination, options: .atomic)
    }

    private static func convert(_ executable: URL, from input: URL, to output: URL, in directory: URL, home: URL) throws {
        let log = directory.appendingPathComponent("converter.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let stream = try FileHandle(forWritingTo: log)
        defer { try? stream.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-f", "-o", output.path, input.path]
        process.currentDirectoryURL = directory
        // Give the converter its own settings and plugin directories.
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment
        process.standardOutput = stream
        process.standardError = stream
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            let details = (try? String(contentsOf: log, encoding: .utf8))?
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw invalid("MuseScore 保存 .mscz 失败（\(process.terminationStatus)）。\(details)")
        }
    }

    private static func annotate(_ xml: Data, arrangement: ArrangementResult, title: String) throws -> Data {
        let document = try XMLDocument(data: xml, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), let top = root.elements(forName: "part").first else {
            throw invalid("乐谱没有生成可编辑的声部。")
        }
        root.insertChild(node("work", children: [node("work-title", title)]), at: 0)

        let barTicks = arrangement.ticksPerBar
        let markers = Dictionary(uniqueKeysWithValues: arrangement.markers.map { ($0.tick / barTicks, $0.name) })
        let chords = Dictionary(grouping: arrangement.harmony, by: { $0.tick / barTicks })
        var divisions = 1
        for (index, measure) in top.elements(forName: "measure").enumerated() {
            let attributes = measure.elements(forName: "attributes").first
            if let value = attributes?.elements(forName: "divisions").first?.stringValue.flatMap(Int.init), value > 0 {
                divisions = value
            }
            let children = measure.children ?? []
            var insert = children.prefix { ["print", "attributes"].contains($0.name ?? "") }.count
            if let marker = markers[index] {
                let direction = node("direction", children: [node("direction-type", children: [node("rehearsal", marker)])])
                direction.addAttribute(attribute("placement", "above"))
                measure.insertChild(direction, at: insert)
                insert += 1
            }
            for (tick, chord) in chords[index] ?? [] {
                let offset = Int((Double(tick % barTicks) * Double(divisions) /
                                  Double(arrangement.style.ticksPerQuarter)).rounded())
                measure.insertChild(harmony(chord, offset: offset, key: arrangement.key), at: insert)
                insert += 1
            }
        }
        return document.xmlData(options: .nodePrettyPrint)
    }

    private static func harmony(_ chord: Chord, offset: Int, key: SongKey?) -> XMLElement {
        func spelled(_ pitch: Int, element: String) -> XMLElement {
            let steps = ["C", "C", "D", "E", "E", "F", "F", "G", "A", "A", "B", "B"]
            let alters = [0, 1, 0, -1, 0, 0, 1, 0, -1, 0, -1, 0]
            let name = key?.spell(pitch)
            let step = name?.first.map(String.init) ?? steps[pitch]
            let alter = name.map { $0.hasSuffix("♯") ? 1 : $0.hasSuffix("♭") ? -1 : 0 } ?? alters[pitch]
            var children = [node(element + "-step", step)]
            if alter != 0 { children.append(node(element + "-alter", String(alter))) }
            return node(element, children: children)
        }

        let description: (kind: String, degrees: [(Int, Int, String)])
        switch chord.quality {
        case .major: description = ("major", [])
        case .minor: description = ("minor", [])
        case .sixth: description = ("major-sixth", [])
        case .minorSixth: description = ("minor-sixth", [])
        case .majorSeventh: description = ("major-seventh", [])
        case .minorSeventh: description = ("minor-seventh", [])
        case .seventh: description = ("dominant", [])
        case .majorSeventhSharpEleven: description = ("major-seventh", [(11, 1, "add")])
        case .addNine: description = ("major", [(9, 0, "add")])
        case .majorSeventhNine: description = ("major-ninth", [])
        case .sixthNine: description = ("major-sixth", [(9, 0, "add")])
        case .augmented: description = ("augmented", [])
        case .halfDiminished: description = ("half-diminished", [])
        case .minorNine: description = ("minor", [(9, 0, "add")])
        case .minorSeventhNine: description = ("minor-ninth", [])
        case .minorSeventhEleven: description = ("minor-11th", [])
        case .minorMajorSeventh: description = ("major-minor", [])
        case .minorMajorSeventhNine: description = ("major-minor", [(9, 0, "add")])
        case .diminished: description = ("diminished", [])
        case .diminishedSeventh: description = ("diminished-seventh", [])
        case .seventhSuspended: description = ("suspended-fourth", [(7, -1, "add")])
        case .seventhFlatFive: description = ("dominant", [(5, -1, "alter")])
        case .seventhNine: description = ("dominant-ninth", [])
        case .seventhSharpEleven: description = ("dominant", [(11, 1, "add")])
        case .seventhThirteen: description = ("dominant-13th", [])
        case .seventhFlatNine: description = ("dominant", [(9, -1, "add")])
        case .seventhFlatThirteen: description = ("dominant", [(13, -1, "add")])
        case .seventhSharpNine: description = ("dominant", [(9, 1, "add")])
        case .majorSeventhAugmented: description = ("major-seventh", [(5, 1, "alter")])
        case .seventhAugmented: description = ("augmented-seventh", [])
        case .octave: description = ("other", [(8, 0, "add")])
        case .fifth: description = ("power", [])
        case .suspended: description = ("suspended-fourth", [])
        case .suspendedSecond: description = ("suspended-second", [])
        }

        var children = [spelled(chord.root, element: "root"), node("kind", description.kind)]
        if let bass = chord.bass { children.append(spelled(bass, element: "bass")) }
        for (degree, alter, type) in description.degrees {
            children.append(node("degree", children: [node("degree-value", String(degree)),
                                                       node("degree-alter", String(alter)), node("degree-type", type)]))
        }
        if offset > 0 { children.append(node("offset", String(offset))) }
        return node("harmony", children: children)
    }

    private static func node(_ name: String, _ value: String? = nil, children: [XMLNode] = []) -> XMLElement {
        let element = XMLElement(name: name, stringValue: value)
        if !children.isEmpty { element.setChildren(children) }
        return element
    }

    private static func attribute(_ name: String, _ value: String) -> XMLNode {
        let attribute = XMLNode(kind: .attribute)
        attribute.name = name
        attribute.stringValue = value
        return attribute
    }
}
