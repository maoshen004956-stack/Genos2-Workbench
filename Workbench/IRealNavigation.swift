import Foundation

/// Executes iReal's written form before any sections or accompaniment are generated.
/// A jump belongs to the end of its measure; Segno and the destination Coda
/// belong to the beginning. Repeat counters are reset on D.C./D.S. returns.
enum IRealNavigation {
    enum Origin: Equatable { case start, segno }
    enum Target: Equatable { case coda, fine, ending(Int), end }
    struct Jump: Equatable { let origin: Origin; let target: Target }
    struct Mark {
        var repeatStart = false
        var repeatEnd: Int? = nil
        var ending: Int? = nil
        var segno = false
        var codaStart = false
        var toCoda = false
        var fine = false
        var jump: Jump? = nil
    }
    struct Visit { let index: Int; let restart: Bool; let returned: Bool }

    struct NavigationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct RepeatGroup {
        let start: Int
        var end: Int
        var count: Int
        var firstEnding: Int?
        var secondEnding: Int?
    }

    static func expand(_ marks: [Mark]) throws -> [Visit] {
        func problem(_ message: String) -> NavigationError { .init(message: message) }
        guard marks.count <= 2_048 else { throw problem("原谱超过 2048 小节，请拆分导入") }
        guard !marks.isEmpty else { return [] }

        let segnos = marks.indices.filter { marks[$0].segno }
        let codas = marks.indices.filter { marks[$0].codaStart }
        let toCodas = marks.indices.filter { marks[$0].toCoda }
        let fines = marks.indices.filter { marks[$0].fine }
        let jumps = marks.indices.filter { marks[$0].jump != nil }
        guard segnos.count <= 1, codas.count <= 1, toCodas.count <= 1,
              fines.count <= 1, jumps.count <= 1 else {
            throw problem("谱面含多个同类 Segno、Coda、Fine 或跳转指令，无法唯一确定演奏顺序")
        }
        if let from = toCodas.first {
            guard let destination = codas.first, destination > from else {
                throw problem("To Coda 缺少位于其后的 Coda 目标")
            }
        }

        let jumpIndex = jumps.first
        let jump = jumpIndex.flatMap { marks[$0].jump }
        var returnIndex = 0
        if let jump, let jumpIndex {
            if jump.origin == .segno {
                guard let segno = segnos.first, segno <= jumpIndex else {
                    throw problem("D.S. 缺少位于跳转指令之前的 Segno 标记")
                }
                returnIndex = segno
            }
            switch jump.target {
            case .coda:
                guard let from = toCodas.first, let destination = codas.first,
                      from >= returnIndex, from <= jumpIndex, destination > jumpIndex else {
                    throw problem("D.C./D.S. al Coda 需要返奏范围内的 To Coda 和跳转指令之后的 Coda 目标")
                }
            case .fine, .ending:
                guard let fine = fines.first, fine >= returnIndex, fine <= jumpIndex else {
                    throw problem("D.C./D.S. al Fine 或指定结尾需要返奏范围内的 Fine 终止标记")
                }
            case .end: break
            }
            if jump.target != .coda, !toCodas.isEmpty {
                throw problem("To Coda 与 D.C./D.S. 的目标指令不一致")
            }
        }

        // Pair repeat signs before playback, including nested repeats. A lone
        // closing repeat at the beginning of a chart implies a return to bar 1.
        var groups: [RepeatGroup] = []
        var open: [Int] = []
        var ends: [Int: Int] = [:]
        var endingGroups: [Int: Int] = [:]
        var implicitFirstEnding: Int?
        for index in marks.indices {
            let mark = marks[index]
            if mark.repeatStart {
                groups.append(.init(start: index, end: -1, count: 2))
                open.append(groups.count - 1)
            }
            if let ending = mark.ending {
                guard ending == 1 || ending == 2 else {
                    throw problem("目前支持第一、第二结尾；其他结尾编号需要先展开")
                }
                if ending == 1 {
                    if let group = open.last {
                        guard groups[group].firstEnding == nil else { throw problem("同一反复段出现多个第一结尾") }
                        groups[group].firstEnding = index
                        endingGroups[index] = group
                    } else if groups.isEmpty, implicitFirstEnding == nil {
                        implicitFirstEnding = index
                    } else { throw problem("第一结尾缺少对应的反复段") }
                } else {
                    guard index > 0, let group = ends[index - 1], groups[group].firstEnding != nil,
                          groups[group].secondEnding == nil else {
                        throw problem("第二结尾必须紧接第一结尾的反复结束线")
                    }
                    groups[group].secondEnding = index
                    endingGroups[index] = group
                }
            }
            if let count = mark.repeatEnd {
                guard (2...16).contains(count) else { throw problem("单段反复次数需要在 2–16 遍之间") }
                let group: Int
                if let value = open.popLast() { group = value }
                else if groups.isEmpty {
                    groups.append(.init(start: 0, end: -1, count: count, firstEnding: implicitFirstEnding))
                    group = 0
                    if let first = implicitFirstEnding { endingGroups[first] = group }
                    implicitFirstEnding = nil
                } else { throw problem("反复结束线缺少对应的开始线，无法确定返回位置") }
                groups[group].end = index
                groups[group].count = count
                ends[index] = group
            }
        }
        guard open.isEmpty, implicitFirstEnding == nil else { throw problem("反复开始线或第一结尾缺少对应的反复结束线") }
        for group in groups where group.firstEnding != nil {
            guard group.secondEnding != nil else { throw problem("第一结尾缺少紧随其后的第二结尾") }
            guard group.count == 2 else { throw problem("带第一、第二结尾的反复段应为两遍；请展开其他遍数的结尾安排") }
        }
        if let jump, case let .ending(number) = jump.target {
            guard number == 1 || number == 2,
                  marks.indices.contains(where: { $0 >= returnIndex && marks[$0].ending == number }) else {
                throw problem("跳转指定的结尾不存在或暂不支持该结尾编号")
            }
        }

        let starts = Dictionary(grouping: groups.indices, by: { groups[$0].start })
        var passes: [Int: Int] = [:]
        var output: [Visit] = []
        var index = 0
        var restart = false
        var returned = false
        var didJump = false
        var didCoda = false
        var didFine = false
        var steps = 0
        while marks.indices.contains(index) {
            steps += 1
            guard steps <= 16_384 else { throw problem("谱面跳转无法收敛，请检查反复和结尾标记") }
            let mark = marks[index]
            if mark.codaStart, didCoda { returned = false }
            for group in starts[index] ?? [] where passes[group] == nil { passes[group] = 1 }

            if let number = mark.ending, let group = endingGroups[index] {
                let desired: Int
                if returned, let jump, case let .ending(target) = jump.target { desired = target }
                else { desired = passes[group] ?? 1 }
                if number != desired {
                    guard number == 1, let next = groups[group].secondEnding else {
                        throw problem("无法确定未选结尾的结束位置；请补充 Fine 或展开结尾")
                    }
                    // Selecting the second ending advances within this pass;
                    // it does not start a new arrangement section.
                    index = next
                    continue
                }
            }

            guard output.count < 4_096 else { throw problem("反复展开后超过 4096 小节，请减少反复次数或拆分导入") }
            output.append(.init(index: index, restart: restart, returned: returned))
            restart = false

            if mark.fine {
                let shouldStop: Bool
                if let jump {
                    switch jump.target {
                    case .fine, .ending: shouldStop = returned
                    case .coda, .end: shouldStop = false
                    }
                } else { shouldStop = true }
                if shouldStop { didFine = true; break }
            }
            // On the return journey a To Coda takes priority over a closing
            // repeat. Without D.C./D.S. this is the final/only player chorus.
            if mark.toCoda, !didCoda, (jump == nil || returned), let destination = codas.first {
                didCoda = true
                passes.removeAll()
                index = destination
                restart = true
                continue
            }
            if let group = ends[index] {
                let forcedEnding: Bool
                if returned, let jump, case .ending = jump.target, groups[group].firstEnding != nil { forcedEnding = true }
                else { forcedEnding = false }
                let pass = passes[group] ?? 1
                if !forcedEnding, pass < groups[group].count {
                    passes[group] = pass + 1
                    // An outer repeat starts each nested repeat afresh.
                    for child in groups.indices where child != group && groups[child].start >= groups[group].start && groups[child].end <= groups[group].end {
                        passes.removeValue(forKey: child)
                    }
                    index = groups[group].start
                    restart = true
                    continue
                }
            }
            // A D.C./D.S. sharing the final bar of a repeated passage runs
            // once that passage has completed all its written repetitions.
            if mark.jump != nil, !didJump {
                didJump = true
                returned = true
                passes.removeAll()
                index = returnIndex
                restart = true
                continue
            }
            index += 1
        }
        if let jump {
            guard didJump else { throw problem("D.C./D.S. 跳转指令位于无法到达的结尾内") }
            switch jump.target {
            case .coda:
                guard didCoda else { throw problem("返奏后未能到达 To Coda，请检查结尾和跳转位置") }
            case .fine, .ending:
                guard didFine else { throw problem("返奏后未能到达 Fine，请检查结尾和终止位置") }
            case .end: break
            }
        } else if !toCodas.isEmpty, !didCoda {
            throw problem("To Coda 位于无法到达的结尾内")
        }
        return output
    }
}
