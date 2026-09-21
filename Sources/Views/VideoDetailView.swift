import SwiftUI

struct VideoDetailView: View {
    let videoItem: VideoItem
    let onBack: () -> Void
    
    @StateObject private var playerManager = VideoPlayerManager()
    @State private var detail: VideoDetail?
    @State private var relatedVideos: [VideoItem] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航返回条
            HStack {
                Button(action: onBack) {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                
                Spacer()
                Text(detail?.title ?? videoItem.title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: 500)
                Spacer()
            }
            .frame(height: 40)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // 详情主体：左侧 视频+推荐，右侧 评论区
            HSplitView {
                // 左侧面板
                VStack(spacing: 0) {
                    CustomPlayerView(playerManager: playerManager)
                        .aspectRatio(16/9, contentMode: .fit)
                        .background(Color.black)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(detail?.title ?? videoItem.title)
                                .font(.title3.bold())
                            
                            HStack(spacing: 12) {
                                Text(detail?.ownerName ?? videoItem.ownerName)
                                    .font(.subheadline.bold())
                                Text("播放 \(detail?.viewCount ?? 0)  点赞 \(detail?.likeCount ?? 0)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text(detail?.desc ?? "")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            
                            Divider().padding(.vertical, 4)
                            
                            Text("相关视频推荐")
                                .font(.headline)
                            
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                                ForEach(relatedVideos) { item in
                                    VideoCardView(item: item)
                                        .onTapGesture {
                                            switchVideo(item)
                                        }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .frame(minWidth: 550)
                
                // 右侧评论面板
                VStack(spacing: 0) {
                    HStack {
                        Text("评论区")
                            .font(.headline)
                        Spacer()
                        Text("只读模式")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(NSColor.controlBackgroundColor))
                    
                    Divider()
                    
                    if let aid = detail?.aid {
                        CommentSectionView(aid: aid)
                    } else {
                        Spacer()
                    }
                }
                .frame(minWidth: 320, maxWidth: 420)
            }
        }
        .task {
            loadDetail(bvid: videoItem.bvid)
        }
    }
    
    private func loadDetail(bvid: String) {
        Task {
            if let d = try? await BiliService.shared.fetchVideoDetail(bvid: bvid) {
                self.detail = d
                playerManager.playVideo(bvid: d.bvid, cid: d.cid)
            }
            if let rel = try? await BiliService.shared.fetchRelatedVideos(bvid: bvid) {
                self.relatedVideos = rel
            }
        }
    }
    
    private func switchVideo(_ item: VideoItem) {
        loadDetail(bvid: item.bvid)
    }
}
