import SwiftUI

struct VideoCardView: View {
    let item: VideoItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: fixImageUrl(item.pic)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(16/9, contentMode: .fill)
                    case .failure(_):
                        Color.gray.opacity(0.2)
                    default:
                        ProgressView()
                    }
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipped()
                .cornerRadius(8)
                
                HStack(spacing: 4) {
                    if let d = item.duration {
                        Text(item.formattedDuration)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.75))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                }
                .padding(6)
            }
            
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .frame(height: 36, alignment: .topLeading)
            
            HStack {
                Text(item.ownerName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("▶ \(item.formattedViewCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }
    
    private func fixImageUrl(_ urlStr: String) -> URL? {
        var str = urlStr
        if str.hasPrefix("//") { str = "https:" + str }
        return URL(string: str)
    }
}
