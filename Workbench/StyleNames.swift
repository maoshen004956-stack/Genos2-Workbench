import Foundation

enum StyleNames {
    private static let catalog: [String: String] = {
        guard let url = Bundle.main.url(forResource: "StyleNames.zh-Hans", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        for row in text.split(whereSeparator: \.isNewline) {
            let fields = row.split(separator: "\t", maxSplits: 1)
            if fields.count == 2 { names[String(fields[0])] = String(fields[1]) }
        }
        return names
    }()

    private static let byOriginalName = Dictionary(
        catalog.sorted(by: { $0.key < $1.key }).map { (searchKey(originalName($0.key)), $0.value) },
        uniquingKeysWith: { first, _ in first }
    )

    static func originalName(_ path: String) -> String {
        let file = URL(fileURLWithPath: path).deletingPathExtension()
        if file.pathExtension.range(of: "^T[0-9]+$", options: .regularExpression) != nil {
            return file.deletingPathExtension().lastPathComponent
        }
        return file.lastPathComponent
    }

    static func localized(_ path: String) -> String {
        let original = originalName(path)
        return catalog[path] ?? byOriginalName[searchKey(original)] ?? original
    }

    private static func searchKey(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
