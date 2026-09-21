import Foundation

final class CookieManager: ObservableObject {
    static let shared = CookieManager()
    
    @Published var sessdata: String = ""
    @Published var biliJct: String = ""
    @Published var dedeUserId: String = ""
    
    private let sessdataKey = "bili_sessdata"
    private let biliJctKey = "bili_jct"
    private let dedeUserIdKey = "bili_dede_user_id"
    
    var isLoggedIn: Bool {
        return !sessdata.isEmpty
    }
    
    private init() {
        self.sessdata = UserDefaults.standard.string(forKey: sessdataKey) ?? ""
        self.biliJct = UserDefaults.standard.string(forKey: biliJctKey) ?? ""
        self.dedeUserId = UserDefaults.standard.string(forKey: dedeUserIdKey) ?? ""
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
        return parts.joined(separator: "; ")
    }
}
