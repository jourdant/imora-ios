import SwiftUI

/// horizontal "on this day" carousel above the main timeline.
struct MemoryLane: View {
    @Environment(SessionStore.self) private var session
    @State private var memories: [Memory] = []
    @State private var viewer: ViewerContext?

    var body: some View {
        if !memories.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Memories")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(memories) { memory in
                            if let first = memory.assets.first {
                                Button {
                                    openMemory(memory)
                                } label: {
                                    memoryCard(memory, cover: first)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 4)
            .fullScreenCover(item: $viewer) { context in
                AssetViewerScreen(assets: context.assets, initialIndex: context.index) { _ in }
            }
        } else {
            Color.clear
                .frame(height: 0)
                .task { await load() }
        }
    }

    @ViewBuilder private func memoryCard(_ memory: Memory, cover: AssetDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let client = session.client {
                RemoteImage(
                    url: client.thumbnailURL(assetID: cover.id, size: "preview"),
                    targetPixelSize: 640,
                    thumbhash: cover.thumbhash
                )
                .frame(width: 148, height: 196)
                .clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                Text(yearsAgoLabel(memory))
                    .font(.subheadline.weight(.bold))
                Text("\(memory.assets.count) photos")
                    .font(.caption2)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .frame(width: 148, height: 196)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func yearsAgoLabel(_ memory: Memory) -> String {
        let years = Calendar.current.component(.year, from: Date()) - memory.data.year
        return years <= 1 ? "1 year ago" : "\(years) years ago"
    }

    private func openMemory(_ memory: Memory) {
        let assets = memory.assets.map { $0.asAsset() }
        guard !assets.isEmpty else { return }
        viewer = ViewerContext(assets: assets, index: 0)
    }

    private func load() async {
        guard let client = session.client, memories.isEmpty else { return }
        if let fetched = try? await client.memories(for: Date()) {
            memories = fetched.filter { !$0.assets.isEmpty }
        }
    }
}
