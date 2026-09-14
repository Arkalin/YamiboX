import SwiftUI
import Testing
@testable import YamiboXUI

#if os(iOS)
@MainActor @Suite("Reader information animation", .serialized)
struct ReaderInformationAnimationTests {
    @Test func titleReplacementSettlesAndPageReuseDiscardsThePreviousTitle() async throws {
        let record = RenderRecord()
        let host = UIHostingController(rootView: titleContent("Chapter", pageID: "first", record: record))
        let window = show(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle()
        #expect(record.last?.pageLine == "Chapter")

        host.rootView = titleContent("19 pages remaining", pageID: "first", record: record)
        try await settle()
        #expect(record.last?.pageLine == "19 pages remaining")

        host.rootView = titleContent("Chapter", pageID: "first", record: record)
        try await Task.sleep(for: .milliseconds(45))
        host.rootView = titleContent("19 pages remaining", pageID: "first", record: record)
        try await settle()
        #expect(record.last?.pageLine == "19 pages remaining")

        host.rootView = titleContent("Next chapter", pageID: "next", record: record)
        try await settle()
        #expect(record.last?.pageLine == "Next chapter")
    }

    @Test func onlyVisibleFormatChangesOnTheSamePageUseReplacement() {
        let styles: [ReaderPageInformationPresentation.PageNumberStyle] = [.hidden, .compact, .full]
        for previous in styles {
            for next in styles {
                let expected = previous != .hidden && next != .hidden && previous != next
                #expect(ReaderInformationAnimation.shouldReplaceFooter(from: value(previous), to: value(next), reduceMotion: false) == expected)
                #expect(!ReaderInformationAnimation.shouldReplaceFooter(from: value(previous), to: value(next), reduceMotion: true))
                #expect(!ReaderInformationAnimation.shouldReplaceFooter(from: value(previous), to: value(next, page: "next"), reduceMotion: false))
            }
        }
    }

    @Test func rapidReversalsAndPageReuseDoNotPublishObsoleteText() async throws {
        let record = RenderRecord()
        let host = UIHostingController(rootView: content(value(.compact), record: record))
        let window = show(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle()
        #expect(record.last?.style == .compact)

        host.rootView = content(value(.full), record: record)
        try await Task.sleep(for: .milliseconds(45))
        #expect(record.last?.style == .compact)
        host.rootView = content(value(.compact), record: record)
        try await settle()
        #expect(record.last?.style == .compact)

        host.rootView = content(value(.full), record: record)
        try await Task.sleep(for: .milliseconds(180))
        #expect(record.last?.style == .full)
        host.rootView = content(value(.compact), record: record)
        try await Task.sleep(for: .milliseconds(35))
        host.rootView = content(value(.full, page: "next"), record: record)
        try await settle()
        #expect(record.last?.pageID == "next")
        #expect(record.last?.style == .full)
    }

    @Test func hiddenUpdatesPreserveTheOutgoingFormatAndRestoreWithoutDelay() async throws {
        let record = RenderRecord()
        let host = UIHostingController(rootView: content(value(.full), record: record))
        let window = show(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle()
        host.rootView = content(value(.hidden), record: record)
        try await Task.sleep(for: .milliseconds(60))
        #expect(record.last?.style == .full)
        host.rootView = content(value(.compact), record: record)
        try await Task.sleep(for: .milliseconds(60))
        #expect(record.last?.style == .compact)
    }

    private func value(_ style: ReaderPageInformationPresentation.PageNumberStyle, page: String = "page") -> ReaderInformationFooterValue {
        ReaderInformationFooterValue(pageID: page, number: 7, pageLine: "7 / 20", webLine: "1 / 2", style: style)
    }

    private func content(_ value: ReaderInformationFooterValue, record: RenderRecord) -> some View {
        ReaderInformationFooterReplacement(value: value) { value in
            RenderProbe(value: value, record: record)
        }
    }

    private func titleContent(_ title: String, pageID: String, record: RenderRecord) -> some View {
        RenderProbe(value: ReaderInformationFooterValue(
            pageID: pageID, number: 1, pageLine: title, webLine: "", style: .full
        ), record: record)
        .modifier(ReaderInformationTitleTransition(title: title))
        .id(pageID)
    }

    private func show(_ host: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        return window
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }
}

@MainActor private final class RenderRecord {
    var last: ReaderInformationFooterValue?
}

private struct RenderProbe: UIViewRepresentable {
    let value: ReaderInformationFooterValue
    let record: RenderRecord
    func makeUIView(context: Context) -> UILabel { UILabel() }
    func updateUIView(_ view: UILabel, context: Context) {
        record.last = value
        view.text = value.style == .compact ? String(value.number) : value.pageLine
    }
}
#endif
