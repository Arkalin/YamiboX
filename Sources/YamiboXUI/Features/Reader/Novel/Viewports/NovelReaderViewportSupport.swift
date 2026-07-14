import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct NovelReaderVerticalViewportMetrics: Equatable {
    var contentOffsetY: CGFloat = 0
    var viewportHeight: CGFloat = 0
}

enum NovelReaderVerticalBoundaryDirection: Equatable {
    case previous
    case next
}

struct NovelReaderVerticalBoundaryPullState: Equatable {
    var direction: NovelReaderVerticalBoundaryDirection?
    var distance: CGFloat = 0
    var isArmed = false

    static let idle = NovelReaderVerticalBoundaryPullState()
}

struct NovelReaderVerticalSurfaceFrameValue: Equatable {
    let documentView: Int
    let frame: CGRect
}

/// Per-scroll-frame pixel data (surface frames, TextKit viewport samples)
/// only needs to be *available* to imperative restore/position-tracking code
/// — it is never read from `NovelReaderView.body`. Holding it in a plain
/// reference type stored behind `@State` (instead of `@State`-ing the
/// dictionaries/samples directly) keeps per-frame writes from invalidating
/// and re-evaluating the whole reader view tree on every scroll tick.
@MainActor
final class NovelReaderVerticalViewportSamplingBox {
    var surfaceFrames: [Int: NovelReaderVerticalSurfaceFrameValue] = [:]
    var textViewportSample: NovelTextViewportSample?
}

struct NovelReaderVerticalPositioningFingerprint: Equatable {
    let generation: UInt64
    let view: Int
    let surfaceCount: Int
    let surfaceIndex: Int
    let intraSurfaceProgressBucket: Int
    let readingMode: ReaderReadingMode
}

struct NovelReaderSurfaceSelectionTag: Hashable {
    let view: Int
    let index: Int
}

let readerPadVisibleStatusBarTopInset: CGFloat = 32

struct NovelReaderVerticalSurfaceFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: NovelReaderVerticalSurfaceFrameValue] { [:] }

    static func reduce(value: inout [Int: NovelReaderVerticalSurfaceFrameValue], nextValue: () -> [Int: NovelReaderVerticalSurfaceFrameValue]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct NovelReaderVerticalBoundaryPullBadge: View {
    let text: String
    let systemImage: String
    let progress: CGFloat
    let isArmed: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ReaderGlassContainer(spacing: 8) {
            Label {
                Text(text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } icon: {
                Image(systemName: systemImage)
                    .symbolVariant(isArmed ? .fill : .none)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .readerChromePanel(cornerRadius: 22, tint: badgeTint)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.22 + 0.38 * progress), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 12, y: 4)
        }
    }

    private var badgeTint: Color {
        if isArmed {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.14)
        }
        return readerChromePanelTint(for: colorScheme)
    }
}

extension NovelTextSegmentIdentity {
    /// Segment identities are "<chapterIdentity>#text:N" / "...#image:N"
    /// (`NovelReaderProjectionBuilder.segmentSemantics`); this recovers the
    /// owning chapter identity by trimming that suffix.
    var chapterIdentity: NovelChapterIdentity? {
        guard let suffixRange = rawValue.range(of: #"#(text|image):\d+$"#, options: .regularExpression) else {
            return nil
        }
        return NovelChapterIdentity(rawValue: String(rawValue[..<suffixRange.lowerBound]))
    }
}

extension NovelReaderSurface {
    /// Best-effort external-block lookup for a long-pressed image URL,
    /// paired with the surface it was found on — image blocks don't carry a
    /// page number themselves, only their owning surface's `documentView`
    /// does, and that's needed for `NovelImageLikeAnchor.view`. Only the
    /// surfaces passed in are searched, so a duplicate image URL reused
    /// across two different surfaces resolves to the first match.
    static func externalBlock(
        forImageURL url: URL,
        in surfaces: [NovelReaderSurface]
    ) -> (surface: NovelReaderSurface, block: NovelReaderExternalBlock)? {
        for surface in surfaces {
            if let block = surface.externalBlocks.first(where: { $0.url == url }) {
                return (surface, block)
            }
        }
        return nil
    }
}

func novelImageLikeAnchor(forImageURL url: URL, in surfaces: [NovelReaderSurface]) -> NovelImageLikeAnchor? {
    guard let match = NovelReaderSurface.externalBlock(forImageURL: url, in: surfaces),
          let chapterIdentity = match.block.chapterIdentity,
          let imageSegmentIdentity = match.block.imageSegmentIdentity else {
        return nil
    }
    return NovelImageLikeAnchor(
        chapterIdentity: chapterIdentity,
        imageSegmentIdentity: imageSegmentIdentity.rawValue,
        view: match.surface.documentView,
        resolvedAuthorID: match.surface.resolvedAuthorID
    )
}

/// Single-surface convenience for block-level "is this image liked" lookups
/// (each viewport already has the one `NovelReaderSurface` it's rendering).
func novelImageLikeAnchor(forImageURL url: URL, in surface: NovelReaderSurface?) -> NovelImageLikeAnchor? {
    guard let surface else { return nil }
    return novelImageLikeAnchor(forImageURL: url, in: [surface])
}

func isNovelImageLiked(
    _ url: URL,
    surface: NovelReaderSurface?,
    likedAnchors: Set<NovelImageLikeAnchor>
) -> Bool {
    guard let anchor = novelImageLikeAnchor(forImageURL: url, in: surface) else { return false }
    return likedAnchors.contains(anchor)
}
#endif
