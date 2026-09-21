import Foundation
import AVFoundation
import Combine

// MARK: - 原生流拦截器
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
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        let cookie = CookieManager.shared.cookieHeader
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        
        if let dataRequest = loadingRequest.dataRequest {
            let offset = dataRequest.requestedOffset
            let reqLen = Int64(dataRequest.requestedLength)
            
            if reqLen > 0 && !dataRequest.requestsAllDataToEndOfResource {
                let endOffset = offset + reqLen - 1
                request.setValue("bytes=\(offset)-\(endOffset)", forHTTPHeaderField: "Range")
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
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        tasksLock.lock()
        let req = activeTasks[dataTask]
        tasksLock.unlock()
        
        guard let loadingRequest = req, let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        
        if httpResponse.statusCode >= 400 {
            completionHandler(.cancel)
            loadingRequest.finishLoading(with: NSError(domain: "HTTP", code: httpResponse.statusCode))
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

// MARK: - 播放控制器主调度器 (真 4K HEVC 锁定与真实分辨率监测)
final class VideoPlayerManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentQualityName: String = "4K"
    @Published var currentResolutionBadge: String = "" // 🌟 实时展示物理分辨率 (如 HEVC 3840x2160)
    @Published var availableQualities: [(id: Int, name: String)] = []
    @Published var selectedQualityId: Int = 120 // 默认优先请求最高 4K
    @Published var volume: Float = 0.8 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "bili_saved_volume")
            audioPlayer?.volume = volume
        }
    }
    
    let videoPlayer = AVPlayer()
    private var audioPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var currentBvid: String = ""
    private var currentCid: Int = 0
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        let savedVol = UserDefaults.standard.float(forKey: "bili_saved_volume")
        self.volume = savedVol == 0 ? 0.8 : savedVol
        setupSyncObserver()
    }
    
    private func setupSyncObserver() {
        let interval = CMTime(seconds: 0.3, preferredTimescale: 600)
        timeObserverToken = videoPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, let audio = self.audioPlayer else { return }
            
            if self.videoPlayer.timeControlStatus == .playing {
                if audio.timeControlStatus != .playing {
                    audio.play()
                }
                let diff = abs(time.seconds - audio.currentTime().seconds)
                if diff > 0.25 {
                    audio.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if self.videoPlayer.rate != audio.rate {
                    audio.rate = self.videoPlayer.rate
                }
            } else if self.videoPlayer.timeControlStatus == .paused {
                audio.pause()
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
                
                guard let dash = playInfo.dash else { return }
                
                // 🌟 1. 严格检查 targetQuality 是否存在
                let targetQn: Int
                if dash.video.contains(where: { $0.id == targetQuality }) {
                    targetQn = targetQuality
                } else {
                    targetQn = list.first?.0 ?? playInfo.quality
                }
                
                // 🌟 2. 锁定 Intel i5 核显完全硬解流 (HEVC / AVC)
                let hardwareStreams = dash.video.filter { stream in
                    let codec = (stream.codecs ?? "").lowercased()
                    return !codec.contains("av01") && !codec.contains("av1")
                }
                
                // 🌟 3. 精准匹配 targetQn 的 HEVC 4K 流！
                let vStream = hardwareStreams.first(where: { $0.id == targetQn && ($0.codecs ?? "").lowercased().contains("hev") })
                    ?? hardwareStreams.first(where: { $0.id == targetQn && ($0.codecs ?? "").lowercased().contains("avc") })
                    ?? hardwareStreams.first(where: { $0.id == targetQn })
                    ?? hardwareStreams.first(where: { ($0.codecs ?? "").lowercased().contains("hev") })
                    ?? hardwareStreams.first(where: { ($0.codecs ?? "").lowercased().contains("avc") })
                    ?? dash.video.first!
                
                // 真实画质标签绑定（绝不虚报，所播即所显）
                let realQn = vStream.id
                self.selectedQualityId = realQn
                let qName = list.first(where: { $0.0 == realQn })?.1 ?? "\(realQn)P"
                let codecTag = (vStream.codecs ?? "").lowercased().contains("hev") ? "HEVC" : "AVC"
                let dimension = (vStream.width != nil && vStream.height != nil) ? "\(vStream.width!)x\(vStream.height!)" : ""
                
                self.currentQualityName = qName
                self.currentResolutionBadge = "\(codecTag) \(dimension)"
                
                // 优选官方稳定 CDN 节点
                var streamUrlStr = vStream.baseUrl
                if let backups = vStream.backupUrl, !backups.isEmpty {
                    if let reliable = backups.first(where: { $0.contains("mirrorcos") || $0.contains("mirrorali") }) {
                        streamUrlStr = reliable
                    }
                }
                
                guard let finalVUrl = URL(string: streamUrlStr) else { return }
                let vAsset = BiliStreamLoader.shared.createAsset(from: finalVUrl, isAudio: false)
                let vItem = AVPlayerItem(asset: vAsset)
                
                self.videoPlayer.replaceCurrentItem(with: vItem)
                
                // 装载音频
                if let aStream = dash.audio?.first {
                    var aUrlStr = aStream.baseUrl
                    if let aBackups = aStream.backupUrl, !aBackups.isEmpty {
                        if let reliable = aBackups.first(where: { $0.contains("mirrorcos") || $0.contains("mirrorali") }) {
                            aUrlStr = reliable
                        }
                    }
                    if let aUrl = URL(string: aUrlStr) {
                        let aAsset = BiliStreamLoader.shared.createAsset(from: aUrl, isAudio: true)
                        let aItem = AVPlayerItem(asset: aAsset)
                        let aPlayer = AVPlayer(playerItem: aItem)
                        aPlayer.volume = self.volume
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
