# YamiboX Agent Guidelines

## Project and Module Boundaries

- YamiboX is a Swift 6.2+ application targeting iOS 18+.
- `Sources/YamiboXCore` owns data models, application workflows, networking, and persistence.
- `Sources/YamiboXUI` owns the user interface and platform-specific implementations.
- `Sources/YamiboXTestSupport` contains test utilities shared across test targets.
- Treat `Package.swift` as the source of truth for package dependencies and target configuration.

## Testing

- Run tests using the `YamiboX` scheme and `YamiboXTests` test plan on an available local iOS simulator.
- Every `xcodebuild test` invocation must include `-collect-test-diagnostics never` to avoid expensive diagnostic collection.
- Do not use the old project's `swift test` workflow as a substitute for complete project validation.
- For narrow changes, start with relevant tests. Expand coverage for changes that affect shared behavior or multiple modules, and clearly report anything not verified.
- Use `.github/workflows/swift.yml` as the reference for the build and test entry points.

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
