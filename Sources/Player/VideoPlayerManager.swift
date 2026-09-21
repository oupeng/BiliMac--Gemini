import Foundation
import AVFoundation
import Combine

// MARK: - BiliKit 原生流代理拦截器 (零延迟透传，防盗链穿透，全速无截断)
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
    
    func createAsset(from url: URL) -> AVURLAsset {
        var comp = URLComponents()
        comp.scheme = "bilistream"
        comp.host = "video.mp4"
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
        
        // 精准分片透传，严禁人为截断
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

// MARK: - 原生播放主调度器 (真正的单播放器原生体系)
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
        
        // 自动将用户在图 3 原生左上角音量滑块调节的数值永久记住
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
                
                // 优先挑选高质量单流或者 DASH 高能流
                var targetStreamURL: URL? = nil
                
                if let durls = playInfo.durl, let firstDurl = durls.first, let url = URL(string: firstDurl.url) {
                    // 🌟 核心通道 A：B 站官方高码率音画合一原生流（直接带出左上角音量滑块）
                    targetStreamURL = url
                    self.selectedQualityId = playInfo.quality
                    self.currentQualityName = list.first(where: { $0.0 == playInfo.quality })?.1 ?? "\(playInfo.quality)P"
                } else if let dash = playInfo.dash {
                    // 🌟 核心通道 B：DASH 高画质通道（HEVC 满血优先）
                    let targetQn = dash.video.contains(where: { $0.id == targetQuality }) ? targetQuality : (list.first?.0 ?? playInfo.quality)
                    self.selectedQualityId = targetQn
                    self.currentQualityName = list.first(where: { $0.0 == targetQn })?.1 ?? "\(targetQn)P"
                    
                    let hardwareStreams = dash.video.filter { stream in
                        let c = (stream.codecs ?? "").lowercased()
                        return !c.contains("av01") && !c.contains("av1")
                    }
                    
                    let vStream = hardwareStreams.first(where: { $0.id == targetQn && ($0.codecs ?? "").lowercased().contains("hev") })
                        ?? hardwareStreams.first(where: { $0.id == targetQn && ($0.codecs ?? "").lowercased().contains("avc") })
                        ?? hardwareStreams.first(where: { $0.id == targetQn })
                        ?? hardwareStreams.first
                        ?? dash.video.first!
                    
                    var streamUrlStr = vStream.baseUrl
                    if let backups = vStream.backupUrl, !backups.isEmpty {
                        if let reliable = backups.first(where: { $0.contains("mirrorcos") || $0.contains("mirrorali") }) {
                            streamUrlStr = reliable
                        }
                    }
                    targetStreamURL = URL(string: streamUrlStr)
                }
                
                guard let finalUrl = targetStreamURL else { return }
                
                let asset = BiliStreamLoader.shared.createAsset(from: finalUrl)
                let item = AVPlayerItem(asset: asset)
                
                self.videoPlayer.replaceCurrentItem(with: item)
                
                let savedVol = UserDefaults.standard.float(forKey: "bili_saved_volume")
                self.videoPlayer.volume = savedVol == 0 ? 0.8 : savedVol
                
                if resumeTime > 0 {
                    let targetCM = CMTime(seconds: resumeTime, preferredTimescale: 600)
                    await self.videoPlayer.seek(to: targetCM, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                
                self.videoPlayer.play()
                self.isPlaying = true
            } catch {
                print("加载流媒体失败: \(error)")
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
