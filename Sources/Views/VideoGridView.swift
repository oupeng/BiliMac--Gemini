import SwiftUI

struct VideoGridView: View {
    let title: String
    let videos: [VideoItem]
    let onSelect: (VideoItem) -> Void
    let onRefresh: () -> Void
    
    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(title)
                        .font(.title2.bold())
                    Spacer()
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(videos) { item in
                        VideoCardView(item: item)
                            .onTapGesture {
                                onSelect(item)
                            }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }
}
