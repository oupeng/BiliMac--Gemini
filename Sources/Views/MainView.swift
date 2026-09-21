import SwiftUI

struct MainView: View {
    @State private var selectedTab: TabType = .recommend
    @State private var userInfo: UserInfo?
    @State private var showLogin = false
    @State private var selectedVideo: VideoItem?
    
    // 数据流
    @State private var recommendVideos: [VideoItem] = []
    @State private var popularVideos: [VideoItem] = []
    @State private var watchLaterVideos: [VideoItem] = []
    @State private var favoriteVideos: [VideoItem] = []
    
    var body: some View {
        Group {
            if let video = selectedVideo {
                // 同一窗口直接推入详情内联播放
                VideoDetailView(videoItem: video, onBack: {
                    self.selectedVideo = nil
                })
            } else {
                NavigationSplitView {
                    SidebarView(selectedTab: $selectedTab, userInfo: $userInfo, onOpenLogin: {
                        showLogin = true
                    })
                    .frame(minWidth: 180, maxWidth: 220)
                } detail: {
                    switch selectedTab {
                    case .recommend:
                        VideoGridView(title: "推荐视频", videos: recommendVideos, onSelect: { selectedVideo = $0 }) {
                            loadRecommend()
                        }
                    case .popular:
                        VideoGridView(title: "综合热门", videos: popularVideos, onSelect: { selectedVideo = $0 }) {
                            loadPopular()
                        }
                    case .watchLater:
                        VideoGridView(title: "稍后再看", videos: watchLaterVideos, onSelect: { selectedVideo = $0 }) {
                            loadWatchLater()
                        }
                    case .favorite:
                        VideoGridView(title: "我的收藏", videos: favoriteVideos, onSelect: { selectedVideo = $0 }) {
                            loadFavorites()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
                .onDisappear {
                    refreshUserInfo()
                }
        }
        .task {
            refreshUserInfo()
            loadRecommend()
            loadPopular()
        }
    }
    
    private func refreshUserInfo() {
        Task {
            if let u = try? await BiliService.shared.fetchUserInfo() {
                self.userInfo = u
                if u.isLogin {
                    loadWatchLater()
                    loadFavorites()
                }
            }
        }
    }
    
    private func loadRecommend() {
        Task {
            if let v = try? await BiliService.shared.fetchRecommendVideos() {
                self.recommendVideos = v
            }
        }
    }
    
    private func loadPopular() {
        Task {
            if let v = try? await BiliService.shared.fetchPopularVideos() {
                self.popularVideos = v
            }
        }
    }
    
    private func loadWatchLater() {
        Task {
            if let v = try? await BiliService.shared.fetchWatchLater() {
                self.watchLaterVideos = v
            }
        }
    }
    
    private func loadFavorites() {
        Task {
            guard let mid = userInfo?.mid, mid > 0 else { return }
            if let folders = try? await BiliService.shared.fetchFavoriteFolders(mid: mid),
               let first = folders.first {
                if let v = try? await BiliService.shared.fetchFavoriteVideos(folderId: first.id) {
                    self.favoriteVideos = v
                }
            }
        }
    }
}
