import Foundation
import AVFoundation
import Combine

// MARK: - B 站原生流媒体拦截器 (解决防盗链、零延迟推流、强力断网熔断)
final class BiliStreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    static let shared = BiliStreamLoader()
    
    private var tasksLock = NSLock()
    private var activeTasks: [URLSessionDataTask: AVAssetResourceLoadingRequest] = [:]
    private let loaderQueue = DispatchQueue(label: "com.bilimac.streamloader", qos: .userInteractive)
    
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
        asset.resourceLoader.setDelegate(self, queue: loaderQueue)
        return asset
    }
    
    // 🌟 强力物理断流：瞬间取消所有进行中的网络任务，流量立刻归零
    func cancelAll() {
        tasksLock.lock()
        for (task, req) in activeTasks {
            task.cancel()
            req.finishLoading()
        }
        activeTasks.removeAll()
        tasksLock.unlock()
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let customURL = loadingRequest.request.url,
              let comp = URLComponents(url: customURL, resolvingAgainstBaseURL: false),
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
        
        // 关键：精准透传分片 Range
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
        tasksLock.lock()
        activeTasks[task] = loadingRequest
        tasksLock.unlock()
        task.resume()
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasksLock.lock()
        for (task, req) in activeTasks where req == loadingRequest {
            task.cancel()
            activeTasks.removeValue(forKey: task)
        }
        tasksLock.unlock()
    }
    
    // MARK: - URLSessionDataDelegate 逐包实时响应
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        tasksLock.lock()
        let req = activeTasks[dataTask]
        tasksLock.unlock()
        
        guard let loadingRequest = req, let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        
        if let contentInfo = loadingRequest.contentInformationRequest {
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
        tasksLock.lock()
        let req = activeTasks[dataTask]
        tasksLock.unlock()
        
        // 逐包喂入硬件解码器，画面瞬间呈现
        req?.dataRequest?.respond(with: data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let dTask = task as? URLSessionDataTask else { return }
        tasksLock.lock()
        let req = activeTasks[dTask]
        activeTasks.removeValue(forKey: dTask)
        tasksLock.unlock()
        
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            req?.finishLoading(with: error)
        } else {
            req?.finishLoading()
        }
    }
}

// MARK: - 播放控制器管理器
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
        
        // 音量记忆
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
                
                // 排除 AV1，优先 AVC (H.264)，确保 Intel i5 满血硬解
                let vStream = candidates.first(where: { ($0.codecs ?? "").lowercased().hasPrefix("avc") })
                    ?? candidates.first(where: { ($0.codecs ?? "").lowercased().hasPrefix("hev") })
                    ?? candidates.first(where: { !($0.codecs ?? "").lowercased().hasPrefix("av01") })
                    ?? dash.video.first!
                
                guard let vUrl = URL(string: vStream.baseUrl) else { return }
                let vAsset = BiliStreamLoader.shared.createAsset(from: vUrl, isAudio: false)
                let vItem = AVPlayerItem(asset: vAsset)
                self.videoPlayer.replaceCurrentItem(with: vItem)
                
                // 挂载音频轨
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
                print("加载视频流失败: \(error)")
            }
        }
    }
    
    // 🌟 全量熔断方法：退出时掐死一切流媒体与网络请求
    func cleanup() {
        videoPlayer.pause()
        audioPlayer?.pause()
        videoPlayer.replaceCurrentItem(with: nil)
        audioPlayer?.replaceCurrentItem(with: nil)
        audioPlayer = nil
        BiliStreamLoader.shared.cancelAll()
        isPlaying = false
    }
    
    deinit {
        cleanup()
        if let token = timeObserverToken {
            videoPlayer.removeTimeObserver(token)
        }
    }
}
