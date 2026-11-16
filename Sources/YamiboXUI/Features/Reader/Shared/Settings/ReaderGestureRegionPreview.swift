import SwiftUI
import YamiboXCore

extension ReaderGestureRegionAction {
    var title: String {
        switch self {
        case .previous: L10n.string("reader.previous_page")
        case .toggleChrome: L10n.string("reader.external.menu")
        case .next: L10n.string("reader.next_page")
        }
    }
}

/// Use the same shape and label geometry for the preview and interactive remote.
struct ReaderGestureRegionMap<Content: View>: View {
    let layout: ReaderGestureRegionLayout
    @ViewBuilder let content: (ReaderGestureRegionAction, Int, ReaderGestureRegionShape) -> Content

    var body: some View {
        GeometryReader { proxy in
            let unit = CGSize(width: proxy.size.width / 3, height: proxy.size.height / 3)
            let regions = layout.regions
            ForEach(regions.indices, id: \.self) { index in
                let region = regions[index]
                let bounds = region.rectangles.reduce(CGRect.null) { $0.union($1) }
                let shape = ReaderGestureRegionShape(rectangles: region.rectangles, bounds: bounds)
                content(region.action, index, shape)
                    .frame(width: bounds.width * unit.width, height: bounds.height * unit.height)
                    .position(x: bounds.midX * unit.width, y: bounds.midY * unit.height)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct ReaderGestureRegionShape: Shape {
    let rectangles: [CGRect]
    let bounds: CGRect

    func path(in rect: CGRect) -> Path {
        Path { path in
            for part in rectangles {
                path.addRect(project(part, into: rect))
            }
        }
    }

    var labelCenter: UnitPoint {
        let label = labelFrame(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UnitPoint(x: label.midX, y: label.midY)
    }

    func labelFrame(in rect: CGRect) -> CGRect {
        project(rectangles[0], into: rect)
    }

    private func project(_ part: CGRect, into rect: CGRect) -> CGRect {
        let scaleX = rect.width / bounds.width
        let scaleY = rect.height / bounds.height
        return CGRect(x: rect.minX + (part.minX - bounds.minX) * scaleX,
                      y: rect.minY + (part.minY - bounds.minY) * scaleY,
                      width: part.width * scaleX, height: part.height * scaleY)
    }
}

struct ReaderGestureRegionPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ReaderGestureRegionLayout
    let onSave: (ReaderGestureRegionLayout) -> Void

    init(selection: ReaderGestureRegionLayout, onSave: @escaping (ReaderGestureRegionLayout) -> Void) {
        _selection = State(initialValue: selection)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(ReaderGestureRegionLayout.allCases, id: \.self) { layout in
                    ReaderGestureRegionMap(layout: layout) { action, _, shape in
                        previewRegion(action, shape: shape)
                    }
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 38)
                    .tag(layout)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Picker(L10n.string("reader.gesture_regions.title"), selection: $selection) {
                    ForEach(ReaderGestureRegionLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    } label: {
                        Label(L10n.string("common.cancel"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(selection)
                        dismiss()
                    } label: {
                        Label(L10n.string("common.save"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
    }

    private func previewRegion(_ action: ReaderGestureRegionAction, shape: ReaderGestureRegionShape) -> some View {
        GeometryReader { proxy in
            let frame = shape.labelFrame(in: CGRect(origin: .zero, size: proxy.size))
            ViewThatFits {
                VStack(spacing: 6) {
                    Image(systemName: symbol(for: action))
                    Text(action.title)
                }
                .fixedSize()
                Text(action.title).lineLimit(1).minimumScaleFactor(0.45)
            }
            .font(.headline)
            .padding(.horizontal, 4)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
        }
        .background {
            shape.fill(color(for: action))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
    }

    private func symbol(for action: ReaderGestureRegionAction) -> String {
        switch action {
        case .previous: "chevron.backward"
        case .toggleChrome: "line.3.horizontal"
        case .next: "chevron.forward"
        }
    }

    private func color(for action: ReaderGestureRegionAction) -> Color {
        switch action {
        case .previous: Color(uiColor: .secondarySystemGroupedBackground)
        case .toggleChrome: Color(uiColor: .tertiarySystemGroupedBackground).opacity(0.7).mix(with: .gray, by: 0.18)
        case .next: Color(uiColor: .systemFill).mix(with: .accentColor, by: 0.14)
        }
    }
}
