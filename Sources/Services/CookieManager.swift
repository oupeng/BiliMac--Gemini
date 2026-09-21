import Foundation

final class CookieManager: ObservableObject {
    static let shared = CookieManager()
    
    @Published var sessdata: String = ""
    @Published var biliJct: String = ""
    @Published var dedeUserId: String = ""
    @Published var buvid3: String = ""
    
    private let sessdataKey = "bili_sessdata"
    private let biliJctKey = "bili_jct"
    private let dedeUserIdKey = "bili_dede_user_id"
    private let buvid3Key = "bili_buvid3"
    
    var isLoggedIn: Bool {
        return !sessdata.isEmpty
    }
    
    private init() {
        self.sessdata = UserDefaults.standard.string(forKey: sessdataKey) ?? ""
        self.biliJct = UserDefaults.standard.string(forKey: biliJctKey) ?? ""
        self.dedeUserId = UserDefaults.standard.string(forKey: dedeUserIdKey) ?? ""
        
        // 确保生成合规的 buvid3 设备指纹，避免 4K 被当作未激活设备截断为 10 秒试看
        if let savedBuvid = UserDefaults.standard.string(forKey: buvid3Key), !savedBuvid.isEmpty {
            self.buvid3 = savedBuvid
        } else {
            let newBuvid = UUID().uuidString + "infoc"
            self.buvid3 = newBuvid
            UserDefaults.standard.set(newBuvid, forKey: buvid3Key)
        }
    }
    
    func save(sessdata: String, biliJct: String, dedeUserId: String) {
        self.sessdata = sessdata
        self.biliJct = biliJct
        self.dedeUserId = dedeUserId
        
        UserDefaults.standard.set(sessdata, forKey: sessdataKey)
        UserDefaults.standard.set(biliJct, forKey: biliJctKey)
        UserDefaults.standard.set(dedeUserId, forKey: dedeUserIdKey)
    }
    
    func clear() {
        self.sessdata = ""
        self.biliJct = ""
        self.dedeUserId = ""
        UserDefaults.standard.removeObject(forKey: sessdataKey)
        UserDefaults.standard.removeObject(forKey: biliJctKey)
        UserDefaults.standard.removeObject(forKey: dedeUserIdKey)
    }
    
    var cookieHeader: String {
        var parts: [String] = []
        if !sessdata.isEmpty { parts.append("SESSDATA=\(sessdata)") }
        if !biliJct.isEmpty { parts.append("bili_jct=\(biliJct)") }
        if !dedeUserId.isEmpty { parts.append("DedeUserID=\(dedeUserId)") }
        if !buvid3.isEmpty {
            parts.append("buvid3=\(buvid3)")
            parts.append("b_nut=\(Int(Date().timeIntervalSince1970))")
        }
        return parts.joined(separator: "; ")
    }
}
