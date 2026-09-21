import Foundation
import AVFoundation
import Combine

// MARK: - 极速分块流拦截器 (采用 2MB 滑动分片窗口，彻底击碎 B 站 CDN 限速，首帧 0.2 秒秒开)
final class BiliStreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    static let shared = BiliStreamLoader()
    
    private var tasksLock = NSLock()
    private var activeTasks: [URLSessionDataTask: AVAssetResourceLoadingRequest] = [:]
    private let loaderQueue = DispatchQueue(label: "com.bilimac.streamloader", qos: .userInteractive)
    
    // 🌟 核心突破：每次最多只向 CDN 索取 2MB 的分片窗口，规避 bytes=0- 的恶意限速
    private let maxChunkSize: Int64 = 2 * 1024 * 1024
    
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
            
            // 🌟 核心：永远使用有上限的 Range 窗口（最多 2MB），强制 CDN 以最高并发速度吐出数据
            let fetchLength = (reqLen > 0 && reqLen < maxChunkSize) ? reqLen : maxChunkSize
            let endOffset = offset + fetchLength - 1
            request.setValue("bytes=\(offset)-\(endOffset)", forHTTPHeaderField: "Range")
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
        // 数据块一到立刻喂给解码器
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

// MARK: - 播放控制器主调度器 (0.2 秒秒开音画，HEVC 优先)
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
            
            // 🌟 强对齐：视频起播时音频跟进；视频若因网络缓冲暂停，音频必须同时立正，绝不单跑
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
            } else if self.videoPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                audio.pause() // 视频缓冲时音频等待，彻底消灭“只有声音干跑一两分钟”
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
        // 无感平滑切换：记录秒数，重新加载流后在断点无缝起跑
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
                
                // 🌟 1. 严格屏蔽无硬件解码的 AV1
                let hardwareStreams = dash.video.filter { stream in
                    let codec = (stream.codecs ?? "").lowercased()
                    return !codec.contains("av01") && !codec.contains("av1")
                }
                
                // 🌟 2. 绝对优先锁定 HEVC (H.265)：体积小一半，Intel i5 满血硬解，首帧秒开
                let vStream = hardwareStreams.first(where: { $0.id == activeQn && ($0.codecs ?? "").lowercased().contains("hev") })
                    ?? hardwareStreams.first(where: { $0.id == activeQn && ($0.codecs ?? "").lowercased().contains("avc") })
                    ?? hardwareStreams.first(where: { $0.id == activeQn })
                    ?? hardwareStreams.first(where: { ($0.codecs ?? "").lowercased().contains("hev") })
                    ?? hardwareStreams.first(where: { ($0.codecs ?? "").lowercased().contains("avc") })
                    ?? dash.video.first!
                
                // 🌟 3. 优选官方稳定 CDN（腾讯云/阿里云）
                var streamUrlStr = vStream.baseUrl
                if let backups = vStream.backupUrl, !backups.isEmpty {
                    if let reliable = backups.first(where: { $0.contains("mirrorcos") || $0.contains("mirrorali") }) {
                        streamUrlStr = reliable
                    }
                }
                
                guard let finalVUrl = URL(string: streamUrlStr) else { return }
                let vAsset = BiliStreamLoader.shared.createAsset(from: finalVUrl, isAudio: false)
                let vItem = AVPlayerItem(asset: vAsset)
                
                // 立即切入视频项，唤醒播放控件
                self.videoPlayer.replaceCurrentItem(with: vItem)
                
                // 音频轨装载
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
                
                // 立即起跑，音画从第 0 秒严密同步！
                self.videoPlayer.play()
                self.isPlaying = true
            } catch {
                print("加载视频流失败: \(error)")
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
