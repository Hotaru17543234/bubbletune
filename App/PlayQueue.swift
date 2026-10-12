import Foundation

/// 播放顺序：顺序 / 倒序 / 随机
enum OrderMode: String, CaseIterable, Identifiable, Codable {
    case sequential
    case reverse
    case shuffle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .reverse: return "倒序播放"
        case .shuffle: return "随机播放"
        }
    }

    var shortTitle: String {
        switch self {
        case .sequential: return "顺序"
        case .reverse: return "倒序"
        case .shuffle: return "随机"
        }
    }

    var icon: String {
        switch self {
        case .sequential: return "arrow.down"
        case .reverse: return "arrow.up"
        case .shuffle: return "shuffle"
        }
    }
}

/// 放到头之后怎么办：列表循环 / 放完就停 / 单曲循环
enum RepeatMode: String, CaseIterable, Identifiable, Codable {
    case all
    case off
    case one

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "列表循环"
        case .off: return "放完就停"
        case .one: return "单曲循环"
        }
    }

    var icon: String {
        switch self {
        case .all: return "repeat"
        case .off: return "arrow.right.to.line"
        case .one: return "repeat.1"
        }
    }
}

/// 只管「下一首该放谁」的纯逻辑，不碰声音和界面。
/// (仓库里的 Tests/queue_model.py 是它的一比一 Python 版，用来测试)
struct PlayQueue {
    struct Step {
        let id: UUID
        /// 自动播放下一首时是否接着放（「放完就停」走到头时为 false）
        let autoplay: Bool
    }

    private(set) var mode: OrderMode
    private(set) var order: [UUID] = []
    private(set) var current: UUID?

    init(mode: OrderMode) {
        self.mode = mode
    }

    private var position: Int? {
        guard let current else { return nil }
        return order.firstIndex(of: current)
    }

    /// 按歌曲列表重新排好播放顺序，并把 start 设为当前歌曲
    mutating func rebuild(library ids: [UUID], startingWith start: UUID?) {
        if let start, ids.contains(start) {
            current = start
        } else {
            current = nil
        }
        switch mode {
        case .sequential:
            order = ids
        case .reverse:
            order = Array(ids.reversed())
        case .shuffle:
            var rest = ids.filter { $0 != current }
            rest.shuffle()
            if let current {
                order = [current] + rest
            } else {
                order = rest
            }
        }
    }

    mutating func setMode(_ newMode: OrderMode, library ids: [UUID]) {
        mode = newMode
        rebuild(library: ids, startingWith: current)
    }

    /// 歌曲列表变了（导入、删除、拖动排序）：保住当前歌曲；随机模式下保住已经洗好的顺序
    mutating func sync(library ids: [UUID]) {
        let idSet = Set(ids)
        if let current, !idSet.contains(current) {
            self.current = nil
        }
        switch mode {
        case .sequential:
            order = ids
        case .reverse:
            order = Array(ids.reversed())
        case .shuffle:
            var kept = order.filter { idSet.contains($0) }
            let keptSet = Set(kept)
            let newOnes = ids.filter { !keptSet.contains($0) }
            var start = 0
            if let current, let i = kept.firstIndex(of: current) {
                start = i + 1
            }
            // 新导入的歌随机插在「当前歌曲之后」，这一轮里一定会放到
            for id in newOnes {
                let i = Int.random(in: start...kept.count)
                kept.insert(id, at: i)
            }
            order = kept
        }
    }

    /// 在列表里点了一首歌
    mutating func select(_ id: UUID, library ids: [UUID]) {
        if mode == .shuffle {
            rebuild(library: ids, startingWith: id)
        } else {
            current = id
        }
    }

    /// 还没选歌就按了播放：从播放顺序的第一首开始
    mutating func start() -> UUID? {
        guard !order.isEmpty else { return nil }
        if current == nil {
            current = order[0]
        }
        return current
    }

    /// 下一首。automatic = 上一首自己放完了（不是手动按的）
    mutating func next(automatic: Bool, repeatMode: RepeatMode) -> Step? {
        guard !order.isEmpty else { return nil }
        guard let pos = position, let current else {
            self.current = order[0]
            return Step(id: order[0], autoplay: true)
        }
        if automatic && repeatMode == .one {
            return Step(id: current, autoplay: true)
        }
        if pos + 1 < order.count {
            self.current = order[pos + 1]
            return Step(id: order[pos + 1], autoplay: true)
        }
        // 走到播放顺序的最后了
        if mode == .shuffle {
            reshuffle(avoidingFirst: current)
        }
        self.current = order[0]
        let keepGoing = !(automatic && repeatMode == .off)
        return Step(id: order[0], autoplay: keepGoing)
    }

    /// 上一首（「放了 3 秒以上就回到开头」由 Player 处理）
    mutating func previous() -> UUID? {
        guard !order.isEmpty else { return nil }
        guard let pos = position else {
            current = order[order.count - 1]
            return current
        }
        current = pos > 0 ? order[pos - 1] : order[order.count - 1]
        return current
    }

    /// 随机模式一轮放完后重新洗牌，并且不让刚放完的那首排在第一个
    private mutating func reshuffle(avoidingFirst last: UUID) {
        order.shuffle()
        if order.count > 1 && order[0] == last {
            let j = Int.random(in: 1..<order.count)
            order.swapAt(0, j)
        }
    }
}
