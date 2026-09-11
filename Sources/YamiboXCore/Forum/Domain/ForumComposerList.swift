import Foundation

extension ForumComposerDocument {
    func removingListItems(in visible: ForumComposerRange, projection: ForumComposerProjection) -> [ForumComposerSourceEdit] {
        var lists: [String: ForumComposerNode] = [:]
        for span in projection.spans(in: visible) {
            if let list = span.ancestors.last(where: { $0.tag == .list }) { lists[list.id] = list }
        }
        let roots = lists.values.filter { node in
            !lists.values.contains { $0.id != node.id && $0.contentRange.location <= node.range.location && $0.contentRange.end >= node.range.end }
        }
        return roots.compactMap { list in
            let items = list.children.filter { $0.tag == .item }
            let selected = items.indices.filter { index in
                let end = index + 1 < items.count ? items[index + 1].range.location : list.contentRange.end
                let start = projection.spans.first { span in
                    guard span.nodeID == items[index].id else { return false }
                    if case .listMarker = span.kind { return true }
                    return false
                }?.range.location ?? projection.visibleOffset(forSourceOffset: items[index].range.location)
                let finish = projection.visibleOffset(forSourceOffset: end)
                return ForumComposerRange(location: start, length: max(1, finish - start)).intersection(visible) != nil
            }
            guard let first = selected.first, let last = selected.last else { return nil }
            let start = items[first].range.location
            let end = last + 1 < items.count ? items[last + 1].range.location : list.contentRange.end
            let before = substring(.init(location: list.contentRange.location, length: start - list.contentRange.location))
            let after = substring(.init(location: end, length: list.contentRange.end - end))
            let left = before.isEmpty ? "" : list.opening + before + list.closing
            let right = after.isEmpty ? "" : list.opening + after + list.closing
            var content = substring(.init(location: start, length: end - start)) as NSString
            for index in (first...last).reversed() {
                let marker = items[index]
                content = content.replacingCharacters(in: NSRange(location: marker.range.location - start, length: marker.range.length), with: index == first ? "" : "\n") as NSString
            }
            return .init(range: list.range, replacement: left + (left.isEmpty ? "" : "\n") + (content as String) + (right.isEmpty ? "" : "\n") + right)
        }
    }

    public func listInput(at visibleOffset: Int, backspace: Bool = false, parsesEmoticons: Bool = true) -> ForumComposerCommand? {
        let projection = ForumComposerProjection(document: self, parsesEmoticons: parsesEmoticons)
        let offset = projection.sourceOffset(forVisibleOffset: visibleOffset)
        guard let list = ancestors(at: offset).last(where: { $0.tag == .list }),
              let item = list.children.last(where: { $0.tag == .item && $0.range.end <= offset }) else { return nil }
        let next = list.children.first { $0.tag == .item && $0.range.location > item.range.location }
        let end = next?.range.location ?? list.contentRange.end
        let body = substring(.init(location: item.range.end, length: end - item.range.end))
        if backspace {
            guard projection.visibleOffset(forSourceOffset: item.range.end) == visibleOffset else { return nil }
            return listIndent(at: visibleOffset, increase: false, parsesEmoticons: parsesEmoticons)
        }
        if ForumComposerDocument(source: body).plainText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let before = substring(.init(location: list.contentRange.location, length: item.range.location - list.contentRange.location))
            let after = substring(.init(location: end, length: list.contentRange.end - end))
            let left = before.isEmpty ? "" : list.opening + before + list.closing
            let right = after.isEmpty ? "" : list.opening + after + list.closing
            let separator = ancestors(at: offset).filter { $0.tag == .list }.count > 1 ? "[*]" : "\n"
            let replacement = left + separator + right
            return .edit([.init(range: list.range, replacement: replacement)], selection: .init(sourceRange: .init(location: list.range.location + left.utf16.count + separator.utf16.count)))
        }
        let stack = ancestors(at: offset).filter { $0.range.location > list.range.location }
        let prefix = stack.reversed().map(\.closing).joined() + "\n[*]" + stack.map(\.opening).joined()
        return .edit([.init(range: .init(location: offset), replacement: prefix)], selection: .init(sourceRange: .init(location: offset + prefix.utf16.count)))
    }

    public func listIndent(at visibleOffset: Int, increase: Bool, parsesEmoticons: Bool = true) -> ForumComposerCommand? {
        let projection = ForumComposerProjection(document: self, parsesEmoticons: parsesEmoticons)
        let offset = projection.sourceOffset(forVisibleOffset: visibleOffset)
        let ancestors = ancestors(at: offset)
        guard let list = ancestors.last(where: { $0.tag == .list }),
              let item = list.children.last(where: { $0.tag == .item && $0.range.end <= offset }) else { return nil }
        let next = list.children.first { $0.tag == .item && $0.range.location > item.range.location }
        let end = next?.range.location ?? list.contentRange.end
        let range = ForumComposerRange(location: item.range.location, length: end - item.range.location)
        let content = substring(range)
        if increase {
            guard list.children.contains(where: { $0.tag == .item && $0.range.location < item.range.location }) else { return nil }
            return .edit([.init(range: range, replacement: list.opening + content + list.closing)], selection: .init(sourceRange: .init(location: offset + list.opening.utf16.count)))
        }
        let before = substring(.init(location: list.contentRange.location, length: item.range.location - list.contentRange.location))
        let after = substring(.init(location: end, length: list.contentRange.end - end))
        let left = before.isEmpty ? "" : list.opening + before + list.closing
        let right = after.isEmpty ? "" : list.opening + after + list.closing
        let nested = ancestors.filter { $0.tag == .list }.count > 1
        let moved = nested ? content : String(content.dropFirst(item.opening.count))
        let separator = nested ? "" : "\n"
        let replacement = left + separator + moved + right
        let removed = nested ? 0 : item.opening.utf16.count
        return .edit([.init(range: list.range, replacement: replacement)], selection: .init(sourceRange: .init(location: list.range.location + left.utf16.count + separator.utf16.count + max(0, offset - item.range.location - removed))))
    }
}
