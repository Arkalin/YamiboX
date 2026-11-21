import SwiftUI
import YamiboXCore

struct LocalFavoriteSmartCardBadge: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(colorScheme == .dark ? .black : .white)
            .padding(5)
            .background(appTheme.controlAccent, in: Circle())
            .offset(x: 5, y: -5)
            .accessibilityHidden(true)
    }
}

struct LocalFavoriteCollectionMosaic: View {
    let color: Color
    let tiles: [LocalFavoriteCollectionPreviewTile]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<2, id: \.self) { column in
                        tile(at: row * 2 + column)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(at index: Int) -> some View {
        Group {
            if index < tiles.count {
                BookCoverThumbnail(source: tiles[index].coverSource, title: tiles[index].title)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.18))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity)
    }
}

struct LocalFavoriteCollectionCoverPreview: View {
    let color: Color
    let tiles: [LocalFavoriteCollectionPreviewTile]

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let columnWidth = (proxy.size.width - spacing) / 2
            let rowHeight = (proxy.size.height - spacing) / 2
            VStack(spacing: spacing) {
                HStack(spacing: spacing) {
                    tile(at: 0, width: columnWidth, height: rowHeight)
                    tile(at: 1, width: columnWidth, height: rowHeight)
                }
                HStack(spacing: spacing) {
                    tile(at: 2, width: columnWidth, height: rowHeight)
                    tile(at: 3, width: columnWidth, height: rowHeight)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(at index: Int, width: CGFloat, height: CGFloat) -> some View {
        Group {
            if index < tiles.count {
                BookCoverThumbnail(source: tiles[index].coverSource, title: tiles[index].title)
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color.opacity(index == 0 ? 0.8 : 0.18))
            }
        }
        .frame(width: max(0, width), height: max(0, height))
    }
}
