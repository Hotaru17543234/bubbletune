import SwiftUI

@main
struct BubbleTuneApp: App {
    @StateObject private var library: Library
    @StateObject private var player: Player
    @StateObject private var telegram: TelegramSync

    init() {
        let library = Library()
        _library = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: Player(library: library))
        _telegram = StateObject(wrappedValue: TelegramSync(library: library))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(telegram)
                .preferredColorScheme(.light)
                // 别的 App 里「分享 → 泡泡音」打开的歌曲文件
                .onOpenURL { url in
                    if url.isFileURL {
                        library.importFiles([url])
                    }
                }
        }
    }
}
