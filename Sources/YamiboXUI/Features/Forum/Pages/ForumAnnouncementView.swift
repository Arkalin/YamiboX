import SwiftUI
import YamiboXCore

struct ForumAnnouncementView: View {
    let page: ForumAnnouncementPage
    let url: URL
    let onURLTap: (URL) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !page.filters.isEmpty {
                    Section {
                        Menu {
                            ForEach(page.filters, id: \.url) { filter in
                                Button(filter.title) { onURLTap(filter.url) }
                            }
                        } label: {
                            Label(L10n.string("forum.announcement.filter"), systemImage: "calendar")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                    }
                }
                ForEach(page.items) { item in
                    Section {
                        ForumAnnouncementRow(item: item, url: url,
                                             initiallyExpanded: item.id == (page.selectedID ?? page.items.first?.id),
                                             onURLTap: onURLTap)
                    }
                    .id(item.id)
                }
                if page.items.isEmpty {
                    Text(L10n.string("forum.announcement.empty"))
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: page.selectedID) {
                if let id = page.selectedID { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .accessibilityIdentifier("forum-announcements")
    }
}

private struct ForumAnnouncementRow: View {
    let item: ForumAnnouncement
    let url: URL
    let onURLTap: (URL) -> Void
    @State private var isExpanded: Bool
    @State private var imageRequest: ForumThreadImageBrowserRequest?

    init(item: ForumAnnouncement, url: URL, initiallyExpanded: Bool, onURLTap: @escaping (URL) -> Void) {
        self.item = item
        self.url = url
        self.onURLTap = onURLTap
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let authorURL = item.authorURL {
                    Button(item.author) { onURLTap(authorURL) }
                        .buttonStyle(.plain)
                } else if !item.author.isEmpty {
                    Text(item.author)
                }
                ForumThreadContentBlocksView(
                    blocks: item.blocks, fallbackText: "", refererURL: url,
                    onImageTap: { id, imageURL, title, referer in
                        imageRequest = ForumThreadImageBrowserRequest(
                            items: [ImageBrowserItem(id: id,
                                                     source: YamiboImageSource(url: imageURL, refererPageURL: referer),
                                                     title: title ?? item.title)],
                            initialItemID: id
                        )
                    }, onURLTap: onURLTap
                )
            }
            .padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline)
                if !item.date.isEmpty {
                    Text(item.date).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .fullScreenCover(item: $imageRequest) { request in
            ImageBrowserView(items: request.items, initialItemID: request.initialItemID, mode: .single) {
                imageRequest = nil
            }
        }
    }
}
