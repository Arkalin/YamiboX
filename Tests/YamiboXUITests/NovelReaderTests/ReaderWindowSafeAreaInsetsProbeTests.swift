import Testing
import UIKit
@testable import YamiboXUI

@MainActor
private final class ReaderSafeAreaTestWindow: UIWindow {
    var reportedInsets = UIEdgeInsets.zero

    override var safeAreaInsets: UIEdgeInsets { reportedInsets }
}

@MainActor
private func finishPendingSafeAreaReports() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor
@Test func readerSafeAreaProbesReadTheirOwnWindows() async {
    let firstWindow = ReaderSafeAreaTestWindow()
    firstWindow.reportedInsets = UIEdgeInsets(top: 24, left: 8, bottom: 20, right: 0)
    let secondWindow = ReaderSafeAreaTestWindow()
    secondWindow.reportedInsets = UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 16)
    let firstProbe = ReaderWindowSafeAreaInsetsProbe.ProbeView()
    let secondProbe = ReaderWindowSafeAreaInsetsProbe.ProbeView()
    var firstReported: UIEdgeInsets?
    var secondReported: UIEdgeInsets?
    firstProbe.onChange = { firstReported = $0 }
    secondProbe.onChange = { secondReported = $0 }

    firstWindow.addSubview(firstProbe)
    secondWindow.addSubview(secondProbe)
    await finishPendingSafeAreaReports()

    #expect(firstReported == firstWindow.reportedInsets)
    #expect(secondReported == secondWindow.reportedInsets)
}

@MainActor
@Test func readerSafeAreaProbeClearsInsetsWhenDetached() async {
    let window = ReaderSafeAreaTestWindow()
    let probe = ReaderWindowSafeAreaInsetsProbe.ProbeView()
    var reports: [UIEdgeInsets?] = []
    probe.onChange = { reports.append($0) }

    window.addSubview(probe)
    await finishPendingSafeAreaReports()
    probe.removeFromSuperview()
    await finishPendingSafeAreaReports()

    // Known zero is distinct from an unknown, detached window.
    #expect(reports == [.zero, nil])
}

@MainActor
@Test(arguments: [false, true])
func readerSafeAreaProbeDiscardsReportsQueuedByAPreviousWindow(explicitlyDetaches: Bool) async {
    let firstWindow = ReaderSafeAreaTestWindow()
    let secondWindow = ReaderSafeAreaTestWindow()
    firstWindow.reportedInsets = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
    secondWindow.reportedInsets = firstWindow.reportedInsets
    let probe = ReaderWindowSafeAreaInsetsProbe.ProbeView()
    var reports: [UIEdgeInsets?] = []
    probe.onChange = { reports.append($0) }

    firstWindow.addSubview(probe)
    if explicitlyDetaches { probe.removeFromSuperview() }
    secondWindow.addSubview(probe)
    await finishPendingSafeAreaReports()

    #expect(reports == [secondWindow.reportedInsets])
}

@MainActor
@Test func readerSafeAreaProbePublishesTheLatestLayoutSample() async {
    let window = ReaderSafeAreaTestWindow()
    let probe = ReaderWindowSafeAreaInsetsProbe.ProbeView()
    var reports: [UIEdgeInsets?] = []
    probe.onChange = { reports.append($0) }

    window.addSubview(probe)
    window.reportedInsets = UIEdgeInsets(top: 12, left: 0, bottom: 8, right: 0)
    probe.safeAreaInsetsDidChange()
    await finishPendingSafeAreaReports()

    #expect(reports == [window.reportedInsets])
}
