import Foundation
import AVFoundation
import Combine

// MARK: - 原生防盗链与流切片拦截器
final class BiliResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let shared = BiliResourceLoader()
    private var tasks: [AVAssetResourceLoadingRequest: URLSessionDataTask] = [:]
    private let loaderQueue = DispatchQueue(label: "com.bilimac.resourceloader")
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    
    func createAsset(from originalURL: URL, isAudio: Bool = false) -> AVURLAsset {
        var comp = URLComponents()
        comp.scheme = "bilistream"
        comp.host = isAudio ? "audio.mp4" : "video.mp4"
        comp.queryItems = [URLQueryItem(name: "real_url", value: originalURL.absoluteString)]
        
        guard let proxyURL = comp.url else {
            return AVURLAsset(url: originalURL)
        }
        
        let asset = AVURLAsset(url: proxyURL)
        asset.resourceLoader.setDelegate(self, queue: loaderQueue)
        return asset
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url,
              let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let realUrlStr = comp.queryItems?.first(where: { $0.name == "real_url" })?.value,
              let realURL = URL(string: realUrlStr) else {
            return false
        }
        
        var request = URLRequest(url: realURL)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        
        let cookie = CookieManager.shared.cookieHeader
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        
        if let dataRequest = loadingRequest.dataRequest {
            let offset = dataRequest.requestedOffset
            let length = dataRequest.requestedLength
            if length > 0 {
                request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
            } else {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }
        }
        
        let task = session.dataTask(with: request) { [weak self, weak loadingRequest] data, response, error in
            guard let self = self, let loadingRequest = loadingRequest else { return }
            
            self.loaderQueue.async {
                if let error = error {
                    if (error as NSError).code != NSURLErrorCancelled {
                        loadingRequest.finishLoading(with: error)
                    }
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    if let contentInfo = loadingRequest.contentInformationRequest {
                        contentInfo.isByteRangeAccessSupported = true
                        contentInfo.contentType = "public.mpeg-4"
                        
                        if let rangeStr = httpResponse.allHeaderFields["Content-Range"] as? String ?? httpResponse.allHeaderFields["content-range"] as? String,
                           let total = rangeStr.split(separator: "/").last,
                           let totalLength = Int64(total.trimmingCharacters(in: .whitespaces)) {
                            contentInfo.contentLength = totalLength
                        } else if httpResponse.expectedContentLength > 0 {
                            contentInfo.contentLength = httpResponse.expectedContentLength
                        }
                    }
                }
                
                if let data = data, let dataRequest = loadingRequest.dataRequest {
                    dataRequest.respond(with: data)
                }
                
                loadingRequest.finishLoading()
                self.tasks.removeValue(forKey: loadingRequest)
            }
        }
        
        tasks[loadingRequest] = task
        task.resume()
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks[loadingRequest]?.cancel()
        tasks.removeValue(forKey: loadingRequest)
    }
}

// MARK: - 播放控制器核心管理器
final class VideoPlayerManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentQualityName: String = "加载中..."
    @Published var availableQualities: [(id: Int, name: String)] = []
    @Published var selectedQualityId: Int = 116 // 优先尝试最高画质 1080P60
    
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
        
        // 自动记忆音量调节
        videoPlayer.publisher(for: \.volume)
            .sink { [weak self] vol in
                UserDefaults.standard.set(vol, forKey: "bili_saved_volume")
                self?.audioPlayer?.volume = vol
            }
            .store(in: &cancellables)
            
        setupSyncObserver()
    }
    
    private func setupSyncObserver() {
        // 双轨精准对齐时钟
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
                
                guard let dash = playInfo.dash else { return }
                
                let candidates = dash.video.filter { $0.id == activeQn }
                
                // 🌟 彻底排除 AV1！强制锁定 Intel i5 核显完全硬解的 AVC/H.264，极大降低 CPU 负载与发热
                let vStream = candidates.first(where: { ($0.codecs ?? "").lowercased().contains("avc") })
                    ?? candidates.first(where: { ($0.codecs ?? "").lowercased().contains("hev") })
                    ?? candidates.first(where: { !($0.codecs ?? "").lowercased().contains("av01") })
                    ?? dash.video.first!
                
                guard let vUrl = URL(string: vStream.baseUrl) else { return }
                let vAsset = BiliResourceLoader.shared.createAsset(from: vUrl, isAudio: false)
                let vItem = AVPlayerItem(asset: vAsset)
                
                self.videoPlayer.replaceCurrentItem(with: vItem)
                
                // 挂载音频轨（AAC/M4A）
                if let aStream = dash.audio?.first, let aUrl = URL(string: aStream.baseUrl) {
                    let aAsset = BiliResourceLoader.shared.createAsset(from: aUrl, isAudio: true)
                    let aItem = AVPlayerItem(asset: aAsset)
                    let aPlayer = AVPlayer(playerItem: aItem)
                    aPlayer.volume = self.videoPlayer.volume
                    self.audioPlayer = aPlayer
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
                print("加载视频流失败: \(error)")
            }
        }
    }
    
    deinit {
        if let token = timeObserverToken {
            videoPlayer.removeTimeObserver(token)
        }
    }
}
