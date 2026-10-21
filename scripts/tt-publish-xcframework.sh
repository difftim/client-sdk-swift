#!/bin/bash
# Publish LiveKit.xcframework for one fork release to the private distribution repo
# (difftim/client-sdk-swift-xcframework): a draft Release with the zip, a Package.swift whose
# LiveKit target downloads from the api.github.com asset URL, a commit + tag on the distribution
# repo, then publish and download the zip the way SwiftPM does (~/.netrc) to check the checksum.
#
#   bash scripts/tt-publish-xcframework.sh --check <version>
#   bash scripts/tt-publish-xcframework.sh <version> <notes.md> [<build output dir>]
#
# tt-release.sh runs it after tagging the source. Run it by hand only to resume an interrupted
# release: without a build output dir it builds HEAD, which must be the <version> tag.
# TT_RELEASE_DRY_RUN=1 builds if needed and writes Package.swift with asset id 0 to a temp dir.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_REPO="difftim/client-sdk-swift-xcframework"
ZIP_NAME="LiveKit.xcframework.zip"
DRY_RUN="${TT_RELEASE_DRY_RUN:-0}"

die() { echo "Error: $*" >&2; exit 1; }
tt_xcframework() { xcrun swift run --package-path "$ROOT_DIR/scripts/tt-xcframework" -c release tt-xcframework "$@"; }
checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }
info_field() { plutil -extract "$2" raw -o - "$1"; }

dist_preflight() {
    local version=$1
    grep -qs 'machine api.github.com' "$HOME/.netrc" \
        || die "~/.netrc has no 'machine api.github.com' entry; it is needed to check the private download."
    gh repo view "$DIST_REPO" >/dev/null 2>&1 || die "Cannot read $DIST_REPO with the current gh login."
    if gh release view "$version" -R "$DIST_REPO" >/dev/null 2>&1; then
        die "Release $version already exists on $DIST_REPO (an interrupted run leaves a draft; follow the recovery steps it printed)."
    fi
    if gh api "repos/$DIST_REPO/git/ref/tags/$version" >/dev/null 2>&1; then
        die "$DIST_REPO already has tag $version."
    fi
}

