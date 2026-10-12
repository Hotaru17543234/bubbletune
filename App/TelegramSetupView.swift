import SwiftUI

/// 设置 → Telegram 同步：填 api_id、登录、选频道、手动同步、退出
struct TelegramSetupView: View {
    @EnvironmentObject private var telegram: TelegramSync

    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var phone = "+81 "
    @State private var code = ""
    @State private var password = ""
    @State private var email = ""
    @State private var emailCode = ""
    @State private var confirmLogout = false
    @State private var choosingChannel = false

    var body: some View {
        Form {
            switch telegram.loginStep {
            case .needsCredentials:
                credentialsSections
            case .starting, .loggingOut:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(telegram.loginStep == .loggingOut ? "正在退出…" : "正在连接 Telegram…")
                    }
                }
            case .waitPhone:
                phoneSection
                changeCredentialsSection
            case .waitCode(let hint):
                codeSection(hint: hint)
            case .waitPassword(let hint):
                passwordSection(hint: hint)
            case .waitEmail:
                emailSection
            case .waitEmailCode(let pattern):
                emailCodeSection(pattern: pattern)
            case .ready:
                if telegram.channel == nil || choosingChannel {
                    channelPickerSection
                } else {
                    syncSections
                }
                accountSection
            }

            if let error = telegram.loginError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("Telegram 同步")
        .navigationBarTitleDisplayMode(.inline)
        .fontDesign(.rounded)
        .disabled(telegram.working)
        .overlay {
            if telegram.working {
                ProgressView()
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .confirmationDialog("退出 Telegram 登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { telegram.logOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已经同步下来的歌会留在泡泡音里，不会被删掉。")
        }
    }

    // MARK: - 第 1 步：api_id

    @ViewBuilder
    private var credentialsSections: some View {
        Section {
            step(1, "用浏览器打开 my.telegram.org，填你的 Telegram 手机号（要带 +81 这样的区号），验证码会发到你的 Telegram app 里。")
            step(2, "登录后点「API development tools」。")
            step(3, "App title 填 BubbleTune，Short name 填 bubbletune2026 这样只有字母数字的名字，Platform 选 iOS，其它可以空着，点「Create application」。")
            step(4, "页面上会出现 App api_id（一串数字）和 App api_hash（32 位字母数字），复制到下面。")
            Link(destination: URL(string: "https://my.telegram.org")!) {
                Label("打开 my.telegram.org", systemImage: "safari")
            }
        } header: {
            Text("先申请一个开发者编号（只要做一次）")
        } footer: {
            Text("如果点 Create 时出现「ERROR」：先关掉 VPN，换个名字，或者等 15 分钟再试。每个手机号只能申请一个，申请过的话页面上会直接显示。")
        }

        Section {
            TextField("api_id（一串数字）", text: $apiID)
                .keyboardType(.numberPad)
            TextField("api_hash（32 位字母数字）", text: $apiHash)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            Button {
                telegram.saveCredentials(apiID: apiID, apiHash: apiHash)
            } label: {
                Label("下一步", systemImage: "arrow.right.circle.fill")
            }
            .disabled(apiID.isEmpty || apiHash.isEmpty)
        } footer: {
            Text("这两个只存在你的手机里，泡泡音用它们代表「你自己做的 Telegram 客户端」去连接 Telegram。")
        }
    }

    // MARK: - 第 2 步：手机号

