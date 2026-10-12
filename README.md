# 泡泡音 BubbleTune

洗澡时带进浴室用的 iPhone 听歌 app 🫧

- **歌曲列表**：一个总列表，拖动排序、左滑删除、搜索；记住上次放到哪首、第几秒
- **播放顺序**：顺序 / 倒序（从最后一首往前）/ 随机（洗牌式，一轮放完才会重复，也不会连着放同一首）
- **播完之后**：列表循环 / 放完就停 / 单曲循环
- **洗澡模式**：深色大字全屏，屏幕不会自动熄灭
  - 一进去就锁住，只有「下一首」和「暂停/播放」能按
  - 按钮要按住约 0.3 秒才生效，水滴碰一下不会乱切歌（设置里可以改）
  - 显示歌名、歌手、封面、现在几点、已经洗了多久
  - 底部「滑动退出」，要把小圆球拖到最右边才能出来
- **导入歌曲**
  - 右上角「＋」从「文件」App / iCloud 云盘选，可以多选
  - 别的 App 里「分享」→「泡泡音」
  - 「文件」App →「我的 iPhone」→「泡泡音」文件夹，直接放歌进去
  - 电脑：Windows 用「Apple 设备」App（或 iTunes）的「文件」，Mac 用访达
- 锁屏、控制中心、耳机都能控制播放；来电自动暂停，挂断接着放；拔耳机自动暂停

支持 mp3 · m4a · aac · flac · wav · aiff（iPhone 自带解码器能放的格式）。
Apple Music 订阅下载的歌有版权保护，自己做的 app 放不了。

## 怎么编译

不需要 Mac。每次推送到 `main` 分支，GitHub Actions 会在云端 Mac 上：

1. 用 XcodeGen 根据 `project.yml` 生成 Xcode 工程
2. 编译出不签名的 App
3. 打包成 `BubbleTune.ipa`，发布到 Releases
4. 把编译报告写到 `build-report` 分支的 `report.txt`

## 怎么装到 iPhone

用 SideStore（免费 Apple ID）安装 Releases 里最新的 `BubbleTune.ipa`。
免费 Apple ID 签出来的 App 每 7 天要在 SideStore 里点一次「Refresh All」续期。
免费账号最多同时装 3 个自签 app（SideStore 自己也算 1 个）。

## 代码结构

- `App/PlayQueue.swift`：「下一首放谁」的纯逻辑（顺序/倒序/随机 × 循环方式）
- `App/Player.swift`：真正放声音、后台播放、锁屏控制、来电打断
- `App/Library.swift`：歌曲列表、导入、扫描文件夹、删除排序
- `App/ShowerModeView.swift`：洗澡模式
- `App/HoldButton.swift`：按住才生效的大按钮、滑动退出
- `App/RootView.swift`、`NowPlayingView.swift`、`SettingsView.swift`：其他界面
- `Tests/`：PlayQueue 的 Python 一比一版本和测试（`cd Tests && python3 test_queue.py`）