if [ "${1:-}" = "--check" ]; then
    [ $# -eq 2 ] || die "Usage: $0 --check <version>"
    dist_preflight "$2"
    exit 0
fi

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 --check <version>"
    echo "       $0 <version> <notes.md> [<build output dir>]"
    exit 1
fi
VERSION=$1
NOTES_FILE=$2
OUT_DIR=${3:-"$ROOT_DIR/.build/tt-xcframework/$VERSION"}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "Invalid version: $VERSION"
[ -f "$NOTES_FILE" ] || die "Notes file not found: $NOTES_FILE"

if [ "$DRY_RUN" != "1" ]; then
    dist_preflight "$VERSION"
    [ "$(git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$VERSION^{commit}" || true)" = "$(git -C "$ROOT_DIR" rev-parse HEAD)" ] \
        || die "HEAD is not the $VERSION tag; check out the tagged commit before publishing it."
fi

# ── Build (skipped when tt-release.sh already built this version) ────
if [ ! -f "$OUT_DIR/$ZIP_NAME" ] || [ ! -f "$OUT_DIR/build-info.json" ]; then
    tt_xcframework build --repo "$ROOT_DIR" --output "$OUT_DIR"
fi
[ "$(info_field "$OUT_DIR/build-info.json" version)" = "$VERSION" ] \
    || die "$OUT_DIR was built for $(info_field "$OUT_DIR/build-info.json" version), not $VERSION."
CHECKSUM=$(info_field "$OUT_DIR/build-info.json" checksum)
[ "$(checksum "$OUT_DIR/$ZIP_NAME")" = "$CHECKSUM" ] || die "$OUT_DIR/$ZIP_NAME does not match build-info.json."

# Package.swift, build-info.json, README, LICENSE and NOTICE: what each distribution tag holds.
write_dist_files() {
    local dir=$1 asset_url=$2
    tt_xcframework manifest --info "$OUT_DIR/build-info.json" --livekit-url "$asset_url" --output "$dir/Package.swift"
    cp "$OUT_DIR/build-info.json" "$dir/build-info.json"
    cp "$ROOT_DIR/scripts/xcframework-dist/README.md" "$dir/README.md"
    cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/NOTICE" "$dir/"
}

if [ "$DRY_RUN" = "1" ]; then
    DRY_DIR=$(mktemp -d)
    write_dist_files "$DRY_DIR" "https://api.github.com/repos/$DIST_REPO/releases/assets/0.zip"
    echo "Dry run: nothing was pushed. Distribution files for $VERSION are in $DRY_DIR"
    exit 0
fi

# ── Draft Release with the zip; the asset id goes into Package.swift ─
gh release create "$VERSION" "$OUT_DIR/$ZIP_NAME" -R "$DIST_REPO" --draft --title "$VERSION" --notes-file "$NOTES_FILE"

on_failure() {
    local status=$?
    [ "$status" -eq 0 ] && return
    echo "" >&2
    echo "Publishing to $DIST_REPO was interrupted after the draft Release $VERSION was created." >&2
    echo "  Check:  gh release view $VERSION -R $DIST_REPO" >&2
    echo "  If $DIST_REPO main already has \"[chore][release] LiveKit $VERSION\":" >&2
    echo "          gh release edit $VERSION -R $DIST_REPO --target <that commit> --draft=false" >&2
    echo "  Otherwise delete the draft and rerun:" >&2
    echo "          gh release delete $VERSION -R $DIST_REPO --yes && bash scripts/tt-publish-xcframework.sh $VERSION <notes.md>" >&2
    exit "$status"
}
trap on_failure EXIT

# Drafts are not reachable by tag, so look the asset up in the release list.
ASSET_ID=$(gh api "repos/$DIST_REPO/releases?per_page=30" \
    --jq ".[] | select(.tag_name == \"$VERSION\" and .draft) | .assets[] | select(.name == \"$ZIP_NAME\") | .id")
[[ "$ASSET_ID" =~ ^[0-9]+$ ]] || die "Cannot find the uploaded $ZIP_NAME on draft $VERSION (got '$ASSET_ID')."
# SwiftPM only downloads private Release assets from this URL, and only with the .zip suffix.
ASSET_URL="https://api.github.com/repos/$DIST_REPO/releases/assets/$ASSET_ID.zip"

# ── Commit the distribution files, then publish the draft on that commit ─
DIST_DIR="$(mktemp -d)/dist"
gh repo clone "$DIST_REPO" "$DIST_DIR" -- -q
write_dist_files "$DIST_DIR" "$ASSET_URL"
git -C "$DIST_DIR" add -A
git -C "$DIST_DIR" commit -q -m "[chore][release] LiveKit $VERSION"
git -C "$DIST_DIR" push -q origin HEAD:main
DIST_COMMIT=$(git -C "$DIST_DIR" rev-parse HEAD)

# Publishing creates the tag on DIST_COMMIT, so the tag and the zip become visible together.
gh release edit "$VERSION" -R "$DIST_REPO" --target "$DIST_COMMIT" --draft=false
trap - EXIT

# ── Verify ───────────────────────────────────────────────────────────
git -C "$DIST_DIR" fetch -q origin "refs/tags/$VERSION:refs/tags/$VERSION"
[ "$(git -C "$DIST_DIR" rev-parse "$VERSION^{commit}")" = "$DIST_COMMIT" ] || die "$DIST_REPO tag $VERSION does not point at $DIST_COMMIT."
# The Release is published now; a failed download is most likely the network, so do not delete it.
VERIFY_DIR=$(mktemp -d)
curl --netrc -fsSL --retry 3 --retry-all-errors -H 'Accept: application/octet-stream' \
    -o "$VERIFY_DIR/$ZIP_NAME" "$ASSET_URL" \
    || die "Release $VERSION is published, but downloading $ASSET_URL with ~/.netrc failed; retry and compare shasum -a 256 with $CHECKSUM."
[ "$(checksum "$VERIFY_DIR/$ZIP_NAME")" = "$CHECKSUM" ] || die "The zip downloaded from $ASSET_URL does not match checksum $CHECKSUM."
rm -rf "$VERIFY_DIR"

echo "Published LiveKit $VERSION to $DIST_REPO: tag at $(git -C "$DIST_DIR" rev-parse --short HEAD), checksum $CHECKSUM verified via ~/.netrc."
