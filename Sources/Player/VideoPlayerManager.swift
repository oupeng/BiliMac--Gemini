import Foundation
import Combine

final class VideoPlayerManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentBvid: String = ""
    @Published var currentCid: Int = 0
    @Published var volume: Float = 0.8 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "bili_saved_volume")
        }
    }
    
    init() {
        let savedVol = UserDefaults.standard.float(forKey: "bili_saved_volume")
        self.volume = savedVol == 0 ? 0.8 : savedVol
    }
    
    func playVideo(bvid: String, cid: Int) {
        self.currentBvid = bvid
        self.currentCid = cid
        self.isPlaying = true
    }
    
    // 🌟 全量熔断方法：退出时彻底销毁播放实例，网络连接立即归零
    func cleanup() {
        self.currentBvid = ""
        self.currentCid = 0
        self.isPlaying = false
    }
    
    deinit {
        cleanup()
    }
}
