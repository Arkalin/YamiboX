# YamiboX Agent Guidelines

## Project and Module Boundaries

- YamiboX is a Swift 6.2+ application targeting iOS 18+.
- `Sources/YamiboXCore` owns data models, application workflows, networking, and persistence.
- `Sources/YamiboXUI` owns the user interface and platform-specific implementations.
- Treat `Package.swift` as the source of truth for package dependencies and target configuration.

## Development Environment

- Unless the user explicitly specifies otherwise, use only the local test App (`YamiboX-Local` scheme, `Debug-Local` configuration, `com.arkalin.YamiboX.local`) on an iOS simulator for development, testing, and verification. Do not use the ordinary `YamiboX` Debug or Release App, or the production forum, for these activities without an explicit user request.
- Unless the user explicitly specifies another URL, use the existing local forum at `http://127.0.0.1:8088`, supplied on every launch through `--forum-base-url`. This is an agent workflow default, not a hardcoded App fallback. If it is unavailable, diagnose the local environment rather than switching to another site.
- For development, testing, and verification, agents may freely create, modify, delete, or reset local test-environment data, including forum accounts, posts, attachments, fixtures, and test App data, without requesting additional user approval. This authorization is limited to the local test environment; it does not cover production, remote environments, or unrelated user data. Follow any narrower constraints explicitly given by the user for a task.
- Consult [Test App Launch Arguments](docs/tests/launch-arguments.md) before launching the App for testing or verification. Keep parameter syntax, page navigation targets, and launch examples in that document rather than duplicating them here.

## Testing

- Do not create any unit tests, unit test files, or unit test targets without explicit user approval. General implementation requests do not constitute approval. This restriction takes precedence over the test coverage guidance below.
- Match validation to the change: inspect documentation-only or reversible low-impact edits; run relevant existing tests for behavior changes; broaden checks for shared behavior or cross-module contracts. Do not expand or repeat passing checks without new changes, failures, or unresolved doubts.
- Running existing local tests does not require separate confirmation at each step, subject to tool permissions. If new unit tests are warranted, request approval for those tests while continuing other authorized implementation and validation.
- UI automation tests and their dedicated host have been removed. Unless the user explicitly specifies otherwise, validate builds using the `YamiboX-Local` scheme on an available iOS simulator; do not substitute the old project's `swift test` workflow.
- Consult `.github/workflows/swift.yml` when build entry points need clarification.

Select an available simulator with `xcrun simctl list devices available`, then replace `<SIMULATOR_UDID>` below with its identifier:

```sh
xcodebuild build \
  -project YamiboX.xcodeproj \
  -scheme YamiboX-Local \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>'
```

Keep signing enabled for installed simulator builds so Keychain access works. `CODE_SIGNING_ALLOWED=NO` is acceptable only for compile-only checks; do not install those artifacts for interaction verification.

## Completion

- For implementation requests, finish the scoped change, perform necessary validation, and fix regressions introduced by the change before reporting back. Do not stop at the first implementation unless the user requested a review checkpoint.
- Use existing project patterns for routine choices. Ask only when missing information materially changes behavior, scope, or authorization.
- Report the result, checks performed, and anything blocked or unverified. Do not add unrelated cleanup or broader testing just to extend the task.

## Commit Conventions

- When the user requests a commit, commit on the current branch by default. Do not automatically create a new branch.
- Use a subject in the form `type: lowercase imperative description`, without a scope or trailing period.
- Commit only changes relevant to the current task; leave unrelated changes untouched.
- A request to commit does not authorize pushing, publishing a release, or closing an issue.
