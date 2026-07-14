import SwiftUI
import YamiboXCore

public struct SpecialThanksView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                SpecialThanksSection(
                    title: L10n.string("special_thanks.open_source_libraries"),
                    items: SpecialThanksItem.openSourceLibraries
                )

                SpecialThanksSection(
                    title: L10n.string("special_thanks.upstream_projects"),
                    items: SpecialThanksItem.upstreamProjects
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .navigationTitle(L10n.string("special_thanks.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct SpecialThanksSection: View {
    let title: String
    let items: [SpecialThanksItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                    }
                    AboutExternalLinkRow(title: item.name, destination: item.url)
                }
            }
        }
    }
}

private struct SpecialThanksItem: Identifiable {
    let id: String
    let name: String
    let url: URL

    static let openSourceLibraries: [SpecialThanksItem] = [
        SpecialThanksItem(id: "grdb", name: "GRDB.swift", url: URL(string: "https://github.com/groue/GRDB.swift")!),
        SpecialThanksItem(id: "kanna", name: "Kanna", url: URL(string: "https://github.com/tid-kijyun/Kanna")!),
        SpecialThanksItem(id: "nuke", name: "Nuke", url: URL(string: "https://github.com/kean/Nuke")!)
    ]

    static let upstreamProjects: [SpecialThanksItem] = [
        SpecialThanksItem(id: "yamiboreaderpro", name: "YamiboReaderPro", url: URL(string: "https://github.com/prprbell/YamiboReaderPro")!),
        SpecialThanksItem(id: "yamibo-app", name: "yamibo-app", url: URL(string: "https://github.com/LittleSurvival/yamibo-app")!)
    ]
}
