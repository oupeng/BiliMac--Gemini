import SwiftUI

struct CommentSectionView: View {
    let aid: Int
    @State private var comments: [BiliComment] = []
    @State private var isLoading = false
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if isLoading && comments.isEmpty {
                    ProgressView().padding()
                } else if comments.isEmpty {
                    Text("暂无评论").foregroundColor(.secondary).padding()
                } else {
                    ForEach(comments) { comment in
                        CommentRow(comment: comment)
                        Divider()
                    }
                }
            }
            .padding(14)
        }
        .task {
            loadComments()
        }
    }
    
    private func loadComments() {
        guard aid > 0 else { return }
        isLoading = true
        Task {
            if let list = try? await BiliService.shared.fetchComments(aid: aid) {
                self.comments = list
            }
            isLoading = false
        }
    }
}

struct CommentRow: View {
    let comment: BiliComment
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: fixUrl(comment.avatar)) { phase in
                if let img = phase.image {
                    img.resizable()
                } else {
                    Circle().fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(comment.uname)
                        .font(.caption.bold())
                        .foregroundColor(comment.isVip ? .pink : .primary)
                    Spacer()
                    Text("👍 \(comment.like)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Text(comment.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                
                // 楼中楼对话展示
                if let replies = comment.replies, !replies.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(replies.prefix(3)) { sub in
                            HStack(alignment: .top, spacing: 4) {
                                Text(sub.uname + ":")
                                    .font(.caption.bold())
                                    .foregroundColor(.secondary)
                                Text(sub.message)
                                    .font(.caption)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                }
            }
        }
    }
    
    private func fixUrl(_ u: String) -> URL? {
        var str = u
        if str.hasPrefix("//") { str = "https:" + str }
        return URL(string: str)
    }
}
