#!/bin/bash
# Release the TempTalk fork of the LiveKit Swift SDK (difftim/client-sdk-swift):
# build LiveKit.xcframework, push main to chative and self-pri, tag LiveKitSDK.version
# (no "v", lightweight, chative only), publish a GitHub Release with Chinese notes, then
# publish the xcframework to the private distribution repo (scripts/tt-publish-xcframework.sh).
#
#   bash scripts/tt-release.sh <changes.md>
#
# Bump LiveKitSDK.version ("[chore][sdk] bump version to X") and commit before running.
# It pushes and publishes without asking: get the go-ahead first. The public distribution
# repo is never touched here; sync it by hand with scripts/tt-sync-public.sh.
# TT_RELEASE_DRY_RUN=1 only builds and writes the distribution files to a temp dir.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITHUB_REPO="difftim/client-sdk-swift"
DIST_REPO="difftim/client-sdk-swift-xcframework"
VERSION_FILE="$ROOT_DIR/Sources/LiveKit/LiveKit.swift"
DRY_RUN="${TT_RELEASE_DRY_RUN:-0}"

die() { echo "Error: $*" >&2; exit 1; }
sdk_version() { sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' "$VERSION_FILE" | head -1; }
tt_xcframework() { xcrun swift run --package-path "$ROOT_DIR/scripts/tt-xcframework" -c release tt-xcframework "$@"; }

write_notes() {
    cat "$CHANGES_FILE"
    echo ""
    echo "## 接入"
    echo '```swift'
    echo ".package(url: \"https://github.com/$DIST_REPO\", exact: \"$VERSION\")"
    echo '```'
    echo ""
    echo "依赖分发仓里的 LiveKit.xcframework；私有仓需要在 \`~/.netrc\` 配置 \`api.github.com\` 的 token。"
    if [ -n "${PREV_TAG:-}" ]; then
        echo ""
        echo "**完整对比**：https://github.com/$GITHUB_REPO/compare/$PREV_TAG...$VERSION"
    fi
}

if [ $# -ne 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 <changes.md>"
    echo ""
    echo "Current LiveKitSDK.version: $(sdk_version)"
    echo "changes.md holds the \"## 变更\" section (Chinese, one [feat]/[fix]/[chore] item per line)."
    echo "The release notes add the SPM snippet and the compare link to the previous tag."
    exit 1
fi
CHANGES_FILE="$1"
[ -f "$CHANGES_FILE" ] || die "Changes file not found: $CHANGES_FILE"
grep -q '^## 变更' "$CHANGES_FILE" || die "$CHANGES_FILE must contain a \"## 变更\" section."
CHANGES_FILE="$(cd "$(dirname "$CHANGES_FILE")" && pwd)/$(basename "$CHANGES_FILE")"
cd "$ROOT_DIR"

if [ "$DRY_RUN" = "1" ]; then
    VERSION=$(sdk_version)
    NOTES_FILE=$(mktemp)
    write_notes > "$NOTES_FILE"
    echo "Dry run for $VERSION: no git, gh or network writes. Release notes: $NOTES_FILE"
    TT_RELEASE_DRY_RUN=1 bash "$ROOT_DIR/scripts/tt-publish-xcframework.sh" "$VERSION" "$NOTES_FILE"
    exit 0
fi

# ── Preflight ────────────────────────────────────────────────────────
# The local branch is usually named chative/main itself, so compare full ref names.
[ "$(git rev-parse --symbolic-full-name '@{u}' 2>/dev/null)" = "refs/remotes/chative/main" ] \
    || die "The current branch must track chative/main."
git diff --quiet && git diff --cached --quiet || die "Uncommitted changes."
gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"

git pull --ff-only chative main
git fetch --tags chative
VERSION=$(sdk_version)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "Cannot read LiveKitSDK.version from $VERSION_FILE (got '$VERSION')."
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null \
    && die "Tag $VERSION already exists. Bump LiveKitSDK.version first."
git ls-remote --exit-code --tags chative "$VERSION" >/dev/null && die "chative already has tag $VERSION."
gh release view "$VERSION" -R "$GITHUB_REPO" >/dev/null 2>&1 && die "Release $VERSION already exists on $GITHUB_REPO."
bash "$ROOT_DIR/scripts/tt-publish-xcframework.sh" --check "$VERSION"
PREV_TAG=$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)
COMMIT=$(git rev-parse HEAD)

echo "Version: $VERSION (previous tag: ${PREV_TAG:-none})"
echo "Commit:  $(git log -1 --format='%h %s')"

# ── Build first: a failed build must not leave a pushed tag behind ──
OUT_DIR="$ROOT_DIR/.build/tt-xcframework/$VERSION"
tt_xcframework build --repo "$ROOT_DIR" --output "$OUT_DIR"

# ── Push main to both remotes, then the tag to chative only ─────────
git push chative HEAD:main
git push self-pri HEAD:main
git tag "$VERSION" "$COMMIT"
git push chative "refs/tags/$VERSION"

# ── GitHub Release ───────────────────────────────────────────────────
NOTES_FILE=$(mktemp)
write_notes > "$NOTES_FILE"
gh release create "$VERSION" -R "$GITHUB_REPO" --verify-tag --title "$VERSION" --notes-file "$NOTES_FILE"

# ── Verify ───────────────────────────────────────────────────────────
git fetch chative
git fetch self-pri
[ "$(git rev-parse "refs/remotes/chative/main")" = "$COMMIT" ] || die "chative/main is not at $COMMIT."
[ "$(git rev-parse "refs/remotes/self-pri/main")" = "$COMMIT" ] || die "self-pri/main is not at $COMMIT."
[ "$(git ls-remote --tags chative "refs/tags/$VERSION" | cut -f1)" = "$COMMIT" ] || die "chative tag $VERSION does not point at $COMMIT."
STATE=$(gh release view "$VERSION" -R "$GITHUB_REPO" --json tagName,name,isDraft,isPrerelease \
    -q '"\(.tagName)|\(.name)|\(.isDraft)|\(.isPrerelease)"')
[ "$STATE" = "$VERSION|$VERSION|false|false" ] || die "Unexpected release state: $STATE"

echo "Released $VERSION: chative and self-pri main at $(git rev-parse --short "$COMMIT"), tag on chative, GitHub Release published."

# ── Private distribution repo ────────────────────────────────────────
bash "$ROOT_DIR/scripts/tt-publish-xcframework.sh" "$VERSION" "$NOTES_FILE" "$OUT_DIR"

echo "============================"
echo "Released $VERSION: source on $GITHUB_REPO, LiveKit.xcframework on $DIST_REPO. Sync the public repo with scripts/tt-sync-public.sh when you choose."
echo "============================"
