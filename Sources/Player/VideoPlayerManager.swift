import Foundation
import AVFoundation
import Combine

// MARK: - 原生防盗链与数据流注入拦截器 (彻底解决 403 与 m4s 播放失败)
final class BiliResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let shared = BiliResourceLoader()
    private var tasks: [AVAssetResourceLoadingRequest: URLSessionDataTask] = [:]
    private let loaderQueue = DispatchQueue(label: "com.bilimac.resourceloader")
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    
    func createAsset(from originalURL: URL) -> AVURLAsset {
        var comp = URLComponents()
        comp.scheme = "bilistream"
        comp.host = "video.mp4"
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

// MARK: - 播放控制管理器
final class VideoPlayerManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentQualityName: String = "1080P"
    @Published var availableQualities: [(id: Int, name: String)] = []
    @Published var selectedQualityId: Int = 80
    
    let videoPlayer = AVPlayer()
    private var currentBvid: String = ""
    private var currentCid: Int = 0
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        let savedVol = UserDefaults.standard.float(forKey: "bili_saved_volume")
        let initVol = savedVol == 0 ? 0.8 : savedVol
        self.videoPlayer.volume = initVol
        
        // 自动记忆并持久化调节的音量
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
                
                // 挑选流媒体地址（优先标准 MP4 单流，其次 DASH 流）
                var streamUrlString: String? = nil
                if let durl = playInfo.durl?.first {
                    streamUrlString = durl.url
                } else if let dash = playInfo.dash {
                    let candidates = dash.video.filter { $0.id == activeQn }
                    let vStream = candidates.first(where: { ($0.codecs ?? "").contains("avc") })
                        ?? candidates.first(where: { ($0.codecs ?? "").contains("hev") })
                        ?? candidates.first
                        ?? dash.video.first!
                    streamUrlString = vStream.baseUrl
                }
                
                guard let finalStr = streamUrlString, let targetUrl = URL(string: finalStr) else { return }
                
                // 🌟 通过原生资源拦截器构建资产，彻底消除防盗链拦截
                let asset = BiliResourceLoader.shared.createAsset(from: targetUrl)
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
                print("加载视频流失败: \(error)")
            }
        }
    }
}
