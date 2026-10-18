import AppKit
import WebKit

final class BrowserWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    private var webView: WKWebView!
    private let homeURL = URL(string: "https://www.bilibili.com/")!
    private var titleObserver: NSKeyValueObservation?
    private var hudView: NSView?
    private var hudLabel: NSTextField?
    private var hudIcon: NSImageView?
    private var hudHideWork: DispatchWorkItem?
    private var sensitivityItems: [NSMenuItem] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 1100, height: 700)
        window.title = "哔哩哔哩"
        // 记住上次窗口位置/大小:显式存 UserDefaults(frameAutosaveName 在本 App 上保存时机不可靠)
        if let saved = UserDefaults.standard.string(forKey: Self.windowFrameKey) {
            let r = NSRectFromString(saved)
            if r.width >= window.minSize.width && r.height >= window.minSize.height {
                window.setFrame(r, display: false)
            } else {
                window.center()
            }
        } else {
            window.center() // 首次启动(无存档)才居中
        }
        // 允许进入原生全屏(独立 Space,占满整块显示器)
        window.collectionBehavior = [.fullScreenPrimary]
        self.init(window: window)
        window.delegate = self
        setupWebView()
        setupMenu()
        webView.load(URLRequest(url: homeURL))
    }

    // MARK: - WebView

    /// 播放器悬停检测:mousemove/scroll 时用 elementFromPoint 命中测试,
    /// 状态变化(或悬停中每 300ms)经 biliHover 回传 {over, rect} 给原生(60ms 节流)。
    /// 每个同源 frame 都会注入(新版直播播放器位于 /blanc/<room> 的同源 iframe),
    /// rect 会逐级换算成顶层页面坐标,供音量 HUD 正确定位。
    static let hoverDetectJS = """
    (function(){
      // ---- 播放器/视频定位(每个 frame 各自执行) ----
      function mainVideo() {
        var vs = document.querySelectorAll('video');
        var best = null, bestArea = -1;
        for (var i = 0; i < vs.length; i++) {
          var a = (vs[i].videoWidth || 0) * (vs[i].videoHeight || 0);
          if (a > bestArea) { bestArea = a; best = vs[i]; }
        }
        return best;
      }
      // 暴露给原生:全屏切换前后读取/恢复暂停状态用
      window.__biliViewerMainVideo = mainVideo;

      // 旧版播放器 + 新版直播播放器(直播间 /blanc iframe 里的 #live-player 等)容器
      var PLAYER_SELECTOR = '.bpx-player-container, .bilibili-player, #live-player, #player-ctnr, .player-section, .live-player, .bpx-player-video-area';

      function findPlayer(x, y) {
        var el = document.elementFromPoint(x, y);
        if (!el) return null;
        if (el.tagName === 'VIDEO') return el;
        var c = el.closest && el.closest(PLAYER_SELECTOR);
        if (c) return c;
        // 兜底:指针落在主视频矩形内(新版直播播放器有弹幕/控制层遮挡,命中的 DOM 不一定是容器)
        var v = mainVideo();
        if (v) {
          var r = v.getBoundingClientRect();
          if (r.width > 0 && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return v;
        }
        return null;
      }

      // 本 frame 视口坐标 → 顶层页面坐标(同源 iframe 逐级累加)
      function rectInTop(r) {
        var x = r.left, y = r.top, w = r.width, h = r.height, win = window;
        try {
          while (win !== win.top) {
            var fe = win.frameElement;
            if (!fe) break;
            var pr = fe.getBoundingClientRect();
            x += pr.left;
            y += pr.top;
            win = win.parent;
          }
        } catch (e) {}
        return { x: x, y: y, w: w, h: h };
      }

      var over = false, lastX = -1, lastY = -1, lastT = 0, lastPost = 0;
      function post(v, x, y) {
        var target = findPlayer(x, y);
        var rect = null;
        if (target) rect = rectInTop(target.getBoundingClientRect());
        try { window.webkit.messageHandlers.biliHover.postMessage({ over: v, rect: rect }); } catch (e) {}
      }
      function update(x, y, force) {
        lastX = x; lastY = y;
        var now = Date.now();
        if (!force && now - lastT < 60) return;
        lastT = now;
        var v = !!findPlayer(x, y);
        if (v !== over) {
          over = v;
          lastPost = now;
          post(v, x, y);
        } else if (v && now - lastPost > 300) {
          lastPost = now;
          post(v, x, y);
        }
      }
      document.addEventListener('mousemove', function(e){ update(e.clientX, e.clientY, false); }, true);
      document.addEventListener('scroll', function(){ if (lastX >= 0) update(lastX, lastY, true); }, true);

      // 接管视频区域的单击/双击(WebKit 不支持 HTML5 element fullscreen,由原生组合实现):
      // - 单击 = 切换播放/暂停(延迟 260ms,给双击留取消窗口)
      // - 双击 = 网页版式真全屏(原生:网页全屏 + 窗口全屏),不改变播放状态
      // 控制栏/弹幕输入/按钮等可交互区域不拦截,保持 B 站原生行为
      function inVideoArea(e) {
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el) return false;
        var p = (el.tagName === 'VIDEO') ? el : (el.closest && el.closest('.bpx-player-container, .bilibili-player'));
        if (!p) return false;
        if (el.closest && el.closest('button, a, input, [role=button], .bpx-player-ctrl-btn, .bpx-player-control-bottom, .bpx-player-sending-bar, .bpx-player-video-progress, .bpx-player-video-btnstart, .bilibili-player-video-control')) return false;
        return true;
      }
      var pendingClickTimer = null;
      function togglePlay() {
        var v = mainVideo();
        if (!v) return;
        if (v.paused) { v.play(); } else { v.pause(); }
      }
      document.addEventListener('click', function(e){
        if (!inVideoArea(e)) return;
        e.preventDefault(); e.stopPropagation();
        if (pendingClickTimer) { // 双击的第二次 click:取消单击动作,交给 dblclick
          clearTimeout(pendingClickTimer); pendingClickTimer = null;
          return;
        }
        pendingClickTimer = setTimeout(function(){ pendingClickTimer = null; togglePlay(); }, 260);
      }, true);
      document.addEventListener('dblclick', function(e){
        if (!inVideoArea(e)) return;
        e.preventDefault(); e.stopPropagation();
        if (pendingClickTimer) { clearTimeout(pendingClickTimer); pendingClickTimer = null; }
        try { window.webkit.messageHandlers.biliDblClick.postMessage({}); } catch (err) {}
      }, true);

      // 供原生调用:调整本 frame 内主视频的"播放器音量",返回调节后的音量(0~1,-1=无视频)。
      // dv 是原生算好的音量增量;这里不改派发合成 WheelEvent(会冒泡导致页面额外滚动)
      window.__biliViewerWheelVolume = function(dv) {
        var v = mainVideo();
        if (!v) return -1;
        if (v.muted && dv > 0) v.muted = false;
        var nv = Math.min(1, Math.max(0, (v.volume || 0) + dv));
        v.volume = nv;
        return nv;
      };
      // 顶层聚合入口:直播播放器在 iframe 里,原生只会在主 frame 执行 JS,
      // 这里沿同源 frame 树找到真正带视频的那个 frame。
      if (window === window.top) {
        window.__biliViewerWheelVolumeGlobal = function(dv) {
          function walk(win) {
            try {
              if (win.__biliViewerWheelVolume) {
                var r = win.__biliViewerWheelVolume(dv);
                if (r >= 0) return r;
              }
            } catch (e) {}
            try {
              for (var i = 0; i < win.frames.length; i++) {
                var r2 = walk(win.frames[i]);
                if (r2 >= 0) return r2;
              }
            } catch (e) {}
            return -1;
          }
          return walk(window);
        };
      }
    })();
    """

    /// 直播播放器兜底:`navigator.mediaDevices` 在 WKWebView 里缺省为 undefined,
    /// 而 B 站直播播放器初始化时会无条件调用 enumerateDevices(),导致 TypeError、画面不出来。
    /// 正常情况下 Info.plist 里声明麦克风/摄像头用途后系统会提供真实 API,这里只在缺失时补一个空实现。
    static let mediaDevicesFallbackJS = """
    (function(){
      if (navigator.mediaDevices) return;
      var noop = function(){};
      var stub = {
        enumerateDevices: function(){ return Promise.resolve([]); },
        getUserMedia: function(){ return Promise.reject(new Error('NotAllowedError')); },
        getDisplayMedia: function(){ return Promise.reject(new Error('NotAllowedError')); },
        addEventListener: noop,
        removeEventListener: noop,
        getSupportedConstraints: function(){ return {}; },
        dispatchEvent: function(){ return false; }
      };
      try {
        Object.defineProperty(Navigator.prototype, 'mediaDevices', { configurable: true, get: function(){ return stub; } });
      } catch (e) {
        try { Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: stub }); } catch (e2) {}
      }
    })();
    """

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        // 持久化登录:使用默认持久化 DataStore,Cookie 长期保留
        config.websiteDataStore = .default()
        // 允许视频/音频自动播放
        config.mediaTypesRequiringUserActionForPlayback = []
        // macOS 上 WKWebView 的 HTML5 全屏由系统自动支持

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        // 直播播放器兜底:WKWebView 缺省不提供 navigator.mediaDevices,
        // B 站直播播放器初始化会调用它,缺失时直接抛错导致画面出不来
        let mediaScript = WKUserScript(source: Self.mediaDevicesFallbackJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(mediaScript)

        // 注入播放器悬停检测脚本:光标在播放器上时滚轮交给原生调音量
        let hoverScript = WKUserScript(source: Self.hoverDetectJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(hoverScript)
        config.userContentController.add(self, name: "biliHover")
        config.userContentController.add(self, name: "biliDblClick")

        webView = VolumeWebView(frame: .zero, configuration: config)
        if let volumeWebView = webView as? VolumeWebView {
            volumeWebView.onVolumeAdjust = { [weak self] value in
                self?.showVolumeHUD(value)
            }
            // 鼠标侧键:3 = 后退,4 = 前进
            volumeWebView.onNavigateBack = { [weak self] in self?.webView.goBack() }
            volumeWebView.onNavigateForward = { [weak self] in self?.webView.goForward() }
            // ESC:窗口全屏时统一退出"网页全屏 + 窗口全屏"
            volumeWebView.isWindowFullscreen = { [weak self] in self?.window?.styleMask.contains(.fullScreen) ?? false }
            volumeWebView.onExitFullscreen = { [weak self] in self?.exitFullscreenCombo() }
            // 悬停播放器时滚轮 → 调整播放器(视频)音量
            volumeWebView.onPlayerVolumeAdjust = { [weak self] deltaY in
                guard let self, let webView = self.webView else { return }
                let js = "window.__biliViewerWheelVolumeGlobal && window.__biliViewerWheelVolumeGlobal(\(deltaY))"
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let result = try? await webView.evaluateJavaScript(js)
                    if let v = result as? Double, v >= 0 {
                        self.showVolumeHUD(Float32(v))
                    }
                }
            }
        }
        // 注入标准桌面 Chrome UA,避免被 B 站判定为"浏览器版本过低"
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]

        window?.contentView = webView
        titleObserver = webView.observe(\.title, options: [.new]) { [weak self] web, _ in
            DispatchQueue.main.async {
                self?.window?.title = web.title?.isEmpty == false ? web.title! : "哔哩哔哩"
            }
        }
    }

    // MARK: - 菜单

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App 菜单
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 BiliViewer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // 滚轮调音量的速度:菜单里即时切换,不用重新编译
        let sensItem = NSMenuItem(title: "滚轮音量灵敏度", action: nil, keyEquivalent: "")
        let sensMenu = NSMenu(title: "滚轮音量灵敏度")
        sensItem.submenu = sensMenu
        appMenu.addItem(sensItem)
        for (title, pct) in [("慢", 60), ("标准", 100), ("快", 150)] {
            let item = NSMenuItem(title: title, action: #selector(setVolumeSensitivity(_:)), keyEquivalent: "")
            item.tag = pct
            item.target = self
            item.state = abs(VolumeWebView.playerVolumeSensitivity - Double(pct) / 100.0) < 0.001 ? .on : .off
            sensMenu.addItem(item)
            sensitivityItems.append(item)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 BiliViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 页面菜单
        let pageMenuItem = NSMenuItem()
        mainMenu.addItem(pageMenuItem)
        let pageMenu = NSMenu(title: "页面")
        pageMenuItem.submenu = pageMenu
        pageMenu.addItem(withTitle: "重新加载", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        pageMenu.addItem(withTitle: "强制刷新(绕过缓存)", action: #selector(forceReloadPage(_:)), keyEquivalent: "R")
        pageMenu.addItem(.separator())
        let back = pageMenu.addItem(withTitle: "后退", action: #selector(goBack(_:)), keyEquivalent: "[")
        back.keyEquivalentModifierMask = [.command]
        let forward = pageMenu.addItem(withTitle: "前进", action: #selector(goForward(_:)), keyEquivalent: "]")
        forward.keyEquivalentModifierMask = [.command]
        pageMenu.addItem(.separator())
        pageMenu.addItem(withTitle: "主页", action: #selector(goHome(_:)), keyEquivalent: "h")
        pageMenu.addItem(.separator())
        pageMenu.addItem(withTitle: "实际大小", action: #selector(actualSize(_:)), keyEquivalent: "0")

        // 编辑菜单(让搜索框等获得复制/粘贴/全选)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // 视图菜单(全屏)
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "视图")
        viewMenuItem.submenu = viewMenu
        // 标准 macOS 原生全屏:独立 Space、占满整块显示器、自动隐藏菜单栏与 Dock
        viewMenu.addItem(withTitle: "进入/退出全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        (viewMenu.items.last as? NSMenuItem)?.keyEquivalentModifierMask = [.control, .command]

        // 窗口菜单
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - 菜单动作

    @objc private func reloadPage(_ sender: Any?) { webView.reload() }
    @objc private func forceReloadPage(_ sender: Any?) {
        webView.reloadFromOrigin()
    }
    @objc private func goBack(_ sender: Any?) { webView.goBack() }
    @objc private func goForward(_ sender: Any?) { webView.goForward() }
    @objc private func goHome(_ sender: Any?) { webView.load(URLRequest(url: homeURL)) }
    @objc private func setVolumeSensitivity(_ sender: NSMenuItem) {
        VolumeWebView.setPlayerVolumeSensitivity(Double(sender.tag) / 100.0)
        for item in sensitivityItems { item.state = (item === sender) ? .on : .off }
    }
    @objc private func actualSize(_ sender: Any?) { webView.magnification = 1.0 }

    // MARK: - WKUIDelegate(弹窗/新窗口)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 允许登录三方跳转等弹窗在主窗口打开
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    // MARK: - NSWindowDelegate

    private static let windowFrameKey = "BiliViewerSavedWindowFrame"

    /// 保存窗口位置/大小(全屏状态下的 frame 不存,退出全屏会自动回到原 frame)
    private func saveWindowFrame() {
        guard let w = window, !w.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: Self.windowFrameKey)
    }

    func windowWillClose(_ notification: Notification) {
        titleObserver?.invalidate()
        saveWindowFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveWindowFrame()
    }

    /// 原生全屏时自动隐藏菜单栏和 Dock,画面占满整块显示器
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        [.autoHideDock, .autoHideMenuBar, .fullScreen]
    }

    // MARK: - 音量 HUD

    /// 简洁 HUD:纯白扬声器图标 + 数字,无背景(靠柔和投影保证可见),定位在播放器区域正中间
    private func showVolumeHUD(_ volume: Float32) {
        guard let contentView = window?.contentView else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.hudView == nil {
                let v = PassthroughView(frame: NSRect(x: 0, y: 0, width: 54, height: 24))
                v.wantsLayer = true
                v.layer?.masksToBounds = false
                // 无深色背景,用柔和投影保证在浅色画面上仍可读
                v.layer?.shadowColor = NSColor.black.cgColor
                v.layer?.shadowOpacity = 0.6
                v.layer?.shadowRadius = 3
                v.layer?.shadowOffset = .zero
                let icon = NSImageView(frame: NSRect(x: 0, y: 4, width: 18, height: 16))
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                icon.contentTintColor = .white
                icon.appearance = NSAppearance(named: .aqua) // 固定亮色外观,避免暗色模式影响
                let label = NSTextField(labelWithString: "")
                label.textColor = .white
                label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
                label.alignment = .left
                label.frame = NSRect(x: 19, y: 2, width: 34, height: 20)
                label.autoresizingMask = []
                v.addSubview(icon)
                v.addSubview(label)
                v.alphaValue = 0
                contentView.addSubview(v, positioned: .above, relativeTo: nil)
                self.hudView = v
                self.hudLabel = label
                self.hudIcon = icon
            }
            guard let hud = self.hudView, let label = self.hudLabel, let icon = self.hudIcon else { return }

            // HUD 定位:优先用播放器区域中心(页面 CSS 坐标 → 视图坐标,需翻转 Y 轴)
            var origin = NSPoint(x: (contentView.bounds.width - hud.frame.width) / 2,
                                 y: (contentView.bounds.height - hud.frame.height) / 2)
            if let wv = self.webView as? VolumeWebView, !wv.playerRectInPage.isEmpty {
                let r = wv.playerRectInPage
                let viewH = contentView.bounds.height
                let cx = r.minX + r.width / 2
                let cy = viewH - (r.minY + r.height / 2) // CSS 顶部原点 → NSView 底部原点
                origin = NSPoint(x: cx - hud.frame.width / 2, y: cy - hud.frame.height / 2)
            }
            hud.setFrameOrigin(origin)
            let pct = Int(round(volume * 100))
            let symbolName: String
            if volume <= 0.001 {
                symbolName = "speaker.slash.fill"
            } else if volume < 0.5 {
                symbolName = "speaker.wave.1.fill"
            } else {
                symbolName = "speaker.wave.3.fill"
            }
            icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "音量")
            label.stringValue = "\(pct)"
            hud.animator().alphaValue = 1
            self.hudHideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.hudView?.animator().alphaValue = 0
            }
            self.hudHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }
}

/// 支持滚轮调音量与鼠标侧键导航的 WKWebView:
/// - 光标悬停播放器(B 站播放器容器/video)时滚轮:调整"播放器音量"(经 JS 转发,HUD 显示视频音量)
/// - ⌥+滚轮:任意位置调系统音量
/// - 鼠标侧键 3/4:后退 / 前进
/// - 其余情况:正常页面滚动
final class VolumeWebView: WKWebView {
    var onVolumeAdjust: ((Float32) -> Void)?
    var onPlayerVolumeAdjust: ((Double) -> Void)?
    var onNavigateBack: (() -> Void)?
    var onNavigateForward: (() -> Void)?
    var isCursorOverPlayer = false
    /// 播放器在页面视口中的矩形(CSS 坐标,顶部原点),由注入 JS 上报
    var playerRectInPage = NSRect.zero

    // MARK: - 滚轮音量手感

    /// 每 1 点滚动位移(scrollingDeltaY)对应的播放器音量变化。
    /// 原来 0.004 太快:一次触控板滑动就能把音量拉满/拉到底,这里降到 0.0012(约 1/3.3 速度)。
    private static let playerVolumeGainPrecise = 0.0012
    /// 每 1 行滚动(deltaY)对应的播放器音量变化(普通滚轮鼠标),单次事件最多按 3 行计
    private static let playerVolumeGainWheel = 0.006
    /// 单次滚动事件的音量变化上限,避免鼠标加速/高速滚动时一步跳太多
    private static let playerVolumeMaxStep = 0.01

    /// 灵敏度倍率(默认 1.0)。菜单「滚轮音量灵敏度」可即时切换,
    /// 也可以用 `defaults write local.biliviewer PlayerVolumeScrollSensitivity -float 0.6` 微调
    static var playerVolumeSensitivity: Double = {
        let v = UserDefaults.standard.double(forKey: PlayerVolumeScrollSensitivityKey)
        return v > 0 ? v : 1.0
    }()
    static let PlayerVolumeScrollSensitivityKey = "PlayerVolumeScrollSensitivity"

    /// 写入并立即生效
    static func setPlayerVolumeSensitivity(_ value: Double) {
        let v = value > 0 ? value : 1.0
        playerVolumeSensitivity = v
        UserDefaults.standard.set(v, forKey: PlayerVolumeScrollSensitivityKey)
    }

    /// 把一次滚轮事件换算成播放器音量增量(带符号,向上滚为正)
    private static func playerVolumeDelta(for event: NSEvent, dy: CGFloat) -> Double {
        let raw: Double
        if event.hasPreciseScrollingDeltas {
            raw = Double(dy) * playerVolumeGainPrecise
        } else {
            raw = max(-3, min(3, Double(dy))) * playerVolumeGainWheel
        }
        let step = raw * playerVolumeSensitivity
        return max(-playerVolumeMaxStep, min(playerVolumeMaxStep, step))
    }

    override func scrollWheel(with event: NSEvent) {
        // 惯性滚动(手指抬起后的减速阶段)不再继续调音量:
        // 否则一甩手指,惯性事件会把音量一路推到 0% 或 100%
        if !event.momentumPhase.isEmpty {
            if isCursorOverPlayer { return }
            super.scrollWheel(with: event)
            return
        }
        // 关键:高精度设备(触控板/Magic Mouse)上 deltaY 常为 0,真实量在 scrollingDeltaY
        let dy: CGFloat = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard abs(dy) > 0.0001 else {
            super.scrollWheel(with: event)
            return
        }
        if isCursorOverPlayer {
            // dy(AppKit 向上滚为正)直接作为音量增量符号:向上滚 = 音量增。
            let dv = Self.playerVolumeDelta(for: event, dy: dy)
            if abs(dv) > 0.000_000_1 { onPlayerVolumeAdjust?(dv) }
            return
        }
        if event.modifierFlags.contains(.option) {
            let step: Float32 = event.hasPreciseScrollingDeltas ? 0.008 : 0.04
            onVolumeAdjust?(SystemVolume.adjust(byDelta: Float32(dy) * step))
            return
        }
        super.scrollWheel(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3: onNavigateBack?()   // 侧键后退
        case 4: onNavigateForward?() // 侧键前进
        default: super.otherMouseDown(with: event)
        }
    }

    var isWindowFullscreen: (() -> Bool)?
    var onExitFullscreen: (() -> Void)?

    /// 窗口全屏时拦截 ESC:统一退出"网页全屏 + 窗口全屏"两层,
    /// 否则 ESC 会被 B 站网页截走只退网页全屏,留下窗口还在全屏
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, isWindowFullscreen?() == true {
            onExitFullscreen?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - 播放器悬停状态回传

/// HUD 用:鼠标事件穿透,避免挡住播放器中央的单击/双击
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension BrowserWindowController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "biliHover":
            handleHoverMessage(message)
        case "biliDblClick":
            togglePlayerFullscreen()
        default:
            break
        }
    }

    private func handleHoverMessage(_ message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let over = payload["over"] as? Bool else { return }
        guard let wv = webView as? VolumeWebView else { return }
        wv.isCursorOverPlayer = over
        if let r = payload["rect"] as? [String: Any],
           let x = r["x"] as? Double, let y = r["y"] as? Double,
           let w = r["w"] as? Double, let h = r["h"] as? Double {
            wv.playerRectInPage = NSRect(x: x, y: y, width: w, height: h)
        }
    }

    /// 统一的全屏切换入口:切换前记住播放器播放状态,切换后纠正回原状态
    /// (B 站全屏切换时会重建播放器:原本暂停的会自动播放,原本播放的会变成暂停)
    /// 切换后 2 秒内每 250ms 轮询一次,状态被 B 站改动就纠正回切换前的样子(双向)
    private func performFSChange(clickWebFS: Bool, toggleWindow: Bool) {
        guard let webView else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wasPaused = ((try? await webView.evaluateJavaScript(Self.mainVideoPausedJS)) as? Int) == 1
            let wantPaused = wasPaused ? 1 : 0
            if clickWebFS {
                _ = try? await webView.evaluateJavaScript(Self.clickWebFSJS)
            }
            if toggleWindow {
                self.window?.toggleFullScreen(nil)
            }
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let now = (try? await webView.evaluateJavaScript(Self.mainVideoPausedJS)) as? Int,
                      now != -1, now != wantPaused else { continue }
                _ = try? await webView.evaluateJavaScript(wasPaused ? Self.pauseMainVideoJS : Self.playMainVideoJS)
            }
        }
    }

    /// 双击播放器:网页全屏(播放器撑满窗口)+ 原生窗口全屏(窗口占满显示器)= 网页版真全屏
    /// 再双击时按当前状态对称退出
    private func togglePlayerFullscreen() {
        guard let webView else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // B 站播放器容器 data-screen:normal=普通 web=网页全屏 full=HTML5全屏
            let state = (try? await webView.evaluateJavaScript(Self.screenStateJS)) as? String ?? "none"
            let webFSActive = state == "web" || state == "full"
            let windowFull = self.window?.styleMask.contains(.fullScreen) ?? false
            switch (webFSActive, windowFull) {
            case (false, false), (true, true): // 进入 / 退出:两层一起切
                self.performFSChange(clickWebFS: true, toggleWindow: true)
            case (true, false):                // 网页全屏开着但窗口没全屏 → 只进窗口全屏
                self.performFSChange(clickWebFS: false, toggleWindow: true)
            case (false, true):                // 窗口全屏但网页全屏没开 → 只开网页全屏
                self.performFSChange(clickWebFS: true, toggleWindow: false)
            }
        }
    }

    /// ESC(窗口全屏时):两层一起退
    private func exitFullscreenCombo() {
        guard let webView else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = (try? await webView.evaluateJavaScript(Self.screenStateJS)) as? String ?? "none"
            self.performFSChange(clickWebFS: state == "web" || state == "full",
                                 toggleWindow: self.window?.styleMask.contains(.fullScreen) == true)
        }
    }

    private static let screenStateJS = "(function(){var c=document.querySelector('.bpx-player-container'); return c ? (c.getAttribute('data-screen')||'normal') : 'none';})()"
    private static let clickWebFSJS = "(function(){var b=document.querySelector('.bpx-player-ctrl-web, .squirtle-video-pagefullscreen'); if(b){b.click(); return 1;} return 0;})()"
    private static let mainVideoPausedJS = "(function(){var v=window.__biliViewerMainVideo&&window.__biliViewerMainVideo(); return v?(v.paused?1:0):-1;})()"
    private static let pauseMainVideoJS = "(function(){var v=window.__biliViewerMainVideo&&window.__biliViewerMainVideo(); if(v&&!v.paused){v.pause(); return 1;} return 0;})()"
    private static let playMainVideoJS = "(function(){var v=window.__biliViewerMainVideo&&window.__biliViewerMainVideo(); if(v&&v.paused){var p=v.play(); if(p&&p.catch)p.catch(function(){}); return 1;} return 0;})()"
}