    private var phoneSection: some View {
        Section {
            TextField("+81 90 1234 5678", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            Button {
                telegram.sendPhone(phone)
            } label: {
                Label("发送验证码", systemImage: "paperplane.fill")
            }
        } header: {
            Text("登录你的 Telegram 账号")
        } footer: {
            Text("填你平时用的 Telegram 手机号，要带国家区号。日本号码是 +81，后面去掉开头的 0。")
        }
    }

    private var changeCredentialsSection: some View {
        Section {
            Button("换一个 api_id", role: .destructive) {
                telegram.resetCredentials()
            }
        }
    }

    // MARK: - 第 3 步：验证码 / 密码 / 邮箱

    private func codeSection(hint: String) -> some View {
        Section {
            TextField("验证码", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button {
                telegram.sendCode(code)
            } label: {
                Label("登录", systemImage: "checkmark.circle.fill")
            }
            Button("没收到？重新发送验证码") {
                telegram.resendCode()
            }
        } header: {
            Text("输入验证码")
        } footer: {
            Text(hint)
        }
    }

    private func passwordSection(hint: String) -> some View {
        Section {
            SecureField("两步验证密码", text: $password)
                .textContentType(.password)
            Button {
                telegram.sendPassword(password)
            } label: {
                Label("登录", systemImage: "checkmark.circle.fill")
            }
        } header: {
            Text("你的账号开了两步验证")
        } footer: {
            Text(hint.isEmpty ? "输入你在 Telegram 里设置的密码。" : "密码提示：\(hint)")
        }
    }

    private var emailSection: some View {
        Section {
            TextField("邮箱地址", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                telegram.sendEmail(email)
            } label: {
                Label("发送邮箱验证码", systemImage: "envelope.fill")
            }
        } header: {
            Text("Telegram 要求绑定一个登录邮箱")
        }
    }

    private func emailCodeSection(pattern: String) -> some View {
        Section {
            TextField("邮箱验证码", text: $emailCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button {
                telegram.sendEmailCode(emailCode)
            } label: {
                Label("确认", systemImage: "checkmark.circle.fill")
            }
        } header: {
            Text("输入邮箱里的验证码")
        } footer: {
            Text(pattern.isEmpty ? "看一下你的邮箱。" : "验证码发到了 \(pattern)")
        }
    }

    // MARK: - 第 4 步：选频道

    private var channelPickerSection: some View {
        Section {
            if telegram.loadingChannels {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取你加入的频道…")
                }
            } else if telegram.channelChoices.isEmpty {
                Text("没找到频道。点下面重新读取一次试试。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(telegram.channelChoices) { choice in
                    Button {
                        choosingChannel = false
                        telegram.choose(choice)
                    } label: {
                        HStack {
                            Image(systemName: "megaphone.fill")
                                .foregroundStyle(Theme.blue)
                            Text(choice.title)
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            if choice.id == telegram.channel?.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.blue)
                            }
                        }
                    }
                }
            }
            Button("重新读取频道列表") {
                Task { await telegram.loadChannels() }
            }
            if telegram.channel != nil {
                Button("取消") { choosingChannel = false }
            }
        } header: {
            Text("选一个要同步的频道")
        } footer: {
            Text("频道里的音频会下载进泡泡音；视频只留下声音。只在 Wi-Fi 下下载。")
        }
        .task {
            if telegram.channelChoices.isEmpty {
                await telegram.loadChannels()
            }
        }
    }

    // MARK: - 已经设置好

    @ViewBuilder
    private var syncSections: some View {
        Section {
            if let channel = telegram.channel {
                LabeledContent("频道", value: channel.title)
            }
            if let last = telegram.lastSync {
                LabeledContent("上次同步") {
                    Text(last, format: .relative(presentation: .named))
                }
            }
            SyncStatusRow(status: telegram.status)
            Button {
                Task { await telegram.sync(manual: true) }
            } label: {
                Label("现在同步", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(telegram.isSyncing)
            Button("换一个频道") {
                choosingChannel = true
            }
        } header: {
            Text("同步")
        } footer: {
            Text("每次打开泡泡音都会自动检查新歌，只在 Wi-Fi 下下载。频道里删掉的歌，泡泡音里也会跟着删掉。")
        }

        if telegram.ignoredCount > 0 {
            Section {
                Button("让它们重新同步回来") {
                    telegram.clearIgnored()
                }
            } footer: {
                Text("你在泡泡音里删掉了 \(telegram.ignoredCount) 首频道里的歌，它们不会再自动同步回来。")
            }
        }
    }

    private var accountSection: some View {
        Section {
            if let name = telegram.accountName {
                LabeledContent("账号", value: name)
            }
            Button("退出 Telegram 登录", role: .destructive) {
                confirmLogout = true
            }
        } header: {
            Text("账号")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(Theme.blue)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 同步状态的一行小字（设置页和歌曲列表上方都用）
struct SyncStatusRow: View {
    let status: TGSyncStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在看频道里有没有新歌…")
            }
            .font(.callout)
        case .downloading(let done, let total, let name, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Theme.blue)
                    Text("正在下载 \(done + 1)/\(total)")
                        .monospacedDigit()
                    Text(name)
                        .lineLimit(1)
                        .foregroundStyle(Theme.ink.opacity(0.6))
                }
                ProgressView(value: fraction)
                    .tint(Theme.blue)
            }
            .font(.callout)
        case .waitingForWiFi(let count):
            Label("还有 \(count) 首等连上 Wi-Fi 再下载", systemImage: "wifi.exclamationmark")
                .font(.callout)
        case .finished(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(Theme.teal)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }
}
