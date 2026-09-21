import Foundation
import AVFoundation
import Combine

// MARK: - 真实流式数据拦截器 (逐包实时喂给硬件解码器，毫秒级起播，支持退出物理熔断)
final class BiliStreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    static let shared = BiliStreamLoader()
    
    private var activeTasks = [URLSessionDataTask: AVAssetResourceLoadingRequest]()
    private let queue = DispatchQueue(label: "com.bilimac.streamloader", qos: .userInteractive)
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    func createAsset(from url: URL, isAudio: Bool = false) -> AVURLAsset {
        var comp = URLComponents()
        comp.scheme = "bilistream"
        comp.host = isAudio ? "audio.mp4" : "video.mp4"
        comp.queryItems = [URLQueryItem(name: "real_url", value: url.absoluteString)]
        
        guard let customURL = comp.url else { return AVURLAsset(url: url) }
        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }
    
    // 🌟 物理断网熔断：退出时立即掐死所有网络请求，流量瞬间归零
    func cancelAll() {
        queue.async {
            for (task, req) in self.activeTasks {
                task.cancel()
                req.finishLoading()
            }
            self.activeTasks.removeAll()
        }
    }
    
    // MARK: - 拦截 Range 分片请求
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let customURL = loadingRequest.request.url,
              let comp = URLComponents(url: customURL, resolvingAgainstBaseURL: false),
              let realUrlStr = comp.queryItems?.first(where: { $0.name == "real_url" })?.value,
              let realURL = URL(string: realUrlStr) else {
            return false
        }
        
        var request = URLRequest(url: realURL)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        let cookie = CookieManager.shared.cookieHeader
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        
        // 严格按原生播放器需要的片段大小拉取，绝不全量提前下载
        if let dataRequest = loadingRequest.dataRequest {
            let offset = dataRequest.requestedOffset
            let length = dataRequest.requestedLength
            if length > 0 {
                request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
            } else {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }
        }
        
        let task = session.dataTask(with: request)
        activeTasks[task] = loadingRequest
        task.resume()
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (task, req) in activeTasks where req == loadingRequest {
            task.cancel()
            activeTasks.removeValue(forKey: task)
        }
    }
    
    // MARK: - 🌟 逐包实时推送：首个 16KB 数据一收到，立刻喂给播放器解码！
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let req = activeTasks[dataTask], let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        
        if let contentInfo = req.contentInformationRequest {
            contentInfo.contentType = "public.mpeg-4"
            contentInfo.isByteRangeAccessSupported = true
            if let rangeHeader = httpResponse.allHeaderFields["Content-Range"] as? String ?? httpResponse.allHeaderFields["content-range"] as? String,
               let totalStr = rangeHeader.split(separator: "/").last,
               let total = Int64(totalStr.trimmingCharacters(in: .whitespaces)) {
                contentInfo.contentLength = total
            } else if httpResponse.expectedContentLength > 0 {
                contentInfo.contentLength = httpResponse.expectedContentLength
            }
        }
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let req = activeTasks[dataTask] else { return }
        req.dataRequest?.respond(with: data) // 收到即推，秒开画面
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let dataTask = task as? URLSessionDataTask, let req = activeTasks[dataTask] else { return }
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            req.finishLoading(with: error)
        } else {
            req.finishLoading()
        }
        activeTasks.removeValue(forKey: dataTask)
    }
}

// MARK: - 播放管理器
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
        
        // 自动记忆音量
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
                
                guard let dash = playInfo.dash else { return }
                
                let candidates = dash.video.filter { $0.id == activeQn }
                
                // 排除 AV1，锁定 Intel i5 核显硬解的 AVC/H.264
                let vStream = candidates.first(where: { ($0.codecs ?? "").lowercased().hasPrefix("avc") })
                    ?? candidates.first(where: { ($0.codecs ?? "").lowercased().hasPrefix("hev") })
                    ?? candidates.first(where: { !($0.codecs ?? "").lowercased().hasPrefix("av01") })
                    ?? dash.video.first!
                
                guard let vUrl = URL(string: vStream.baseUrl) else { return }
                let vAsset = BiliStreamLoader.shared.createAsset(from: vUrl, isAudio: false)
                let vItem = AVPlayerItem(asset: vAsset)
                self.videoPlayer.replaceCurrentItem(with: vItem)
                
                // 音频轨
                if let aStream = dash.audio?.first, let aUrl = URL(string: aStream.baseUrl) {
                    let aAsset = BiliStreamLoader.shared.createAsset(from: aUrl, isAudio: true)
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
                print("加载流媒体失败: \(error)")
            }
        }
    }
    
    // 🌟 全量熔断方法：停止播放、清空内存、断开一切 TCP 网络连接
    func cleanup() {
        videoPlayer.pause()
        audioPlayer?.pause()
        videoPlayer.replaceCurrentItem(with: nil)
        audioPlayer?.replaceCurrentItem(with: nil)
        audioPlayer = nil
        BiliStreamLoader.shared.cancelAll() // 掐断后台流
        isPlaying = false
    }
    
    deinit {
        cleanup()
        if let token = timeObserverToken {
            videoPlayer.removeTimeObserver(token)
        }
    }
}
