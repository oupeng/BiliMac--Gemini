import SwiftUI

enum TabType: String, CaseIterable, Identifiable {
    case recommend = "推荐"
    case popular = "热门"
    case watchLater = "稍后再看"
    case favorite = "收藏"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .recommend: return "sparkles"
        case .popular: return "flame.fill"
        case .watchLater: return "clock.fill"
        case .favorite: return "star.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selectedTab: TabType
    @Binding var userInfo: UserInfo?
    let onOpenLogin: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // 用户状态卡片
            HStack(spacing: 12) {
                if let u = userInfo, u.isLogin {
                    AsyncImage(url: URL(string: u.face)) { phase in
                        if let img = phase.image {
                            img.resizable()
                        } else {
                            Circle().fill(Color.gray.opacity(0.3))
                        }
                    }
                    .frame(width: 38, height: 38)
                    .clipShape(Circle())
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(u.uname)
                            .font(.headline)
                            .lineLimit(1)
                        
                        if u.isVipActive {
                            Text("大会员")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.pink)
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        } else {
                            Text("已登录")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Button(action: onOpenLogin) {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.plus")
                            Text("点击登录")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Spacer()
            }
            .padding()
            
            Divider()
            
            // 选项列表
            List(TabType.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
        }
    }
}
