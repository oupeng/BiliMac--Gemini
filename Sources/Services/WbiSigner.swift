import Foundation
import CryptoKit

struct WbiSigner {
    private static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52
    ]
    
    // 默认兜底 key，日常会通过 nav 接口自动刷新
    static var imgKey: String = "7cd084481368485c8eab10cc4d0890c1"
    static var subKey: String = "4932c028e3674681977797b5e806c9e1"
    
    private static func getMixinKey(raw: String) -> String {
        var res = ""
        let chars = Array(raw)
        for idx in mixinKeyEncTab {
            if idx < chars.count {
                res.append(chars[idx])
            }
        }
        return String(res.prefix(32))
    }
    
    static func sign(params: [String: String]) -> [String: String] {
        var newParams = params
        newParams["wts"] = "\(Int(Date().timeIntervalSince1970))"
        
        // 过滤特殊字符
        let filterChars = CharacterSet(charactersIn: "!'()*")
        for (k, v) in newParams {
            newParams[k] = v.components(separatedBy: filterChars).joined()
        }
        
        let sortedKeys = newParams.keys.sorted()
        let queryString = sortedKeys.map { key in
            let escapedVal = newParams[key]!.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? newParams[key]!
            return "\(key)=\(escapedVal)"
        }.joined(separator: "&")
        
        let mixinKey = getMixinKey(raw: imgKey + subKey)
        let stringToHash = queryString + mixinKey
        let hash = Insecure.MD5.hash(data: stringToHash.data(using: .utf8) ?? Data())
        let w_rid = hash.map { String(format: "%02x", $0) }.joined()
        
        newParams["w_rid"] = w_rid
        return newParams
    }
}
