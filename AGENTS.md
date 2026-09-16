# YamiboX Agent Guidelines

## Project and Module Boundaries

- YamiboX is a Swift 6.2+ application targeting iOS 18+.
- `Sources/YamiboXCore` owns data models, application workflows, networking, and persistence.
- `Sources/YamiboXUI` owns the user interface and platform-specific implementations.
- Treat `Package.swift` as the source of truth for package dependencies and target configuration.

## Testing

- Do not create any unit tests, unit test files, or unit test targets without explicit user approval. General implementation requests do not constitute approval. This restriction takes precedence over the test coverage guidance below.
- Run tests using the `YamiboX` scheme and `YamiboXTests` test plan on an available local iOS simulator.
- Every `xcodebuild test` invocation must include `-collect-test-diagnostics never` to avoid expensive diagnostic collection.
- Do not use the old project's `swift test` workflow as a substitute for complete project validation.
- For narrow changes, start with relevant tests. Expand coverage for changes that affect shared behavior or multiple modules, and clearly report anything not verified.
- Use `.github/workflows/swift.yml` as the reference for the build and test entry points.
- Do not force tests for reversible, low-impact changes. When core logic, edge cases, or uncertainty warrants new unit tests, obtain explicit user approval before creating them.
- Run tests proportionate to the change and complete the necessary checks. After those pass, expand or repeat testing only when there are new changes, new failures, or unresolved doubts; otherwise, continue to complete the task.

Select an available simulator with `xcrun simctl list devices available`, then replace `<SIMULATOR_UDID>` below with its identifier:

```sh
xcodebuild test \
  -project YamiboX.xcodeproj \
  -scheme YamiboX \
  -testPlan YamiboXTests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO
```

## Commit Conventions

- When the user requests a commit, commit on the current branch by default. Do not automatically create a new branch.
- Use a subject in the form `type: lowercase imperative description`, without a scope or trailing period.
- Commit only changes relevant to the current task; leave unrelated changes untouched.
- A request to commit does not authorize pushing, publishing a release, or closing an issue.
