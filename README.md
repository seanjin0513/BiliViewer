# BiliViewer

一个用纯 Swift + AppKit 封装的哔哩哔哩网页版 macOS 原生客户端。零第三方依赖,无需 Xcode,只要 Command Line Tools 即可构建。

## 特性

- **完整网页体验**:基于 WKWebView,登录状态持久化,窗口标题跟随页面
- **滚轮音量**:光标悬停在播放器上时,滚轮直接调节**视频音量**(非系统音量),其他位置正常滚动页面;`⌥ + 滚轮` 调节系统音量。调节幅度偏缓(单次滚动最多 1%),惯性滚动不参与,不会一甩就冲到底;想再改手感见下方「滚轮音量灵敏度」
- **音量 HUD**:白色扬声器图标 + 数字,显示在播放器中央,1 秒自动淡出
- **鼠标侧键**:前进 / 后退
- **双击真全屏**:双击视频 = B 站网页全屏 + 原生窗口全屏(占满整块显示器),再双击或 `ESC` 退出;退出后播放状态不受影响
- **单击暂停/播放**:单击视频区域切换播放,双击不会误触
- **窗口记忆**:记住窗口大小和位置,下次启动自动恢复
- **快捷键**:`⌘R` 刷新 / `⌘⇧R` 强制刷新 / `⌘←` `⌘→` 前进后退 / `⌃⌘F` 全屏
- **直播可播放**:直播间(含新版播放器 iframe)正常播放,同样支持悬停滚轮调音量

## 构建

需要 macOS 12+ 和 Xcode Command Line Tools(`xcode-select --install`)。

```bash
./build.sh
```

脚本会自动完成:生成图标 → `swiftc` 编译 → 组装 App bundle → ad-hoc 签名 → 打包 DMG。产物在 `build/` 下:

> 若项目放在 iCloud/OneDrive 等同步盘里,签名前脚本会先执行 `xattr -cr` 清掉同步盘附带的 Finder 扩展属性,否则 `codesign` 会报 `resource fork, Finder information, or similar detritus not allowed`

- `build/BiliViewer.app` — 直接拖入「应用程序」即可使用
- `build/BiliViewer.dmg` — 分发用镜像

## 项目结构

```
BiliViewer/
├── Sources/
│   ├── main.swift          # 入口:NSApplication 启动 + 菜单栏
│   ├── BrowserWindow.swift # 主窗口:WKWebView、滚轮/侧键/HUD/全屏等全部交互逻辑
│   └── SystemVolume.swift  # CoreAudio 系统音量读写
├── scripts/
│   └── make_icon.swift     # 用 CoreGraphics 生成应用图标
├── Info.plist
└── build.sh                # 一键构建脚本
```

## 实现要点

- **UA 注入**:默认 UA 会被 B 站判定"浏览器版本过低",注入 Chrome UA 解决
- **播放器悬停检测**:注入 JS,用 `elementFromPoint` + `closest()` 检测光标是否在播放器上,60ms 节流,经 `WKScriptMessageHandler` 回传原生
- **播放器音量**:直接修改 `video.volume`(不走合成事件,B 站会忽略非 `isTrusted` 事件)
- **全屏播放状态保护**:B 站全屏切换会重建播放器(暂停的变播放、播放的变暂停),切换后 2 秒内轮询纠正回原状态
- **AppKit 与浏览器滚动方向**:NSEvent 的 `deltaY`(向上滚为正)与浏览器 WheelEvent 相反,转换时需注意;触控板等精确设备要用 `hasPreciseScrollingDeltas` 判断
- **直播播放修复**:WKWebView 默认不暴露 `navigator.mediaDevices`,而 B 站直播播放器初始化会无条件调用 `navigator.mediaDevices.enumerateDevices()`,抛 `TypeError` 后画面一直黑屏(普通视频页不走这条路径,所以只有直播坏)。修复分两层:`Info.plist` 声明 `NSMicrophoneUsageDescription` / `NSCameraUsageDescription`(系统据此提供真实 API),同时在页面注入缺失时的空实现兜底
- **直播间播放器在 iframe 里**:新版直播间把播放器放进 `live.bilibili.com/blanc/<room>` 同源 iframe,主 frame 拿不到 `<video>`。悬停检测脚本按 frame 注入,原生只往主 frame 发 JS,因此注入脚本里额外提供 `__biliViewerWheelVolumeGlobal`,沿同源 frame 树找到真正持有视频的 frame 调音量;上报的播放器矩形也会逐级换算回顶层坐标,HUD 才能落在播放器中央

## 滚轮音量灵敏度

默认的调节速度已经降到了旧版的大约 1/3,并且单次滚动事件最多改变 1%(惯性滚动不参与)。觉得还想再调,有两种方式:

1. 菜单 **BiliViewer → 滚轮音量灵敏度 → 慢 / 标准 / 快**,即时生效,重启后保持;
2. 命令行微调任意倍率(默认 `1.0`):

```bash
defaults write local.biliviewer PlayerVolumeScrollSensitivity -float 0.6   # 更慢
defaults write local.biliviewer PlayerVolumeScrollSensitivity -float 1.5   # 更快
```

要彻底改基准值,可调 `VolumeWebView` 里的三个常量:`playerVolumeGainPrecise`(触控板/Magic Mouse,按滚动位移)、`playerVolumeGainWheel`(普通滚轮,按行数)、`playerVolumeMaxStep`(单次事件上限)。

## License

MIT
