import Foundation
import AVFoundation
import Combine

// MARK: - 原生流拦截器 (精准分片传输，杜绝提前截断导致视频过早结束)
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
        
        // 🌟 核心修复：精准提供系统播放器所需的分片长度，绝不人为提前截断
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

// MARK: - 播放控制器主调度器 (解锁 4K/1080P60 切换，音画毫秒级同频)
final class VideoPlayerManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentQualityName: String = "1080P60"
    @Published var availableQualities: [(id: Int, name: String)] = []
    @Published var selectedQualityId: Int = 116
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
        // 🌟 真实触发清晰度重载，并在当前秒数无缝起跑
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
                
                // 🌟 核心修复：尊重用户选择的清晰度！
                // 如果用户选择了 4K(120) 或 1080P60(116)，且该视频提供，绝不强退回 1080P 普通
                let actualQn: Int
                if dash.video.contains(where: { $0.id == targetQuality }) {
                    actualQn = targetQuality
                } else {
                    actualQn = list.first?.0 ?? playInfo.quality
                }
                
                self.selectedQualityId = actualQn
                self.currentQualityName = list.first(where: { $0.0 == actualQn })?.1 ?? "\(actualQn)P"
                
                // 排除 AV1，锁定 Intel i5 核显硬解
                let hardwareStreams = dash.video.filter { stream in
                    let codec = (stream.codecs ?? "").lowercased()
                    return !codec.contains("av01") && !codec.contains("av1")
                }
                
                // 🌟 按照 actualQn 精准提取 HEVC 或 AVC
                let vStream = hardwareStreams.first(where: { $0.id == actualQn && ($0.codecs ?? "").lowercased().contains("hev") })
                    ?? hardwareStreams.first(where: { $0.id == actualQn && ($0.codecs ?? "").lowercased().contains("avc") })
                    ?? hardwareStreams.first(where: { $0.id == actualQn })
                    ?? hardwareStreams.first(where: { ($0.codecs ?? "").lowercased().contains("hev") })
                    ?? hardwareStreams.first(where: { ($0.codecs ?? "").lowercased().contains("avc") })
                    ?? dash.video.first!
                
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
                
                // 立即更新视频播放项
                self.videoPlayer.replaceCurrentItem(with: vItem)
                
                // 装载音频轨
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
                
                // 🌟 音画同频同时起跑，彻底消除声音延迟！
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
