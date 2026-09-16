# YamiboX Agent Guidelines

## Project and Module Boundaries

- YamiboX is a Swift 6.2+ application targeting iOS 18+.
- `Sources/YamiboXCore` owns data models, application workflows, networking, and persistence.
- `Sources/YamiboXUI` owns the user interface and platform-specific implementations.
- Treat `Package.swift` as the source of truth for package dependencies and target configuration.

## Testing

- Do not create any unit tests, unit test files, or unit test targets without explicit user approval. General implementation requests do not constitute approval. This restriction takes precedence over the test coverage guidance below.
- Match validation to the change: inspect documentation-only or reversible low-impact edits; run relevant existing tests for behavior changes; broaden checks for shared behavior or cross-module contracts. Do not expand or repeat passing checks without new changes, failures, or unresolved doubts.
- Running existing local tests does not require separate confirmation at each step, subject to tool permissions. If new unit tests are warranted, request approval for those tests while continuing other authorized implementation and validation.
- UI automation tests and their dedicated host have been removed. Validate builds using the `YamiboX` scheme on an available iOS simulator; do not substitute the old project's `swift test` workflow.
- Consult `.github/workflows/swift.yml` when build entry points need clarification.

Select an available simulator with `xcrun simctl list devices available`, then replace `<SIMULATOR_UDID>` below with its identifier:

```sh
xcodebuild build \
  -project YamiboX.xcodeproj \
  -scheme YamiboX \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  CODE_SIGNING_ALLOWED=NO
```

## Completion

- For implementation requests, finish the scoped change, perform necessary validation, and fix regressions introduced by the change before reporting back. Do not stop at the first implementation unless the user requested a review checkpoint.
- Use existing project patterns for routine choices. Ask only when missing information materially changes behavior, scope, or authorization.
- Report the result, checks performed, and anything blocked or unverified. Do not add unrelated cleanup or broader testing just to extend the task.

## Commit Conventions

- When the user requests a commit, commit on the current branch by default. Do not automatically create a new branch.
- Use a subject in the form `type: lowercase imperative description`, without a scope or trailing period.
- Commit only changes relevant to the current task; leave unrelated changes untouched.
- A request to commit does not authorize pushing, publishing a release, or closing an issue.
