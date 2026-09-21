import SwiftUI
import CoreImage.CIFilterBuiltins

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cookieManager = CookieManager.shared
    
    @State private var qrImage: NSImage?
    @State private var qrKey: String = ""
    @State private var statusText: String = "正在生成二维码..."
    @State private var isPolling = false
    
    // Cookie 手动导入备用
    @State private var inputSessdata: String = ""
    @State private var inputBiliJct: String = ""
    @State private var inputDedeUserId: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("登录哔哩哔哩")
                .font(.title2.bold())
            
            if let img = qrImage {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .cornerRadius(8)
            } else {
                ProgressView()
                    .frame(width: 180, height: 180)
            }
            
            Text(statusText)
                .font(.callout)
                .foregroundColor(.secondary)
            
            Divider()
            
            DisclosureGroup("使用已有 Cookie 登录") {
                VStack(spacing: 8) {
                    TextField("SESSDATA (大会员关键项)", text: $inputSessdata)
                    TextField("bili_jct", text: $inputBiliJct)
                    TextField("DedeUserID", text: $inputDedeUserId)
                    Button("保存 Cookie") {
                        cookieManager.save(sessdata: inputSessdata, biliJct: inputBiliJct, dedeUserId: inputDedeUserId)
                        dismiss()
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            
            Button("关闭") {
                isPolling = false
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 360)
        .task {
            startQRFlow()
        }
    }
    
    private func startQRFlow() {
        Task {
            do {
                let (urlStr, key) = try await BiliService.shared.generateQRCode()
                self.qrKey = key
                self.qrImage = generateQRCodeImage(from: urlStr)
                self.statusText = "请使用哔哩哔哩手机客户端扫码"
                self.isPolling = true
                pollStatus()
            } catch {
                self.statusText = "生成二维码失败，请重试"
            }
        }
    }
    
    private func pollStatus() {
        guard isPolling else { return }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard isPolling else { return }
            let (code, sess, jct, uid) = (try? await BiliService.shared.pollQRCode(key: qrKey)) ?? (-1, "", "", "")
            
            if code == 0 {
                statusText = "登录成功！"
                cookieManager.save(sessdata: sess, biliJct: jct, dedeUserId: uid)
                isPolling = false
                dismiss()
            } else if code == 86038 {
                statusText = "二维码已失效，正在刷新..."
                startQRFlow()
            } else if code == 86090 {
                statusText = "已扫码，请在手机上确认"
                pollStatus()
            } else {
                pollStatus()
            }
        }
    }
    
    private func generateQRCodeImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
