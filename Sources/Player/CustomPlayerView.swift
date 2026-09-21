import SwiftUI
import WebKit

// MARK: - BiliKit 架构的高能无边框播放器 (原生 VideoToolbox 硬解，秒开 4K/1080P60)
struct BiliPlayerWebView: NSViewRepresentable {
    let bvid: String
    let cid: Int
    @Binding var volume: Float
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        // 🌟 1. 彻底切断 PCDN：封杀 WebRTC 接口，杜绝任何后台借带宽偷上传！
        let disablePCDN = """
        window.RTCPeerConnection = null;
        window.webkitRTCPeerConnection = null;
        window.mozRTCPeerConnection = null;
        """
        let script = WKUserScript(source: disablePCDN, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        // 确保深色半透明现代背景，无白屏闪烁
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        
        loadPlayer(webView: webView)
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 同步音量
        let js = "if(window.player && player.volume){ player.volume(\(volume)); } else { var v = document.querySelector('video'); if(v){ v.volume = \(volume); } }"
        nsView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    private func loadPlayer(webView: WKWebView) {
        // 注入登录态 Cookie
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let domain = ".bilibili.com"
        
        let sess = CookieManager.shared.sessdata
        let jct = CookieManager.shared.biliJct
        let uid = CookieManager.shared.dedeUserId
        let buvid = CookieManager.shared.buvid3
        
        let cookies = [
            ("SESSDATA", sess),
            ("bili_jct", jct),
            ("DedeUserID", uid),
            ("buvid3", buvid)
        ]
        
        let group = DispatchGroup()
        for (name, val) in cookies where !val.isEmpty {
            group.enter()
            if let cookie = HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: name,
                .value: val,
                .secure: "TRUE"
            ]) {
                cookieStore.setCookie(cookie) { group.leave() }
            } else {
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            // 加载官方轻量极速播放流（纯净内嵌，自动起播真 4K，无冗余网页元素）
            if let url = URL(string: "https://www.bilibili.com/blackboard/html5mobileplayer.html?bvid=\(bvid)&cid=\(cid)&p=1&as_wide=1&danmaku=1&has_next=0") {
                var req = URLRequest(url: url)
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
                req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
                webView.load(req)
            }
        }
    }
    
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BiliPlayerWebView
        weak var webView: WKWebView?
        
        init(_ parent: BiliPlayerWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 样式净化：隐藏所有无关手机端下引导，铺满整个 16:9 画幅，音量对齐
            let css = """
            .player-mobile-top-bar, .player-mobile-control-play, .launch-app-btn, .m-video-danmaku { display: none !important; }
            body, html { margin: 0; padding: 0; background: #000 !important; overflow: hidden; width: 100%; height: 100%; }
            video { width: 100% !important; height: 100% !important; object-fit: contain; }
            """
            let js = """
            var s = document.createElement('style');
            s.innerHTML = `\(css)`;
            document.head.appendChild(s);
            var v = document.querySelector('video');
            if (v) {
                v.autoplay = true;
                v.volume = \(parent.volume);
                v.play();
            }
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

struct CustomPlayerView: View {
    @ObservedObject var playerManager: VideoPlayerManager
    
    var body: some View {
        if !playerManager.currentBvid.isEmpty && playerManager.currentCid > 0 {
            BiliPlayerWebView(
                bvid: playerManager.currentBvid,
                cid: playerManager.currentCid,
                volume: $playerManager.volume
            )
            .background(Color.black)
        } else {
            ZStack {
                Color.black
                ProgressView()
                    .controlSize(.large)
            }
        }
    }
}
