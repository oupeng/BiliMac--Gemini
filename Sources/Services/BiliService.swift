import Foundation

final class BiliService {
    static let shared = BiliService()
    private let session = URLSession.shared
    
    private func createRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        let cookie = CookieManager.shared.cookieHeader
        if !cookie.isEmpty {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return req
    }
    
    func fetchUserInfo() async throws -> UserInfo {
        let url = URL(string: "https://api.bilibili.com/x/web-interface/nav")!
        let req = createRequest(url: url)
        let (data, _) = try await session.data(for: req)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any] else {
            return UserInfo(isLogin: false, uname: "未登录", face: "", mid: 0, vipType: 0, vipStatus: 0)
        }
        
        if let wbiImg = dataDict["wbi_img"] as? [String: Any],
           let imgUrl = wbiImg["img_url"] as? String,
           let subUrl = wbiImg["sub_url"] as? String {
            if let iKey = imgUrl.split(separator: "/").last?.split(separator: ".").first {
                WbiSigner.imgKey = String(iKey)
            }
            if let sKey = subUrl.split(separator: "/").last?.split(separator: ".").first {
                WbiSigner.subKey = String(sKey)
            }
        }
        
        return UserInfo(
            isLogin: dataDict["isLogin"] as? Bool ?? false,
            uname: dataDict["uname"] as? String ?? "用户",
            face: dataDict["face"] as? String ?? "",
            mid: dataDict["mid"] as? Int64 ?? 0,
            vipType: dataDict["vipType"] as? Int ?? 0,
            vipStatus: dataDict["vipStatus"] as? Int ?? 0
        )
    }
    
    func fetchRecommendVideos() async throws -> [VideoItem] {
        let baseParams = ["fresh_type": "3", "ps": "20", "fresh_idx": "1"]
        let signed = WbiSigner.sign(params: baseParams)
        var comp = URLComponents(string: "https://api.bilibili.com/x/web-interface/index/top/feed/rcmd")!
        comp.queryItems = signed.map { URLQueryItem(name: $0.key, value: $0.value) }
        
        let req = createRequest(url: comp.url!)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let items = dataObj["item"] as? [[String: Any]] else { return [] }
        
        return items.compactMap { d in
            guard let bvid = d["bvid"] as? String,
                  let title = d["title"] as? String,
                  let pic = d["pic"] as? String else { return nil }
            let owner = d["owner"] as? [String: Any]
            let stat = d["stat"] as? [String: Any]
            return VideoItem(
                bvid: bvid,
                aid: d["id"] as? Int,
                title: title,
                pic: pic,
                ownerName: owner?["name"] as? String ?? "",
                ownerFace: owner?["face"] as? String,
                duration: d["duration"] as? Int,
                viewCount: stat?["view"] as? Int,
                danmakuCount: stat?["danmaku"] as? Int
            )
        }
    }
    
    func fetchPopularVideos() async throws -> [VideoItem] {
        let url = URL(string: "https://api.bilibili.com/x/web-interface/popular?ps=20&pn=1")!
        let req = createRequest(url: url)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else { return [] }
        
        return list.compactMap { d in
            guard let bvid = d["bvid"] as? String,
                  let title = d["title"] as? String,
                  let pic = d["pic"] as? String else { return nil }
            let owner = d["owner"] as? [String: Any]
            let stat = d["stat"] as? [String: Any]
            return VideoItem(
                bvid: bvid,
                aid: d["aid"] as? Int,
                title: title,
                pic: pic,
                ownerName: owner?["name"] as? String ?? "",
                ownerFace: owner?["face"] as? String,
                duration: d["duration"] as? Int,
                viewCount: stat?["view"] as? Int,
                danmakuCount: stat?["danmaku"] as? Int
            )
        }
    }
    
    func fetchWatchLater() async throws -> [VideoItem] {
        let url = URL(string: "https://api.bilibili.com/x/v2/history/toview")!
        let req = createRequest(url: url)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else { return [] }
        
        return list.compactMap { d in
            guard let bvid = d["bvid"] as? String,
                  let title = d["title"] as? String,
                  let pic = d["pic"] as? String else { return nil }
            let owner = d["owner"] as? [String: Any]
            let stat = d["stat"] as? [String: Any]
            return VideoItem(
                bvid: bvid,
                aid: d["aid"] as? Int,
                title: title,
                pic: pic,
                ownerName: owner?["name"] as? String ?? "",
                ownerFace: owner?["face"] as? String,
                duration: d["duration"] as? Int,
                viewCount: stat?["view"] as? Int,
                danmakuCount: stat?["danmaku"] as? Int
            )
        }
    }
    
    func fetchFavoriteFolders(mid: Int64) async throws -> [FavoriteFolder] {
        let url = URL(string: "https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=\(mid)")!
        let req = createRequest(url: url)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else { return [] }
        
        return list.compactMap { d in
            guard let id = d["id"] as? Int64,
                  let title = d["title"] as? String else { return nil }
            return FavoriteFolder(id: id, title: title, media_count: d["media_count"] as? Int ?? 0)
        }
    }
    
    func fetchFavoriteVideos(folderId: Int64) async throws -> [VideoItem] {
        let url = URL(string: "https://api.bilibili.com/x/v3/fav/resource/list?media_id=\(folderId)&pn=1&ps=20")!
        let req = createRequest(url: url)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let medias = dataObj["medias"] as? [[String: Any]] else { return [] }
        
        return medias.compactMap { d in
            guard let bvid = d["bvid"] as? String,
                  let title = d["title"] as? String,
                  let cover = d["cover"] as? String else { return nil }
            let upper = d["upper"] as? [String: Any]
            let cnt = d["cnt_info"] as? [String: Any]
            return VideoItem(
                bvid: bvid,
                aid: d["id"] as? Int,
                title: title,
                pic: cover,
                ownerName: upper?["name"] as? String ?? "",
                ownerFace: upper?["face"] as? String,
                duration: d["duration"] as? Int,
                viewCount: cnt?["play"] as? Int,
                danmakuCount: cnt?["danmaku"] as? Int
            )
        }
    }
    
    func fetchVideoDetail(bvid: String) async throws -> VideoDetail {
        let url = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(bvid)")!
        let req = createRequest(url: url)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let aid = d["aid"] as? Int,
              let cid = d["cid"] as? Int,
              let title = d["title"] as? String,
              let desc = d["desc"] as? String,
              let pic = d["pic"] as? String,
              let owner = d["owner"] as? [String: Any],
              let stat = d["stat"] as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        
        return VideoDetail(
            bvid: bvid,
            aid: aid,
            cid: cid,
            title: title,
            desc: desc,
            pic: pic,
            ownerName: owner["name"] as? String ?? "",
            ownerFace: owner["face"] as? String ?? "",
            ownerMid: owner["mid"] as? Int ?? 0,
            viewCount: stat["view"] as? Int ?? 0,
            likeCount: stat["like"] as? Int ?? 0,
            replyCount: stat["reply"] as? Int ?? 0,
            pubdate: d["pubdate"] as? Int ?? 0
        )
    }
    
    func fetchRelatedVideos(bvid: String) async throws -> [VideoItem] {
        let url = URL(string: "https://api.bilibili.com/x/web-interface/archive/related?bvid=\(bvid)")!
        let req = createRequest(url: url)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        
        return list.compactMap { d in
            guard let bv = d["bvid"] as? String,
                  let title = d["title"] as? String,
                  let pic = d["pic"] as? String else { return nil }
            let owner = d["owner"] as? [String: Any]
            let stat = d["stat"] as? [String: Any]
            return VideoItem(
                bvid: bv,
                aid: d["aid"] as? Int,
                title: title,
                pic: pic,
                ownerName: owner?["name"] as? String ?? "",
                ownerFace: owner?["face"] as? String,
                duration: d["duration"] as? Int,
                viewCount: stat?["view"] as? Int,
                danmakuCount: stat?["danmaku"] as? Int
            )
        }
    }
    
    // MARK: - 真正获取大会员高画质（强制启用现代 DASH 架构，支持 4K / 1080P60 / 1080P+）
    func fetchPlayUrl(bvid: String, cid: Int, qn: Int = 116) async throws -> VideoPlayUrlResponse {
        let params: [String: String] = [
            "bvid": bvid,
            "cid": "\(cid)",
            "qn": "\(qn)",
            "fnval": "16", // 🌟 16 强制开启标准 DASH，彻底解除 720P 封顶限制
            "fnver": "0",
            "fourk": "1"
        ]
        let signed = WbiSigner.sign(params: params)
        var comp = URLComponents(string: "https://api.bilibili.com/x/player/wbi/playurl")!
        comp.queryItems = signed.map { URLQueryItem(name: $0.key, value: $0.value) }
        
        let req = createRequest(url: comp.url!)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: dataObj)
        return try JSONDecoder().decode(VideoPlayUrlResponse.self, from: jsonData)
    }
    
    func fetchComments(aid: Int, page: Int = 1) async throws -> [BiliComment] {
        let url = URL(string: "https://api.bilibili.com/x/v2/reply?type=1&oid=\(aid)&pn=\(page)&ps=20&sort=1")!
        let req = createRequest(url: url)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let replies = dataObj["replies"] as? [[String: Any]] else { return [] }
        
        return replies.compactMap { r -> BiliComment? in
            guard let rpid = r["rpid"] as? Int64,
                  let member = r["member"] as? [String: Any],
                  let uname = member["uname"] as? String,
                  let avatar = member["avatar"] as? String,
                  let content = r["content"] as? [String: Any],
                  let message = content["message"] as? String else { return nil }
            
            let vip = member["vip"] as? [String: Any]
            let isVip = (vip?["vipStatus"] as? Int ?? 0) == 1
            
            var subReplies: [BiliComment] = []
            if let rawSubs = r["replies"] as? [[String: Any]] {
                subReplies = rawSubs.compactMap { s in
                    guard let sRpid = s["rpid"] as? Int64,
                          let sMember = s["member"] as? [String: Any],
                          let sUname = sMember["uname"] as? String,
                          let sAvatar = sMember["avatar"] as? String,
                          let sContent = s["content"] as? [String: Any],
                          let sMsg = sContent["message"] as? String else { return nil }
                    return BiliComment(
                        rpid: sRpid,
                        mid: sMember["mid"] as? Int64 ?? 0,
                        uname: sUname,
                        avatar: sAvatar,
                        message: sMsg,
                        like: s["like"] as? Int ?? 0,
                        ctime: s["ctime"] as? Int ?? 0,
                        replies: nil,
                        isVip: false
                    )
                }
            }
            
            return BiliComment(
                rpid: rpid,
                mid: member["mid"] as? Int64 ?? 0,
                uname: uname,
                avatar: avatar,
                message: message,
                like: r["like"] as? Int ?? 0,
                ctime: r["ctime"] as? Int ?? 0,
                replies: subReplies,
                isVip: isVip
            )
        }
    }
    
    func generateQRCode() async throws -> (url: String, key: String) {
        let url = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!
        let req = createRequest(url: url)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let qurl = dataObj["url"] as? String,
              let qkey = dataObj["qrcode_key"] as? String else {
            throw URLError(.badServerResponse)
        }
        return (qurl, qkey)
    }
    
    func pollQRCode(key: String) async throws -> (code: Int, sessdata: String, biliJct: String, dedeUserId: String) {
        let url = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=\(key)")!
        let req = createRequest(url: url)
        let (data, response) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let code = dataObj["code"] as? Int else {
            return (-1, "", "", "")
        }
        
        var sess = ""
        var jct = ""
        var uid = ""
        
        if code == 0, let httpResp = response as? HTTPURLResponse {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: httpResp.allHeaderFields as? [String: String] ?? [:], for: url)
            for c in cookies {
                if c.name == "SESSDATA" { sess = c.value }
                if c.name == "bili_jct" { jct = c.value }
                if c.name == "DedeUserID" { uid = c.value }
            }
        }
        return (code, sess, jct, uid)
    }
}
