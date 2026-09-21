import Foundation

// MARK: - 视频卡片通用模型
struct VideoItem: Identifiable, Codable, Hashable {
    var id: String { bvid }
    let bvid: String
    let aid: Int?
    let title: String
    let pic: String
    let ownerName: String
    let ownerFace: String?
    let duration: Int?
    let viewCount: Int?
    let danmakuCount: Int?
    
    var formattedDuration: String {
        guard let d = duration, d > 0 else { return "00:00" }
        let m = d / 60
        let s = d % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    var formattedViewCount: String {
        guard let v = viewCount else { return "0" }
        if v >= 10000 {
            return String(format: "%.1f万", Double(v) / 10000.0)
        }
        return "\(v)"
    }
}

// MARK: - 视频详情模型
struct VideoDetail: Codable {
    let bvid: String
    let aid: Int
    let cid: Int
    let title: String
    let desc: String
    let pic: String
    let ownerName: String
    let ownerFace: String
    let ownerMid: Int
    let viewCount: Int
    let likeCount: Int
    let replyCount: Int
    let pubdate: Int
}

// MARK: - 播放流模型
struct VideoPlayUrlResponse: Codable {
    let quality: Int
    let format: String?
    let accept_quality: [Int]
    let accept_description: [String]
    let dash: DashData?
    let durl: [DurlData]?
}

struct DashData: Codable {
    let video: [DashStream]
    let audio: [DashStream]?
}

struct DashStream: Codable {
    let id: Int
    let baseUrl: String
    let backupUrl: [String]?
    let bandwidth: Int?
    let codecs: String?
    let width: Int?
    let height: Int?
    let frameRate: String?
}

struct DurlData: Codable {
    let url: String
    let length: Int?
}

// MARK: - 评论模型
struct BiliComment: Identifiable, Codable {
    var id: Int64 { rpid }
    let rpid: Int64
    let mid: Int64
    let uname: String
    let avatar: String
    let message: String
    let like: Int
    let ctime: Int
    let replies: [BiliComment]?
    let isVip: Bool
}

// MARK: - 用户信息模型
struct UserInfo: Codable {
    let isLogin: Bool
    let uname: String
    let face: String
    let mid: Int64
    let vipType: Int
    let vipStatus: Int
    
    var isVipActive: Bool {
        return vipStatus == 1 && vipType > 0
    }
}

// MARK: - 收藏夹模型
struct FavoriteFolder: Identifiable, Codable {
    let id: Int64
    let title: String
    let media_count: Int
}
