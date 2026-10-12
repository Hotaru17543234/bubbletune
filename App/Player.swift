import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// 负责真正放出声音：播放 / 暂停 / 切歌、后台播放、锁屏和控制中心、来电打断
@MainActor
final class Player: NSObject, ObservableObject {
    @Published private(set) var currentID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var orderMode: OrderMode = .sequential
    @Published private(set) var repeatMode: RepeatMode = .all

    private let library: Library
    private var queue = PlayQueue(mode: .sequential)
    private var audio: AVAudioPlayer?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var wasPlayingBeforeInterruption = false
    private var brokenInARow = 0
    private var autosaveTask: Task<Void, Never>?

    private enum Keys {
        static let order = "orderMode"
        static let repeatMode = "repeatMode"
        static let lastSong = "lastSongID"
        static let lastTime = "lastSongTime"
    }

    /// 当前放到第几秒（界面用 TimelineView 定时来读）
    var currentTime: TimeInterval { audio?.currentTime ?? 0 }

    var duration: TimeInterval {
        if let audio { return audio.duration }
        return currentSong?.duration ?? 0
    }

    var currentSong: Song? { library.song(id: currentID) }

    private var libraryIDs: [UUID] { library.songs.map(\.id) }

    init(library: Library) {
        self.library = library
        super.init()

        let defaults = UserDefaults.standard
        orderMode = OrderMode(rawValue: defaults.string(forKey: Keys.order) ?? "") ?? .sequential
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .all
        queue = PlayQueue(mode: orderMode)

        configureAudioSession()
        setUpRemoteCommands()
        observeAudioSession()

        // 回到上次放的那首歌、那个位置（先不出声）
        let lastID = defaults.string(forKey: Keys.lastSong).flatMap { UUID(uuidString: $0) }
        queue.rebuild(library: libraryIDs, startingWith: lastID)
        if let id = queue.current {
            load(id, autoplay: false, at: defaults.double(forKey: Keys.lastTime))
        }

        library.onSongsChanged = { [weak self] ids in
            self?.librarySongsChanged(ids)
        }
        library.onSongEdited = { [weak self] id in
            self?.songEdited(id)
        }

        // 每 5 秒记一下放到哪了，app 被系统关掉也不怕
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.isPlaying { self.saveState() }
            }
        }
    }

    // MARK: - 播放控制

    func play() {
        guard let audio else {
            var startID = queue.current
            if startID == nil {
                startID = queue.start()
            }
            if let id = startID {
                load(id, autoplay: true)
            }
            return
        }
        activateAudioSession()
        audio.play()
        isPlaying = audio.isPlaying
        updateNowPlaying()
    }

    func pause() {
        audio?.pause()
        isPlaying = false
        updateNowPlaying()
        saveState()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// 手动按「下一首」：正在放就接着放，暂停中就停在下一首
    func next() {
        advance(automatic: false)
    }

    /// 放了 3 秒以上按「上一首」会先回到这首开头，和系统音乐 App 一样
    func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        let keepPlaying = isPlaying
        if let id = queue.previous() {
            load(id, autoplay: keepPlaying)
        }
    }

    /// 在列表里点了一首歌
    func playSong(_ id: UUID) {
        if id == currentID, audio != nil {
            if !isPlaying { play() }
            return
        }
        queue.select(id, library: libraryIDs)
        load(id, autoplay: true)
    }

    func seek(to time: TimeInterval) {
        guard let audio else { return }
        audio.currentTime = max(0, min(time, audio.duration))
        updateNowPlaying()
        saveState()
    }

    // MARK: - 播放方式

    func setOrderMode(_ mode: OrderMode) {
        guard mode != orderMode else { return }
        orderMode = mode
        queue.setMode(mode, library: libraryIDs)
        UserDefaults.standard.set(mode.rawValue, forKey: Keys.order)
    }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Keys.repeatMode)
    }

    func cycleOrderMode() {
        let all = OrderMode.allCases
        let i = all.firstIndex(of: orderMode) ?? 0
        setOrderMode(all[(i + 1) % all.count])
    }

    func cycleRepeatMode() {
        let all = RepeatMode.allCases
        let i = all.firstIndex(of: repeatMode) ?? 0
        setRepeatMode(all[(i + 1) % all.count])
    }

    // MARK: - 内部

    private func advance(automatic: Bool) {
        let wasPlaying = isPlaying
        guard let step = queue.next(automatic: automatic, repeatMode: repeatMode) else {
            stopAndClear()
            return
        }
        let autoplay = automatic ? step.autoplay : wasPlaying
        load(step.id, autoplay: autoplay)
    }

    private func load(_ id: UUID, autoplay: Bool, at startTime: TimeInterval = 0) {
        audio?.stop()
        audio = nil
        currentID = id
        nowPlayingArtwork = nil

        guard let song = library.song(id: id) else {
            isPlaying = false
            updateNowPlaying()
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: song.url)
            player.delegate = self
            player.prepareToPlay()
            if startTime > 0 && startTime < player.duration - 1 {
                player.currentTime = startTime
            }
            audio = player
        } catch {
            isPlaying = false
            updateNowPlaying()
            library.showToast("「\(song.displayTitle)」放不了，可能格式不支持或文件坏了")
            // 自动跳过坏掉的歌，但全都坏了就别一直转圈
            if autoplay {
                brokenInARow += 1
                if brokenInARow < library.songs.count {
                    isPlaying = true
                    advance(automatic: false)
                } else {
                    brokenInARow = 0
                }
            }
            return
        }

        brokenInARow = 0
        if autoplay {
            activateAudioSession()
            audio?.play()
            isPlaying = audio?.isPlaying ?? false
        } else {
            isPlaying = false
        }
        updateNowPlaying()
        saveState()
        loadArtwork(for: song)
    }

    private func stopAndClear() {
        audio?.stop()
        audio = nil
        currentID = nil
        isPlaying = false
        nowPlayingArtwork = nil
        updateNowPlaying()
        saveState()
    }

    private func songFinished() {
        isPlaying = false
        advance(automatic: true)
    }

    private func librarySongsChanged(_ ids: [UUID]) {
        let before = queue.current
        queue.sync(library: ids)
        if before != nil && queue.current == nil {
            // 正在放的歌被删掉了
            stopAndClear()
        }
    }

    /// 正在放的歌改了名字或封面：锁屏和控制中心也跟着更新
    private func songEdited(_ id: UUID) {
        guard id == currentID, let song = currentSong else { return }
        objectWillChange.send()   // 底部播放条、播放页、洗澡模式里的歌名跟着刷新
        nowPlayingArtwork = nil
        updateNowPlaying()
        loadArtwork(for: song)
    }

    func saveState() {
        let defaults = UserDefaults.standard
        defaults.set(currentID?.uuidString, forKey: Keys.lastSong)
        defaults.set(currentTime, forKey: Keys.lastTime)
    }

    // MARK: - 声音会话（后台播放、来电、拔耳机）

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default

        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let info = note.userInfo
            guard let rawType = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            let rawOptions = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            let began = (type == .began)
            Task { @MainActor in
                self.handleInterruption(began: began, shouldResume: shouldResume)
            }
        }

        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            let unplugged = (reason == .oldDeviceUnavailable)
            Task { @MainActor in
                if unplugged { self.pause() }
            }
        }
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            wasPlayingBeforeInterruption = isPlaying
            isPlaying = false
            updateNowPlaying()
            saveState()
        } else if shouldResume && wasPlayingBeforeInterruption {
            wasPlayingBeforeInterruption = false
            play()
        }
    }

    // MARK: - 锁屏 / 控制中心 / 耳机按键

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()

        commands.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.togglePlayPause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self.seek(to: time) }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let song = currentSong else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.displayTitle,
            MPMediaItemPropertyArtist: song.displayArtist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if !song.displayAlbum.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = song.displayAlbum
        }
        if let art = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        center.nowPlayingInfo = info
    }

    private func loadArtwork(for song: Song) {
        let id = song.id
        Task {
            guard let image = await ArtworkCache.shared.image(for: song), self.currentID == id else { return }
            self.nowPlayingArtwork = Self.makeArtwork(image)
            self.updateNowPlaying()
        }
    }

    /// 在非主线程上下文里创建，系统会在后台线程调用这个闭包
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

extension Player: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.audio, ObjectIdentifier(current) == finished else { return }
            self.songFinished()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let broken = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.audio, ObjectIdentifier(current) == broken else { return }
            self.songFinished()
        }
    }
}
