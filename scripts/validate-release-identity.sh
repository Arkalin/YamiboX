#!/bin/bash
set -euo pipefail

project_path="${PROJECT_PATH:-YamiboX.xcodeproj}"
scheme="${SCHEME:-YamiboX}"
configuration="${CONFIGURATION:-Release}"
target="${TARGET:-YamiboX}"
destination="${DESTINATION:-generic/platform=iOS}"
event_name="${RELEASE_EVENT:-${GITHUB_EVENT_NAME:-}}"
workflow_ref="${RELEASE_REF:-${GITHUB_REF:-}}"
workflow_sha="${RELEASE_SHA:-${GITHUB_SHA:-}}"
manual_tag="${RELEASE_TAG_INPUT:-}"

fail() {
    printf 'Release identity validation failed: %s\n' "$1" >&2
    exit 1
}

case "$event_name" in
    push)
        case "$workflow_ref" in
            refs/tags/*)
                release_tag="${workflow_ref#refs/tags/}"
                ;;
            *)
                fail "push workflow was not triggered by a tag ref: ${workflow_ref:-<empty>}"
                ;;
        esac
        [[ -n "$workflow_sha" ]] || fail 'the push event did not provide a triggering revision'
        ;;
    workflow_dispatch)
        release_tag="$manual_tag"
        [[ -n "$release_tag" ]] || fail 'manual dispatch requires the release_tag input'
        ;;
    *)
        fail "unsupported event: ${event_name:-<empty>}"
        ;;
esac

git check-ref-format "refs/tags/${release_tag}" >/dev/null || fail "invalid release tag: ${release_tag}"

# Resolve the same target/configuration that the archive command will use; do
# not infer the version from an arbitrary textual occurrence in project.pbxproj.
settings_json="$(
    xcodebuild \
        -project "$project_path" \
        -scheme "$scheme" \
        -configuration "$configuration" \
        -destination "$destination" \
        -showBuildSettings \
        -json
)"

version="$(
    printf '%s\n' "$settings_json" | TARGET_NAME="$target" python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
target_name = os.environ["TARGET_NAME"]
selected = [entry.get("buildSettings", {}).get("MARKETING_VERSION")
            for entry in data if entry.get("target") == target_name]
versions = {value for value in selected if isinstance(value, str) and value}

if not selected:
    raise SystemExit(f"MARKETING_VERSION was not resolved for target {target_name}")
if len(versions) != 1 or any(not isinstance(value, str) or not value for value in selected):
    raise SystemExit(f"MARKETING_VERSION was ambiguous for target {target_name}: {selected!r}")

version = next(iter(versions))
if any(character.isspace() for character in version):
    raise SystemExit(f"MARKETING_VERSION contains whitespace: {version!r}")
print(version)
'
)"

[[ -n "$version" ]] || fail 'the Release build settings returned an empty MARKETING_VERSION'
expected_tag="v${version}"
[[ "$release_tag" == "$expected_tag" ]] || fail "tag ${release_tag} does not match Release MARKETING_VERSION ${version} (expected ${expected_tag})"

tag_revision="$(git rev-parse --verify --quiet "refs/tags/${release_tag}^{commit}" 2>/dev/null)" \
    || fail "release tag does not exist locally: ${release_tag}"
checked_out_revision="$(git rev-parse --verify HEAD)" \
    || fail 'the checked-out revision could not be resolved'
[[ "$checked_out_revision" == "$tag_revision" ]] || fail "checked-out revision ${checked_out_revision} is not the revision tagged by ${release_tag} (${tag_revision})"

if [[ "$event_name" == push ]]; then
    triggering_revision="$(git rev-parse --verify --quiet "${workflow_sha}^{commit}" 2>/dev/null)" \
        || fail "the triggering revision is not available locally: ${workflow_sha}"
    [[ "$triggering_revision" == "$tag_revision" ]] || fail "triggering revision ${triggering_revision} is not the revision tagged by ${release_tag} (${tag_revision})"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        printf 'version=%s\n' "$version"
        printf 'tag=%s\n' "$release_tag"
        printf 'revision=%s\n' "$checked_out_revision"
    } >> "$GITHUB_OUTPUT"
fi

printf 'Validated release identity: tag=%s version=%s revision=%s\n' \
    "$release_tag" "$version" "$checked_out_revision"
