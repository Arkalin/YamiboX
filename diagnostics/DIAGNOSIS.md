# v0.3.0 compiler crash diagnosis

## Scope and release safety

- Original release commit: `146701083b6cecdab7ec23a7494f8c7651517aeb`.
- The pending release run `33286649625` was canceled before packaging or publishing.
- No GitHub Release for `v0.3.0` exists at the time of diagnosis.
- All experiments live on `codex/diagnose-v030-swift-irgen`, with a read-only workflow token and no publishing steps.

## Exact failure

CI uses Xcode 26.6 (17F113), Swift 6.3.3 (`swiftlang-6.3.3.1.3`), and the iOS 26.5 SDK.

The Swift frontend aborts during IR generation for a generated function adapter:

```text
While emitting IR SIL function "@$sSbScA_pSgIeAghyg_SbIeAghn_TR"
SmallVector unable to grow. Requested capacity (4294967297) is larger than maximum value for size type (4294967295)
SyncCallEmission::setArgs
```

Both the original release archive and the original simulator Debug CI build fail with this symbol. The per-file Debug log identifies `SettingsForumView.swift`. This is not a signing, IPA packaging, release-permission, or dependency-download failure.

## Controlled minimal reproduction

Run: https://github.com/Arkalin/YamiboX/actions/runs/33286951362

Repeated independently in run `33287045963`; all 15 results are identical.

Only SwiftUI and a small model are needed; no YamiboX services or third-party packages are used.

| Variant on Swift 6.3.3 | -Onone | -O | -O + WMO |
| --- | --- | --- | --- |
| `@MainActor` model method passed directly to `Binding.set` | Same crash | Same crash | Pass |
| Same model, explicit closure calling the method | Pass | Pass | Pass |
| Direct method, remove `@MainActor` | Pass | Pass | Pass |
| Direct method, remove `@Observable` only | Same crash | Same crash | Pass |
| Isolated `openURL` completion callback | Pass | Pass | Pass |

All 15 variants pass with local Xcode 27 beta, Swift 6.4 (`swiftlang-6.4.0.20.104`), and the iOS 27 SDK. This is a toolchain comparison, not a compiler-only version bisect, because the SDK also differs.

The small WMO example passes, but the full application WMO archive fails. Optimization can eliminate the problematic adapter in a reduced example; WMO is not a necessary condition, and disabling optimization is not a solution.

## Source trigger and candidate

`Sources/YamiboXUI/Features/Settings/SystemSettings/SettingsForumView.swift:28` passes the main-actor-isolated `SettingsForumViewModel.updateEnhancedCheckInEnabled(_:)` method directly to the generic `Binding<Bool>` setter. It was introduced in `1745026` (enhanced check-in).

The minimal reproduction produces the same generated adapter and compiler abort. Changing only the method-reference expression to an explicit closure avoids that compiler path while preserving the call, input, actor isolation, persistence, and error handling:

```diff
- set: viewModel.updateEnhancedCheckInEnabled
+ set: { viewModel.updateEnhancedCheckInEnabled($0) }
```

The earlier `openURL` change was disproved by a failed archive and has already been undone. Lowering optimization was also disproved. Neither should be retained as a fix.

## Full-project validation

Run: https://github.com/Arkalin/YamiboX/actions/runs/33287045963

The diagnostic job archives the original source, then applies only the candidate line and archives again on the same runner/toolchain. It uses separate DerivedData and archive directories, original Release settings including `-O` and WMO, and no signing.

Result: verified on the same runner in run `33287045963`.

| Original full-project Release archive | Exit 65, exact original compiler-crash symbol |
| --- | --- |
| Full-project Release archive with only the candidate line | Exit 0, `ARCHIVE SUCCEEDED` |

Both logs contain `swiftc -module-name YamiboXUI -O -whole-module-optimization`.

The production worktree now contains the verified setter closure. The experimental project compilation-mode change has been restored to `wholemodule`; `Package.swift` and the release workflow match the original release commit. The aggregate diff against `1467010` is one changed source line.

## Regression coverage

The original normal Swift CI run `33259959831` also reproduces the same compiler failure during simulator Debug compilation. Therefore, the existing actual-app compilation in CI covers this failure; an artificial runtime unit test would not validate an IR generation crash. The isolated compiler probes and the original full Release archive are the direct regression checks.

The existing `SettingsReadingViewModelTests` cover enhanced-check-in loading and persistence. A focused local run with fresh DerivedData passed all 8 tests, with zero failures and zero skips. An initial run with the existing DerivedData encountered stale-symbol link errors; a full clean-directory rebuild succeeded without any additional code changes.

Result bundle: `/tmp/YamiboX-v030-binding-tests.xcresult`.

## Final repair

Commit `ac13b0e8974dbbcfda93bde6c867f5f6e2cccb84` is pushed to `main`. Its production source diff against the original release commit exactly matches the successful full-project candidate diff.

The version tag has not been moved again and no release has been published. The automatic Swift CI run is https://github.com/Arkalin/YamiboX/actions/runs/33287617399 (pending).

## Unrelated CI test failures

After the compiler fix, the normal Swift workflow on `ac13b0e` builds successfully but its full test phase fails twice, identically, on:

- `MineWebLoginSessionMonitorTests.testAuthenticatedWebSessionCompletesMonitoring()`
- `standardForumThemeUsesOnlyNeutralAccentColors()` plus the parameterized `forumTextRolesAreReadableOnForumSurfaces()` expectations

The production diff at that commit is one line in `SettingsForumView`, so it cannot alter web-session monitoring or forum color resolution. These are separate pre-existing or environment-sensitive failures that were previously masked because the whole build crashed before tests could run.

Run `33287617399` (rerun) repeats the same list. The diagnostic job captures their full assertion output on the same Xcode 26.6 runner.
