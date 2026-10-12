import Foundation
import Combine
import UIKit
import TDLibKit

// ⚠️ TDLibKit 里也有叫 Date、Error、Notification 的类型，
// 所以这个文件里用苹果自己的这些类型时，一律写全名（Foundation.Date、Swift.Error）。

/// 登录进行到哪一步了（给界面用的，不直接暴露 TDLibKit 的类型）
enum TGLoginStep: Equatable {
    case needsCredentials           // 还没填 api_id / api_hash
    case starting                   // 正在启动 Telegram 库
    case waitPhone
    case waitCode(hint: String)
    case waitPassword(hint: String)
    case waitEmail
    case waitEmailCode(pattern: String)
    case ready
    case loggingOut
}

/// 同步的状态（显示在歌曲列表上方）
enum TGSyncStatus: Equatable {
    case idle
    case checking
    case downloading(done: Int, total: Int, name: String, fraction: Double)
    case waitingForWiFi(count: Int)
    case finished(message: String)
    case failed(message: String)
}

struct TGChannel: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
}

/// 频道里一条带音频 / 视频的消息
private struct TGMediaItem: Sendable {
    enum Kind: Sendable { case audio, video }
    let messageID: Int64
    let fileID: Int
    let fileName: String   // 已经整理过、一定带扩展名
    let size: Int64
    let kind: Kind
}

/// TDLib 的登录状态，翻译成自己的类型再交给主线程
private enum TGAuthEvent: Sendable {
    case waitParameters
    case waitPhone
    case waitCode(String)
    case waitPassword(String)
    case waitEmail
    case waitEmailCode(String)
    case needRegistration
    case needPremium
    case otherDevice
    case ready
    case loggingOut
    case closing
    case closed

    init(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters: self = .waitParameters
        case .authorizationStateWaitPhoneNumber: self = .waitPhone
        case .authorizationStateWaitCode(let wait): self = .waitCode(TGAuthEvent.describe(wait.codeInfo.type))
        case .authorizationStateWaitPassword(let wait): self = .waitPassword(wait.passwordHint)
        case .authorizationStateWaitEmailAddress: self = .waitEmail
        case .authorizationStateWaitEmailCode(let wait): self = .waitEmailCode(wait.codeInfo.emailAddressPattern)
        case .authorizationStateWaitRegistration: self = .needRegistration
        case .authorizationStateWaitPremiumPurchase: self = .needPremium
        case .authorizationStateWaitOtherDeviceConfirmation: self = .otherDevice
        case .authorizationStateReady: self = .ready
        case .authorizationStateLoggingOut: self = .loggingOut
        case .authorizationStateClosing: self = .closing
        case .authorizationStateClosed: self = .closed
        }
    }

    static func describe(_ type: AuthenticationCodeType) -> String {
        switch type {
        case .authenticationCodeTypeTelegramMessage:
            return "验证码已经发到你手机上的 Telegram app 里啦（是「Telegram」官方账号发来的消息）"
        case .authenticationCodeTypeSms, .authenticationCodeTypeSmsWord, .authenticationCodeTypeSmsPhrase:
            return "验证码已经用短信发到你的手机啦"
        case .authenticationCodeTypeCall, .authenticationCodeTypeFlashCall, .authenticationCodeTypeMissedCall:
            return "Telegram 会打电话告诉你验证码"
        default:
            return "验证码已经发出去啦"
        }
    }
}

/// 登录自己的 Telegram 账号，把一个频道里的音频（视频只要声音）同步进泡泡音
@MainActor
final class TelegramSync: ObservableObject {
    @Published private(set) var loginStep: TGLoginStep = .needsCredentials
    @Published private(set) var accountName: String?
    @Published private(set) var channel: TGChannel?
    @Published private(set) var channelChoices: [TGChannel] = []
    @Published private(set) var loadingChannels = false
    @Published private(set) var status: TGSyncStatus = .idle
    @Published private(set) var lastSync: Foundation.Date?
    @Published private(set) var working = false
    @Published private(set) var ignoredCount = 0
    @Published var loginError: String?

    private let library: Library
    private var manager: TDLibClientManager?
    private var client: TDLibClient?
    private var syncing = false
    private var syncAgainWhenDone = false
    private var pendingWiFiSync = false
    private var currentDownloadFileID: Int?
    private var currentDownload: (done: Int, total: Int, name: String)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var ignored: Set<String> = []
    private var statusResetTask: Task<Void, Never>?
    private let network = NetworkWatcher()

