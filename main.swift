import Foundation
import SXCore

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { throw invalid("缺少 Genos2 曲库路径") }
    let root = URL(fileURLWithPath: args[0], isDirectory: true)
    if args.count == 3, args[1] == "--inspect" {
        let style = try Style(url: styleURL(args[2], root: root))
        print("\(style.name)  \(style.beatsPerBar)/\(style.beatUnit)  \(String(format: "%.2f", style.bpm)) BPM")
        for section in style.sections {
            let bars = Double(section.length) / Double(style.ticksPerBar)
            print("\(section.name)  \(String(format: "%.2f", bars)) 小节")
        }
        return
    }
    guard args.count == 3 else {
        print("用法：arrange 和弦表.txt 输出.mid")
        print("查看段落：arrange --inspect pop/SkyPop.T547.prs")
        return
    }
    let chart = try Chart(contents: String(contentsOfFile: args[1], encoding: .utf8))
    let style = try Style(url: styleURL(chart.style, root: root))
    try render(chart, style: style, output: URL(fileURLWithPath: args[2]))
}

do { try run() }
catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
