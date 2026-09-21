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
            let length = dataRequest.requestedLength
            if length > 0 && length < 50_000_000 {
                let endOffset = offset + Int64(length) - 1
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

// MARK: - 播放控制器单流核心管理器 (删除双播放器，改用 Composition 单流)
final class VideoPlayerManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentQualityName: String = "1080P60"
    @Published var availableQualities: [(id: Int, name: String)] = []
    @Published var selectedQualityId: Int = 116
    
    let videoPlayer = AVPlayer()
    private var currentBvid: String = ""
    private var currentCid: Int = 0
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        let savedVol = UserDefaults.standard.float(forKey: "bili_saved_volume")
        let initVol = savedVol == 0 ? 0.8 : savedVol
        self.videoPlayer.volume = initVol
        
        // 自动记忆原生悬浮面板上的音量滑块调节
        videoPlayer.publisher(for: \.volume)
            .sink { vol in
                UserDefaults.standard.set(vol, forKey: "bili_saved_volume")
            }
            .store(in: &cancellables)
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
                
                // 🌟 1. 严格屏蔽无法硬解的 AV1
                let hardwareStreams = dash.video.filter { stream in
                    let codec = (stream.codecs ?? "").lowercased()
                    return !codec.contains("av01") && !codec.contains("av1")
                }
                
                // 🌟 2. 核心优化：绝对优先锁定 HEVC (H.265)！
                // 体积比 H.264 减半，Intel i5 核显满血硬解，网速要求降低 50%，首帧秒开不转圈！
                let vStream = hardwareStreams.first(where: { $0.id == activeQn && ($0.codecs ?? "").lowercased().contains("hev") })
                    ?? hardwareStreams.first(where: { $0.id == activeQn && ($0.codecs ?? "").lowercased().contains("avc") })
                    ?? hardwareStreams.first(where: { $0.id == activeQn })
                    ?? hardwareStreams.first(where: { ($0.codecs ?? "").lowercased().contains("hev") })
                    ?? hardwareStreams.first(where: { ($0.codecs ?? "").lowercased().contains("avc") })
                    ?? dash.video.first!
                
                // 🌟 3. 官方稳定 CDN 优选
                var streamUrlStr = vStream.baseUrl
                if let backups = vStream.backupUrl, !backups.isEmpty {
                    if let reliable = backups.first(where: { $0.contains("mirrorcos") || $0.contains("mirrorali") }) {
                        streamUrlStr = reliable
                    }
                }
                
                guard let finalVUrl = URL(string: streamUrlStr) else { return }
                let vAsset = BiliStreamLoader.shared.createAsset(from: finalVUrl, isAudio: false)
                
                // 音频轨处理
                var aAsset: AVURLAsset? = nil
                if let aStream = dash.audio?.first {
                    var aUrlStr = aStream.baseUrl
                    if let aBackups = aStream.backupUrl, !aBackups.isEmpty {
                        if let aReliable = aBackups.first(where: { $0.contains("mirrorcos") || $0.contains("mirrorali") }) {
                            aUrlStr = aReliable
                        }
                    }
                    if let aUrl = URL(string: aUrlStr) {
                        aAsset = BiliStreamLoader.shared.createAsset(from: aUrl, isAudio: true)
                    }
                }
                
                // 🌟 4. 采用 AVMutableComposition 原生合成单流 (消灭双播放器，彻底解决音画不同步与重叠)
                let composition = AVMutableComposition()
                let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                
                let vTracks = try await vAsset.loadTracks(withMediaType: .video)
                if let vTrack = vTracks.first {
                    let vRange = try await vTrack.load(.timeRange)
                    try compVideoTrack?.insertTimeRange(vRange, of: vTrack, at: .zero)
                    
                    if let aAsset = aAsset {
                        let aTracks = try await aAsset.loadTracks(withMediaType: .audio)
                        if let aTrack = aTracks.first {
                            let aRange = try await aTrack.load(.timeRange)
                            try compAudioTrack?.insertTimeRange(aRange, of: aTrack, at: .zero)
                        }
                    }
                }
                
                let playerItem = AVPlayerItem(asset: composition)
                self.videoPlayer.replaceCurrentItem(with: playerItem)
                
                let savedVol = UserDefaults.standard.float(forKey: "bili_saved_volume")
                self.videoPlayer.volume = savedVol == 0 ? 0.8 : savedVol
                
                if resumeTime > 0 {
                    let targetCM = CMTime(seconds: resumeTime, preferredTimescale: 600)
                    await self.videoPlayer.seek(to: targetCM, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                
                // 唯一的硬件主从时钟，音画百分之百同频起步！
                self.videoPlayer.play()
                self.isPlaying = true
            } catch {
                print("单流合成加载失败，降级播放: \(error)")
            }
        }
    }
    
    func cleanup() {
        videoPlayer.pause()
        videoPlayer.replaceCurrentItem(with: nil)
        BiliStreamLoader.shared.cancelAll()
        isPlaying = false
    }
    
    deinit {
        cleanup()
    }
}