    private enum Keys {
        static let apiID = "tg.apiId"
        static let apiHash = "tg.apiHash"
        static let channelID = "tg.channelId"
        static let channelTitle = "tg.channelTitle"
        static let lastSync = "tg.lastSync"
        static let ignored = "tg.ignoredMessages"
    }

    private var apiID: Int? {
        let value = UserDefaults.standard.integer(forKey: Keys.apiID)
        return value > 0 ? value : nil
    }

    private var apiHash: String? {
        UserDefaults.standard.string(forKey: Keys.apiHash)
    }

    var hasCredentials: Bool { apiID != nil && apiHash != nil }

    /// 登录好了、也选好频道了
    var isReadyToSync: Bool { loginStep == .ready && channel != nil }

    var isSyncing: Bool { syncing }

    private static var databaseDirectory: URL {
        Storage.support.appendingPathComponent("tdlib", isDirectory: true)
    }

    private static var filesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tdlib-files", isDirectory: true)
    }

    init(library: Library) {
        self.library = library
        let defaults = UserDefaults.standard
        if let id = defaults.object(forKey: Keys.channelID) as? NSNumber,
           let title = defaults.string(forKey: Keys.channelTitle) {
            channel = TGChannel(id: id.int64Value, title: title)
        }
        lastSync = defaults.object(forKey: Keys.lastSync) as? Foundation.Date
        ignored = Set(defaults.stringArray(forKey: Keys.ignored) ?? [])
        ignoredCount = ignored.count

        library.onSongsDeleted = { [weak self] songs in
            self?.songsDeletedByUser(songs)
        }
        network.onChange = { [weak self] onWiFi in
            self?.networkChanged(onWiFi: onWiFi)
        }
        network.start()

        if hasCredentials {
            startClient()
        }
    }

    // MARK: - 启动 Telegram 库

    private func startClient() {
        guard client == nil else { return }
        loginStep = .starting
        let manager = self.manager ?? TDLibClientManager()
        self.manager = manager
        let newClient = Self.makeClient(
            manager: manager,
            onState: { [weak self] event in
                guard let self else { return }
                Task { @MainActor in self.handle(event) }
            },
            onFile: { [weak self] fileID, downloaded, total in
                guard let self else { return }
                Task { @MainActor in self.fileProgress(fileID: fileID, downloaded: downloaded, total: total) }
            }
        )
        client = newClient
        Task {
            _ = try? await newClient.setLogVerbosityLevel(newVerbosityLevel: 1)
        }
    }

    /// 在非主线程的上下文里创建：TDLib 会在后台线程调用这个闭包
    nonisolated private static func makeClient(
        manager: TDLibClientManager,
        onState: @escaping @Sendable (TGAuthEvent) -> Void,
        onFile: @escaping @Sendable (Int, Int64, Int64) -> Void
    ) -> TDLibClient {
        manager.createClient { data, client in
            guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
            switch update {
            case .updateAuthorizationState(let change):
                onState(TGAuthEvent(change.authorizationState))
            case .updateFile(let change):
                let file = change.file
                onFile(file.id, file.local.downloadedSize, max(file.size, file.expectedSize))
            default:
                break
            }
        }
    }

    private func handle(_ event: TGAuthEvent) {
        working = false
        switch event {
        case .waitParameters:
            sendParameters()
        case .waitPhone:
            loginStep = .waitPhone
        case .waitCode(let hint):
            loginStep = .waitCode(hint: hint)
        case .waitPassword(let hint):
            loginStep = .waitPassword(hint: hint)
        case .waitEmail:
            loginStep = .waitEmail
        case .waitEmailCode(let pattern):
            loginStep = .waitEmailCode(pattern: pattern)
        case .needRegistration:
            loginError = "这个手机号还没有注册 Telegram 哦，先用官方 Telegram app 注册吧"
            loginStep = .waitPhone
        case .needPremium:
            loginError = "Telegram 要求这个账号先开通会员才能在新设备登录，暂时没法在泡泡音里登录"
            loginStep = .waitPhone
        case .otherDevice:
            loginStep = .waitPhone
        case .ready:
            loginStep = .ready
            loginError = nil
            afterLogin()
        case .loggingOut:
            loginStep = .loggingOut
        case .closing:
            break
        case .closed:
            client = nil
            accountName = nil
            if hasCredentials {
                startClient()
            } else {
                try? FileManager.default.removeItem(at: Self.databaseDirectory)
                loginStep = .needsCredentials
            }
        }
    }

    private func sendParameters() {
        guard let client, let id = apiID, let hash = apiHash else { return }
        let database = Self.databaseDirectory
        let files = Self.filesDirectory
        try? FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let systemVersion = UIDevice.current.systemVersion
        Task {
            do {
                _ = try await client.setTdlibParameters(
                    apiHash: hash,
                    apiId: id,
                    applicationVersion: "1.2",
                    databaseDirectory: database.path,
                    databaseEncryptionKey: nil,
                    deviceModel: "iPhone",
                    filesDirectory: files.path,
                    systemLanguageCode: "zh-hans",
                    systemVersion: systemVersion,
                    useChatInfoDatabase: true,
                    useFileDatabase: true,
                    useMessageDatabase: true,
                    useSecretChats: false,
                    useTestDc: false
                )
            } catch {
                self.loginError = Self.explain(error)
            }
        }
    }

    // MARK: - 登录（界面调用）

    /// 保存 api_id / api_hash，然后开始连接 Telegram
    func saveCredentials(apiID rawID: String, apiHash rawHash: String) {
        let idText = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = rawHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = Int(idText), id > 0 else {
            loginError = "api_id 应该是一串数字哦"
            return
        }
        guard hash.count == 32, hash.allSatisfy({ $0.isHexDigit }) else {
            loginError = "api_hash 应该是 32 位的字母和数字，再复制一次试试"
            return
        }
        UserDefaults.standard.set(id, forKey: Keys.apiID)
        UserDefaults.standard.set(hash, forKey: Keys.apiHash)
        loginError = nil
        startClient()
    }

    /// 换一个 api_id（只在还没登录时用）
    func resetCredentials() {
        UserDefaults.standard.removeObject(forKey: Keys.apiID)
        UserDefaults.standard.removeObject(forKey: Keys.apiHash)
        loginError = nil
        if let client {
            Task { _ = try? await client.close() }
        } else {
            loginStep = .needsCredentials
        }
    }

    func sendPhone(_ phone: String) {
        // 只留数字和最前面的 +
        let cleaned = phone.filter { $0.isNumber || $0 == "+" }
        guard cleaned.count >= 8 else {
            loginError = "手机号好像不完整，要带国家区号哦，比如 +81 90 1234 5678"
            return
        }
        perform { _ = try await $0.setAuthenticationPhoneNumber(phoneNumber: cleaned, settings: nil) }
    }

    func sendCode(_ code: String) {
        let digits = code.filter { $0.isNumber }
        guard !digits.isEmpty else { return }
        perform { _ = try await $0.checkAuthenticationCode(code: digits) }
    }

    func resendCode() {
        perform { _ = try await $0.resendAuthenticationCode(reason: .resendCodeReasonUserRequest) }
    }

    func sendPassword(_ password: String) {
        guard !password.isEmpty else { return }
        perform { _ = try await $0.checkAuthenticationPassword(password: password) }
    }

    func sendEmail(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else {
            loginError = "邮箱地址好像不对"
            return
        }
        perform { _ = try await $0.setAuthenticationEmailAddress(emailAddress: trimmed) }
    }

    func sendEmailCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let auth = EmailAddressAuthentication.emailAddressAuthenticationCode(EmailAddressAuthenticationCode(code: trimmed))
        perform { _ = try await $0.checkAuthenticationEmailCode(code: auth) }
    }

    /// 退出 Telegram 登录（已经同步下来的歌不会被删）
    func logOut() {
        channel = nil
        channelChoices = []
        UserDefaults.standard.removeObject(forKey: Keys.channelID)
        UserDefaults.standard.removeObject(forKey: Keys.channelTitle)
        perform { _ = try await $0.logOut() }
    }

    private func perform(_ action: @escaping (TDLibClient) async throws -> Void) {
        guard let client else {
            loginError = "还没连上 Telegram，稍等一下再试"
            return
        }
        working = true
        loginError = nil
        Task {
            do {
                try await action(client)
            } catch {
                self.loginError = Self.explain(error)
                self.working = false
            }
        }
    }

    private func afterLogin() {
        guard let client else { return }
        Task {
            if let me = try? await client.getMe() {
                let name = [me.firstName, me.lastName].filter { !$0.isEmpty }.joined(separator: " ")
                self.accountName = name.isEmpty ? me.phoneNumber : name
            }
            if self.channel == nil {
                await self.loadChannels()
            } else {
                await self.sync(manual: false)
            }
        }
    }

    // MARK: - 选频道

    func loadChannels() async {
        guard let client, loginStep == .ready else { return }
        loadingChannels = true
        defer { loadingChannels = false }
        var found: [TGChannel] = []
        var seen = Set<Int64>()
        for list in [ChatList.chatListMain, ChatList.chatListArchive] {
            _ = try? await client.loadChats(chatList: list, limit: 500)
            guard let chats = try? await client.getChats(chatList: list, limit: 500) else { continue }
            for chatID in chats.chatIds where !seen.contains(chatID) {
                seen.insert(chatID)
                guard let chat = try? await client.getChat(chatId: chatID) else { continue }
                if case .chatTypeSupergroup(let group) = chat.type, group.isChannel {
                    found.append(TGChannel(id: chat.id, title: chat.title))
                }
            }
        }
        channelChoices = found
    }

    func choose(_ newChannel: TGChannel) {
        channel = newChannel
        UserDefaults.standard.set(NSNumber(value: newChannel.id), forKey: Keys.channelID)
        UserDefaults.standard.set(newChannel.title, forKey: Keys.channelTitle)
        Task { await sync(manual: true) }
    }

    // MARK: - 自动同步的时机

    /// app 回到前台
    func appBecameActive() {
        guard isReadyToSync else { return }
        // 一分钟内刚同步过就不重复了
        if let lastSync, Foundation.Date().timeIntervalSince(lastSync) < 60 { return }
        Task { await sync(manual: false) }
    }

    private func networkChanged(onWiFi: Bool) {
        guard onWiFi, pendingWiFiSync, isReadyToSync,
              UIApplication.shared.applicationState == .active else { return }
        pendingWiFiSync = false
        Task { await sync(manual: false) }
    }

    /// 你在泡泡音里删掉的 Telegram 歌：记下来，以后不再同步回来
    private func songsDeletedByUser(_ songs: [Song]) {
        let keys = songs.compactMap(\.telegramKey)
        guard !keys.isEmpty else { return }
        ignored.formUnion(keys)
        saveIgnored()
    }

    /// 让以前删掉的歌重新同步回来
    func clearIgnored() {
        ignored.removeAll()
        saveIgnored()
        Task { await sync(manual: true) }
    }

    private func saveIgnored() {
        UserDefaults.standard.set(Array(ignored), forKey: Keys.ignored)
        ignoredCount = ignored.count
    }

    // MARK: - 同步

    func sync(manual: Bool) async {
        guard loginStep == .ready, let channel, let client else { return }
        guard !syncing else {
            if manual { syncAgainWhenDone = true }
            return
        }
        syncing = true
        statusResetTask?.cancel()
        beginBackgroundWork()
        defer {
            syncing = false
            currentDownloadFileID = nil
            currentDownload = nil
            endBackgroundWork()
            if syncAgainWhenDone {
                syncAgainWhenDone = false
                Task { await self.sync(manual: true) }
            }
        }

        // 1. 把频道里的消息从新到旧翻一遍，挑出音频和视频
        status = .checking
        // 确保 Telegram 库认识这个频道（刚启动时可能还没加载聊天列表）
        if (try? await client.getChat(chatId: channel.id)) == nil {
            _ = try? await client.loadChats(chatList: .chatListMain, limit: 500)
            _ = try? await client.loadChats(chatList: .chatListArchive, limit: 500)
            guard (try? await client.getChat(chatId: channel.id)) != nil else {
                finish(.failed(message: "找不到「\(channel.title)」这个频道了，去设置里重新选一下吧"))
                return
            }
        }
        var items: [TGMediaItem] = []
        var seen = Set<Int64>()
        var fromID: Int64 = 0
        var complete = false
        do {
            for _ in 0..<5000 {
                let page = try await client.getChatHistory(chatId: channel.id, fromMessageId: fromID,
                                                           limit: 100, offset: 0, onlyLocal: false)
                let messages = page.messages ?? []
                let fresh = messages.filter { !seen.contains($0.id) }
                if fresh.isEmpty {
                    complete = true
                    break
                }
                for message in fresh {
                    seen.insert(message.id)
                    if let item = Self.mediaItem(from: message) {
                        items.append(item)
                    }
                }
                fromID = messages.map(\.id).min() ?? fromID
            }
        } catch {
            finish(.failed(message: "读取频道失败：\(Self.explain(error))"))
            return
        }
        guard self.channel?.id == channel.id else { return }   // 中途换了频道
        items.sort { $0.messageID < $1.messageID }              // 早发的在前

        // 2. 频道里已经删掉的消息 → 泡泡音里也删掉
        //    （只有完整翻完了频道才删；频道里一首都没找到时也不删，防止网络出问题误删）
        var removedCount = 0
        let currentIDs = Set(items.map(\.messageID))
        let linked = library.songs.filter { $0.tgChatID == channel.id }
        if complete && !items.isEmpty {
            let gone = linked.filter { song in
                guard let messageID = song.tgMessageID else { return false }
                return !currentIDs.contains(messageID)
            }
            if !gone.isEmpty {
                library.delete(ids: Set(gone.map(\.id)), byUser: false)
                removedCount = gone.count
            }
        }

        // 3. 已经同步过的跳过；以前手动导入过的同名同大小的歌直接关联，不重复下载
        var mergedCount = 0
        let linkedIDs = Set(library.songs.compactMap { $0.tgChatID == channel.id ? $0.tgMessageID : nil })
        var toDownload: [TGMediaItem] = []
        for item in items where !linkedIDs.contains(item.messageID) {
            if ignored.contains("\(channel.id):\(item.messageID)") { continue }
            if let match = library.unlinkedSong(matchingFileName: item.fileName, size: item.size) {
                library.linkTelegram(songID: match.id, chatID: channel.id, messageID: item.messageID)
                mergedCount += 1
            } else {
                toDownload.append(item)
            }
        }

        // 4. 下载（只在 Wi-Fi 下）
        var addedCount = 0
        var failedCount = 0
        var waitingCount = 0
        for (index, item) in toDownload.enumerated() {
            guard network.onWiFi else {
                waitingCount = toDownload.count - index
                pendingWiFiSync = true
                break
            }
            guard self.channel?.id == channel.id, loginStep == .ready else { break }
            currentDownloadFileID = item.fileID
            currentDownload = (index, toDownload.count, item.fileName)
            status = .downloading(done: index, total: toDownload.count, name: item.fileName, fraction: 0)
            do {
                let file = try await client.downloadFile(fileId: item.fileID, limit: 0, offset: 0,
                                                         priority: 16, synchronous: true)
                guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else {
                    failedCount += 1
                    continue
                }
                let source = URL(fileURLWithPath: file.local.path)
                let stored = try await MediaTools.store(source: source, originalName: item.fileName,
                                                        extractAudio: item.kind == .video)
                // Telegram 自己缓存的那份删掉，免得一首歌占两份空间
                _ = try? await client.deleteFile(fileId: item.fileID)
                library.addSyncedSong(fileName: stored, chatID: channel.id, messageID: item.messageID)
                addedCount += 1
            } catch {
                failedCount += 1
            }
        }

        // 5. 告诉你结果
        lastSync = Foundation.Date()
        UserDefaults.standard.set(lastSync, forKey: Keys.lastSync)
        var parts: [String] = []
        if addedCount > 0 { parts.append("新增 \(addedCount) 首") }
        if mergedCount > 0 { parts.append("认出 \(mergedCount) 首以前导入过的") }
        if removedCount > 0 { parts.append("频道里删掉的 \(removedCount) 首也删掉了") }
        if failedCount > 0 { parts.append("\(failedCount) 首没下载成功，下次再试") }
        if waitingCount > 0 {
            status = .waitingForWiFi(count: waitingCount)
            if !parts.isEmpty { library.showToast(parts.joined(separator: "，")) }
            return
        }
        if parts.isEmpty {
            finish(.finished(message: manual ? "已经是最新的啦 ✨" : ""))
        } else {
            finish(.finished(message: "同步好啦：" + parts.joined(separator: "，")))
        }
    }

    /// 显示结果，几秒后自动收起
    private func finish(_ result: TGSyncStatus) {
        if case .finished(let message) = result, message.isEmpty {
            status = .idle
            return
        }
        status = result
        statusResetTask?.cancel()
        statusResetTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if case .downloading = self.status { return }
            if case .checking = self.status { return }
            self.status = .idle
        }
    }

    private func fileProgress(fileID: Int, downloaded: Int64, total: Int64) {
        guard fileID == currentDownloadFileID, let current = currentDownload, total > 0 else { return }
        let fraction = min(1, Double(downloaded) / Double(total))
        if case .downloading(_, _, _, let old) = status, abs(old - fraction) < 0.01 { return }
        status = .downloading(done: current.done, total: current.total, name: current.name, fraction: fraction)
    }

    // MARK: - 后台多争取一点时间

    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BubbleTune Telegram sync") { [weak self] in
            MainActor.assumeIsolated {
                self?.endBackgroundWork()
            }
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - 看懂一条消息

    nonisolated private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    nonisolated private static let unplayable: Set<String> = ["ogg", "oga", "opus", "wma", "ape"]

    nonisolated private static func mediaItem(from message: Message) -> TGMediaItem? {
        switch message.content {
        case .messageAudio(let content):
            let audio = content.audio
            let file = audio.audio
            var stem = audio.title
            if !audio.performer.isEmpty && !audio.title.isEmpty {
                stem = "\(audio.performer) - \(audio.title)"
            }
            if stem.isEmpty { stem = "TG音频 \(message.id)" }
            let name = fileName(audio.fileName, fallbackStem: stem, mime: audio.mimeType, defaultExt: "mp3")
            guard !unplayable.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            return TGMediaItem(messageID: message.id, fileID: file.id, fileName: name,
                               size: max(file.size, file.expectedSize), kind: .audio)

        case .messageVideo(let content):
            let video = content.video
            let file = video.video
            let name = fileName(video.fileName, fallbackStem: "TG视频 \(message.id)", mime: video.mimeType, defaultExt: "mp4")
            return TGMediaItem(messageID: message.id, fileID: file.id, fileName: name,
                               size: max(file.size, file.expectedSize), kind: .video)

        case .messageDocument(let content):
            let document = content.document
            let file = document.document
            let ext = (document.fileName as NSString).pathExtension.lowercased()
            let mime = document.mimeType.lowercased()
            let isVideo = videoExtensions.contains(ext) || (ext.isEmpty && mime.hasPrefix("video/"))
            let isAudio = !isVideo && (Storage.audioExtensions.contains(ext) || (ext.isEmpty && mime.hasPrefix("audio/")))
            guard isVideo || isAudio else { return nil }
            let name = fileName(document.fileName, fallbackStem: "TG文件 \(message.id)", mime: document.mimeType,
                                defaultExt: isVideo ? "mp4" : "mp3")
            guard !unplayable.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            return TGMediaItem(messageID: message.id, fileID: file.id, fileName: name,
                               size: max(file.size, file.expectedSize), kind: isVideo ? .video : .audio)

        default:
            return nil
        }
    }

    /// 整理文件名：没有名字就用备用名，没有扩展名就按文件类型补上
    nonisolated private static func fileName(_ raw: String, fallbackStem: String, mime: String, defaultExt: String) -> String {
        var name = MediaTools.safeFileName(raw)
        if name.isEmpty {
            name = MediaTools.safeFileName(fallbackStem)
        }
        if (name as NSString).pathExtension.isEmpty {
            name += "." + ext(forMime: mime, default: defaultExt)
        }
        return name
    }

    nonisolated private static func ext(forMime mime: String, default fallback: String) -> String {
        switch mime.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac": return "m4a"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/ogg", "audio/opus": return "ogg"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return fallback
        }
    }

    /// 把 Telegram 的英文报错翻译成人话
    nonisolated private static func explain(_ error: Swift.Error) -> String {
        guard let tdError = error as? TDLibKit.Error else {
            return error.localizedDescription
        }
        let message = tdError.message
        switch message {
        case "PHONE_NUMBER_INVALID":
            return "手机号格式不对，要带国家区号哦，比如 +81 90 1234 5678"
        case "PHONE_CODE_INVALID":
            return "验证码不对，再仔细看一眼～"
        case "PHONE_CODE_EXPIRED":
            return "验证码过期了，点「重新发送验证码」"
        case "PHONE_CODE_EMPTY":
            return "还没填验证码哦"
        case "PASSWORD_HASH_INVALID":
            return "两步验证密码不对"
        case "API_ID_INVALID", "API_ID_PUBLISHED_FLOOD":
            return "api_id 或 api_hash 不对，点「换一个 api_id」重新填一下"
        case "PHONE_NUMBER_BANNED":
            return "这个手机号被 Telegram 封禁了"
        case "EMAIL_INVALID":
            return "邮箱地址不对"
        case "CODE_INVALID", "EMAIL_CODE_INVALID":
            return "邮箱验证码不对"
        default:
            if tdError.code == 429 || message.contains("FLOOD") || message.contains("Too Many Requests") {
                return "试得太频繁啦，Telegram 让你等一会儿再试（\(message)）"
            }
            return "Telegram 说：\(message)"
        }
    }
}
