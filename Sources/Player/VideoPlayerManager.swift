import Foundation
import AVFoundation
import Combine

final class VideoPlayerManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentQualityName: String = "1080P"
    @Published var availableQualities: [(id: Int, name: String)] = []
    @Published var selectedQualityId: Int = 116 // 优先 1080P60
    
    let videoPlayer = AVPlayer()
    private var audioPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var currentBvid: String = ""
    private var currentCid: Int = 0
    
    init() {
        // 读取记忆的音量大小
        let savedVol = UserDefaults.standard.float(forKey: "bili_saved_volume")
        let initVol = savedVol == 0 ? 0.8 : savedVol
        self.videoPlayer.volume = initVol
        
        setupVolumeAndSyncObserver()
    }
    
    private func setupVolumeAndSyncObserver() {
        // 监听并记住原生播放器上用户调节的音量
        videoPlayer.publisher(for: \.volume)
            .sink { [weak self] vol in
                guard let self = self else { return }
                UserDefaults.standard.set(vol, forKey: "bili_saved_volume")
                self.audioPlayer?.volume = vol
            }
            .store(in: &cancellables)
        
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = videoPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            
            // DASH 双轨时间精准同步
            if let audio = self.audioPlayer {
                let diff = abs(time.seconds - audio.currentTime().seconds)
                if diff > 0.15 {
                    audio.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if self.videoPlayer.rate != audio.rate {
                    audio.rate = self.videoPlayer.rate
                }
            }
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
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
                
                // 解析可用清晰度列表
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
                
                // 🌟 核心：注入哔哩哔哩要求的标准 Referer 与防盗链头，解决 403 划斜杠拒绝访问
                let headers: [String: String] = [
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
                    "Referer": "https://www.bilibili.com"
                ]
                
                let savedVol = UserDefaults.standard.float(forKey: "bili_saved_volume")
                let actualVol = savedVol == 0 ? 0.8 : savedVol
                
                if let dash = playInfo.dash {
                    let candidates = dash.video.filter { $0.id == activeQn }
                    
                    // Intel 核显硬解优先级策略（优先 AVC/H264）
                    let vStream = candidates.first(where: { ($0.codecs ?? "").contains("avc") })
                        ?? candidates.first(where: { ($0.codecs ?? "").contains("hev") })
                        ?? candidates.first
                        ?? dash.video.first!
                    
                    guard let vUrl = URL(string: vStream.baseUrl) else { return }
                    let vAsset = AVURLAsset(url: vUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let vItem = AVPlayerItem(asset: vAsset)
                    
                    self.videoPlayer.replaceCurrentItem(with: vItem)
                    self.videoPlayer.volume = actualVol
                    
                    // 挂载音频轨
                    if let aStream = dash.audio?.first, let aUrl = URL(string: aStream.baseUrl) {
                        let aAsset = AVURLAsset(url: aUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                        let aItem = AVPlayerItem(asset: aAsset)
                        self.audioPlayer = AVPlayer(playerItem: aItem)
                        self.audioPlayer?.volume = actualVol
                    }
                } else if let durl = playInfo.durl?.first, let vUrl = URL(string: durl.url) {
                    let asset = AVURLAsset(url: vUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let item = AVPlayerItem(asset: asset)
                    self.videoPlayer.replaceCurrentItem(with: item)
                    self.videoPlayer.volume = actualVol
                    self.audioPlayer = nil
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
