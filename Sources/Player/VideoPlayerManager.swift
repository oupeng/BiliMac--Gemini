import Foundation
import AVFoundation
import Combine

final class VideoPlayerManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 0.8 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "bili_saved_volume")
            applyVolume()
        }
    }
    @Published var currentQualityName: String = "加载中..."
    @Published var availableQualities: [(id: Int, name: String)] = []
    @Published var selectedQualityId: Int = 120
    
    let videoPlayer = AVPlayer()
    private var audioPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var cancellables = Set<AnyCancellable>()
    
    private var currentBvid: String = ""
    private var currentCid: Int = 0
    
    init() {
        let savedVol = UserDefaults.standard.double(forKey: "bili_saved_volume")
        self.volume = savedVol == 0 ? 0.8 : savedVol
        setupTimeObserver()
    }
    
    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = videoPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
            
            if let dur = self.videoPlayer.currentItem?.duration.seconds, !dur.isNaN, dur > 0 {
                self.duration = dur
            }
            
            // 同步独立音频流（DASH 模式）
            if let audio = self.audioPlayer {
                let diff = abs(self.currentTime - audio.currentTime().seconds)
                if diff > 0.15 {
                    audio.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
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
        let resumeTime = currentTime
        loadStream(targetQuality: qn, resumeTime: resumeTime)
    }
    
    private func loadStream(targetQuality: Int, resumeTime: Double = 0) {
        Task { @MainActor in
            do {
                let playInfo = try await BiliService.shared.fetchPlayUrl(bvid: currentBvid, cid: currentCid, qn: targetQuality)
                
                // 设置清晰度选项列表
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
                
                let headers = [
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                    "Referer": "https://www.bilibili.com"
                ]
                
                // 判断是 DASH 还是 单一 MP4
                if let dash = playInfo.dash {
                    // 挑选匹配的视频流
                    let vStream = dash.video.first(where: { $0.id == activeQn }) ?? dash.video.first!
                    let vUrl = URL(string: vStream.baseUrl)!
                    let vAsset = AVURLAsset(url: vUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let vItem = AVPlayerItem(asset: vAsset)
                    self.videoPlayer.replaceCurrentItem(with: vItem)
                    self.videoPlayer.isMuted = true // 画面流静音，由音频流出声
                    
                    // 绑定音频流
                    if let aStream = dash.audio?.first {
                        let aUrl = URL(string: aStream.baseUrl)!
                        let aAsset = AVURLAsset(url: aUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                        let aItem = AVPlayerItem(asset: aAsset)
                        self.audioPlayer = AVPlayer(playerItem: aItem)
                    }
                } else if let durl = playInfo.durl?.first {
                    let vUrl = URL(string: durl.url)!
                    let asset = AVURLAsset(url: vUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let item = AVPlayerItem(asset: asset)
                    self.videoPlayer.replaceCurrentItem(with: item)
                    self.videoPlayer.isMuted = false
                    self.audioPlayer = nil
                }
                
                self.applyVolume()
                if resumeTime > 0 {
                    let t = CMTime(seconds: resumeTime, preferredTimescale: 600)
                    await self.videoPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                    if let audio = self.audioPlayer {
                        await audio.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
                
                self.play()
            } catch {
                print("加载流媒体失败: \(error)")
            }
        }
    }
    
    func play() {
        videoPlayer.play()
        audioPlayer?.play()
        isPlaying = true
    }
    
    func pause() {
        videoPlayer.pause()
        audioPlayer?.pause()
        isPlaying = false
    }
    
    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }
    
    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        videoPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        audioPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    private func applyVolume() {
        if let audio = audioPlayer {
            audio.volume = Float(volume)
            videoPlayer.isMuted = true
        } else {
            videoPlayer.volume = Float(volume)
            videoPlayer.isMuted = false
        }
    }
    
    deinit {
        if let token = timeObserverToken {
            videoPlayer.removeTimeObserver(token)
        }
    }
}
