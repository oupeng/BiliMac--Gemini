import Foundation
import AVFoundation
import Combine

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
                
                // 优先选取单文件 MP4 或 DASH
                let headers: [String: String] = [
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                    "Referer": "https://www.bilibili.com"
                ]
                
                if let durl = playInfo.durl?.first, let streamUrl = URL(string: durl.url) {
                    // 单流 MP4 原生秒播
                    let asset = AVURLAsset(url: streamUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let item = AVPlayerItem(asset: asset)
                    self.videoPlayer.replaceCurrentItem(with: item)
                    self.audioPlayer?.pause()
                    self.audioPlayer = nil
                } else if let dash = playInfo.dash {
                    let candidates = dash.video.filter { $0.id == activeQn }
                    
                    // Intel i5 专用：严格锁定 AVC/H.264，彻底排除 AV1
                    let vStream = candidates.first(where: { ($0.codecs ?? "").lowercased().contains("avc") })
                        ?? candidates.first(where: { ($0.codecs ?? "").lowercased().contains("hev") })
                        ?? candidates.first(where: { !($0.codecs ?? "").lowercased().contains("av01") })
                        ?? dash.video.first!
                    
                    guard let vUrl = URL(string: vStream.baseUrl) else { return }
                    let vAsset = AVURLAsset(url: vUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let vItem = AVPlayerItem(asset: vAsset)
                    self.videoPlayer.replaceCurrentItem(with: vItem)
                    
                    // 音频轨挂载
                    if let aStream = dash.audio?.first, let aUrl = URL(string: aStream.baseUrl) {
                        let aAsset = AVURLAsset(url: aUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                        let aItem = AVPlayerItem(asset: aAsset)
                        let aPlayer = AVPlayer(playerItem: aItem)
                        aPlayer.volume = self.videoPlayer.volume
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
                print("加载视频流失败: \(error)")
            }
        }
    }
    
    // 🌟 强力销毁方法：退出时立刻停播并切断网络下载，解决后台偷跑流量
    func cleanup() {
        videoPlayer.pause()
        audioPlayer?.pause()
        videoPlayer.replaceCurrentItem(with: nil)
        audioPlayer?.replaceCurrentItem(with: nil)
        audioPlayer = nil
        isPlaying = false
    }
    
    deinit {
        cleanup()
        if let token = timeObserverToken {
            videoPlayer.removeTimeObserver(token)
        }
    }
}
