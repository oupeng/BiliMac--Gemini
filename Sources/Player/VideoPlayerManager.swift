import Foundation
import AVFoundation
import Combine
import Network

// MARK: - 极速本地流式代理 (解决 .m4s 识别失败与 403 防盗链)
final class BiliLocalProxy {
    static let shared = BiliLocalProxy()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var urlMapping: [String: URL] = [:]
    private let queue = DispatchQueue(label: "com.bilimac.proxy", qos: .userInteractive)
    
    private init() {
        start()
    }
    
    private func start() {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: .any)
            listener?.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = self?.listener?.port?.rawValue {
                    self?.port = port
                }
            }
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener?.start(queue: queue)
        } catch {
            print("代理启动失败: \(error)")
        }
    }
    
    func proxyURL(for original: URL, isAudio: Bool = false) -> URL {
        let key = UUID().uuidString
        queue.sync { urlMapping[key] = original }
        // 🌟 核心：强制伪装为 .mp4 格式，唤醒 macOS 原生硬件解码器
        let ext = isAudio ? "audio.mp4" : "video.mp4"
        return URL(string: "http://127.0.0.1:\(port)/\(key)/\(ext)")!
    }
    
    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let reqStr = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            
            let lines = reqStr.components(separatedBy: "\r\n")
            guard let firstLine = lines.first, firstLine.hasPrefix("GET ") else {
                conn.cancel()
                return
            }
            
            let path = firstLine.split(separator: " ")[1]
            let parts = path.split(separator: "/")
            guard let key = parts.first else {
                conn.cancel()
                return
            }
            
            guard let targetURL = self.urlMapping[String(key)] else {
                conn.cancel()
                return
            }
            
            var remoteReq = URLRequest(url: targetURL)
            remoteReq.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
            remoteReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            
            let cookie = CookieManager.shared.cookieHeader
            if !cookie.isEmpty {
                remoteReq.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            
            // 透传 Range 请求头（确保拖拽进度条能正常工作）
            for line in lines {
                if line.lowercased().hasPrefix("range:") {
                    let val = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    remoteReq.setValue(val, forHTTPHeaderField: "Range")
                }
            }
            
            let task = URLSession.shared.dataTask(with: remoteReq) { rData, rResp, _ in
                guard let httpResp = rResp as? HTTPURLResponse else {
                    conn.cancel()
                    return
                }
                
                var headerStr = "HTTP/1.1 \(httpResp.statusCode) OK\r\n"
                for (k, v) in httpResp.allHeaderFields {
                    let kStr = "\(k)"
                    if kStr.lowercased() != "connection" && kStr.lowercased() != "transfer-encoding" {
                        headerStr += "\(k): \(v)\r\n"
                    }
                }
                headerStr += "Content-Type: video/mp4\r\n"
                headerStr += "Connection: close\r\n\r\n"
                
                var responseData = headerStr.data(using: .utf8) ?? Data()
                if let rData = rData {
                    responseData.append(rData)
                }
                
                conn.send(content: responseData, completion: .contentProcessed({ _ in
                    conn.cancel()
                }))
            }
            task.resume()
        }
    }
}

// MARK: - 播放控制器核心管理器
final class VideoPlayerManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentQualityName: String = "1080P60"
    @Published var availableQualities: [(id: Int, name: String)] = []
    @Published var selectedQualityId: Int = 116
    
    let videoPlayer = AVPlayer()
    private var audioPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var currentBvid: String = ""
    private var currentCid: Int = 0
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        let savedVol = UserDefaults.standard.float(forKey: "bili_saved_volume")
        let initVol = savedVol == 0 ? 0.8 : savedVol
        self.videoPlayer.volume = initVol
        
        videoPlayer.publisher(for: \.volume)
            .sink { [weak self] vol in
                UserDefaults.standard.set(vol, forKey: "bili_saved_volume")
                self?.audioPlayer?.volume = vol
            }
            .store(in: &cancellables)
            
        setupSyncObserver()
    }
    
    private func setupSyncObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = videoPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, let audio = self.audioPlayer else { return }
            let vSec = time.seconds
            let aSec = audio.currentTime().seconds
            if abs(vSec - aSec) > 0.15 {
                audio.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if self.videoPlayer.rate != audio.rate {
                audio.rate = self.videoPlayer.rate
            }
        }
    }
    
    func playVideo(bvid: String, cid: Int) {
        self.currentBvid = bvid
        self.currentCid = cid
        loadStream(targetQuality: selectedQualityId)
    }
    
    func changeQuality(to qn: Int) {
        guard qn != selectedQualityId else { return }
        self.selectedQualityId = qn
        let currentTime = videoPlayer.currentTime().seconds
        loadStream(targetQuality: qn, resumeTime: currentTime)
    }
    
    private func loadStream(targetQuality: Int, resumeTime: Double = 0) {
        Task { @MainActor in
            do {
                let playInfo = try await BiliService.shared.fetchPlayUrl(bvid: currentBvid, cid: currentCid, qn: targetQuality)
                
                var list: [(Int, String)] = []
                for i in 0..<playInfo.accept_quality.count {
                    let qId = playInfo.accept_quality[i]
                    let desc = i < playInfo.accept_description.count ? playInfo.accept_description[i] : "\(qId)P"
                    list.append((qId, desc))
                }
                self.availableQualities = list
                
                let activeQn = playInfo.quality
                self.selectedQualityId = activeQn
                self.currentQualityName = list.first(where: { $0.0 == activeQn })?.1 ?? "\(activeQn)P"
                
                if let durl = playInfo.durl?.first, let streamUrl = URL(string: durl.url) {
                    let proxied = BiliLocalProxy.shared.proxyURL(for: streamUrl)
                    let item = AVPlayerItem(url: proxied)
                    self.videoPlayer.replaceCurrentItem(with: item)
                    self.audioPlayer = nil
                } else if let dash = playInfo.dash {
                    let candidates = dash.video.filter { $0.id == activeQn }
                    
                    // Intel 核显硬解锁定 AVC/H.264
                    let vStream = candidates.first(where: { ($0.codecs ?? "").lowercased().contains("avc") })
                        ?? candidates.first(where: { ($0.codecs ?? "").lowercased().contains("hev") })
                        ?? candidates.first(where: { !($0.codecs ?? "").lowercased().contains("av01") })
                        ?? dash.video.first!
                    
                    guard let vUrl = URL(string: vStream.baseUrl) else { return }
                    
                    // 🌟 本地代理直接喂入标准 .mp4 格式，画面立即呈现
                    let proxiedVUrl = BiliLocalProxy.shared.proxyURL(for: vUrl, isAudio: false)
                    let vItem = AVPlayerItem(url: proxiedVUrl)
                    self.videoPlayer.replaceCurrentItem(with: vItem)
                    
                    // 音频轨
                    if let aStream = dash.audio?.first, let aUrl = URL(string: aStream.baseUrl) {
                        let proxiedAUrl = BiliLocalProxy.shared.proxyURL(for: aUrl, isAudio: true)
                        let aItem = AVPlayerItem(url: proxiedAUrl)
                        let aPlayer = AVPlayer(playerItem: aItem)
                        aPlayer.volume = self.videoPlayer.volume
                        self.audioPlayer = aPlayer
                    }
                }
                
                if resumeTime > 0 {
                    let targetCM = CMTime(seconds: resumeTime, preferredTimescale: 600)
                    await self.videoPlayer.seek(to: targetCM, toleranceBefore: .zero, toleranceAfter: .zero)
                    if let audio = self.audioPlayer {
                        await audio.seek(to: targetCM, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
                
                self.videoPlayer.play()
                self.audioPlayer?.play()
                self.isPlaying = true
            } catch {
                print("加载流媒体失败: \(error)")
            }
        }
    }
    
    func cleanup() {
        videoPlayer.pause()
        audioPlayer?.pause()
        videoPlayer.replaceCurrentItem(with: nil)
        audioPlayer?.replaceCurrentItem(with: nil)
        audioPlayer = nil
        isPlaying = false
    }
    
    deinit {
        cleanup()
        if let token = timeObserverToken {
            videoPlayer.removeTimeObserver(token)
        }
    }
}
