#!/bin/bash
# Publish one LiveKitWebRTC.xcframework zip to the private WebRTC distribution repo
# (difftim/webrtc-xcframework): a draft Release with the zip, a Package.swift whose LiveKitWebRTC
# target downloads from the api.github.com asset URL, a commit + tag on the distribution repo, then
# publish and download the zip the way SwiftPM does (~/.netrc) to check the checksum.
#
#   bash scripts/tt-publish-webrtc.sh <version> <LiveKitWebRTC.xcframework.zip>
#
# The zip is published as is; its SHA-256 goes into Package.swift. It pushes and publishes without
# asking. TT_RELEASE_DRY_RUN=1 writes the distribution files with asset id 0 to a temp dir.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_REPO="difftim/webrtc-xcframework"
ZIP_NAME="LiveKitWebRTC.xcframework.zip"
DRY_RUN="${TT_RELEASE_DRY_RUN:-0}"

die() { echo "Error: $*" >&2; exit 1; }
tt_xcframework() { xcrun swift run --package-path "$ROOT_DIR/scripts/tt-xcframework" -c release tt-xcframework "$@"; }
checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ $# -ne 2 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 <version> <$ZIP_NAME>"
    exit 1
fi
VERSION=$1
ZIP=$2
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid version: $VERSION"
[ -f "$ZIP" ] || die "Zip not found: $ZIP"
[ "$(basename "$ZIP")" = "$ZIP_NAME" ] || die "The zip must be named $ZIP_NAME (SwiftPM shows the asset name)."
CHECKSUM=$(checksum "$ZIP")

# Package.swift, README and LICENSE: what each distribution tag holds.
write_dist_files() {
    local dir=$1 asset_url=$2
    tt_xcframework webrtc-manifest --url "$asset_url" --checksum "$CHECKSUM" --output "$dir/Package.swift"
    cp "$ROOT_DIR/scripts/webrtc-dist/README.md" "$ROOT_DIR/scripts/webrtc-dist/LICENSE" "$dir/"
}

if [ "$DRY_RUN" = "1" ]; then
    DRY_DIR=$(mktemp -d)
    write_dist_files "$DRY_DIR" "https://api.github.com/repos/$DIST_REPO/releases/assets/0.zip"
    echo "Dry run: nothing was pushed. Distribution files for $VERSION (checksum $CHECKSUM) are in $DRY_DIR"
    exit 0
fi

# ── Preflight ────────────────────────────────────────────────────────
grep -qs 'machine api.github.com' "$HOME/.netrc" \
    || die "~/.netrc has no 'machine api.github.com' entry; it is needed to check the private download."
gh repo view "$DIST_REPO" >/dev/null 2>&1 || die "Cannot read $DIST_REPO with the current gh login."
if gh release view "$VERSION" -R "$DIST_REPO" >/dev/null 2>&1; then
    die "Release $VERSION already exists on $DIST_REPO (an interrupted run leaves a draft; follow the recovery steps it printed)."
fi
if gh api "repos/$DIST_REPO/git/ref/tags/$VERSION" >/dev/null 2>&1; then
    die "$DIST_REPO already has tag $VERSION."
fi

# ── Draft Release with the zip; the asset id goes into Package.swift ─
NOTES_FILE=$(mktemp)
printf 'LiveKitWebRTC %s\n\nSHA-256: `%s`\n' "$VERSION" "$CHECKSUM" > "$NOTES_FILE"
gh release create "$VERSION" "$ZIP" -R "$DIST_REPO" --draft --title "$VERSION" --notes-file "$NOTES_FILE"

on_failure() {
    local status=$?
    [ "$status" -eq 0 ] && return
    echo "" >&2
    echo "Publishing to $DIST_REPO was interrupted after the draft Release $VERSION was created." >&2
    echo "  Check:  gh release view $VERSION -R $DIST_REPO" >&2
    echo "  If $DIST_REPO main already has \"[chore][release] LiveKitWebRTC $VERSION\":" >&2
    echo "          gh release edit $VERSION -R $DIST_REPO --target <that commit> --draft=false" >&2
    echo "  Otherwise delete the draft and rerun:" >&2
    echo "          gh release delete $VERSION -R $DIST_REPO --yes && bash scripts/tt-publish-webrtc.sh $VERSION <zip>" >&2
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
WORK=$(mktemp -d)
DIST_DIR="$WORK/dist"
gh repo clone "$DIST_REPO" "$DIST_DIR" -- -q
write_dist_files "$DIST_DIR" "$ASSET_URL"
git -C "$DIST_DIR" add -A
git -C "$DIST_DIR" commit -q -m "[chore][release] LiveKitWebRTC $VERSION"
git -C "$DIST_DIR" push -q origin HEAD:main
DIST_COMMIT=$(git -C "$DIST_DIR" rev-parse HEAD)

# Publishing creates the tag on DIST_COMMIT, so the tag and the zip become visible together.
gh release edit "$VERSION" -R "$DIST_REPO" --target "$DIST_COMMIT" --draft=false
trap - EXIT

# ── Verify ───────────────────────────────────────────────────────────
git -C "$DIST_DIR" fetch -q origin "refs/tags/$VERSION:refs/tags/$VERSION"
[ "$(git -C "$DIST_DIR" rev-parse "$VERSION^{commit}")" = "$DIST_COMMIT" ] || die "$DIST_REPO tag $VERSION does not point at $DIST_COMMIT."
# The Release is published now; a failed download is most likely the network, so do not delete it.
curl --netrc -fsSL --retry 3 --retry-all-errors -H 'Accept: application/octet-stream' \
    -o "$WORK/$ZIP_NAME" "$ASSET_URL" \
    || die "Release $VERSION is published, but downloading $ASSET_URL with ~/.netrc failed; retry and compare shasum -a 256 with $CHECKSUM."
[ "$(checksum "$WORK/$ZIP_NAME")" = "$CHECKSUM" ] || die "The zip downloaded from $ASSET_URL does not match checksum $CHECKSUM."
rm -rf "$WORK" "$NOTES_FILE"

echo "Published LiveKitWebRTC $VERSION to $DIST_REPO: tag at ${DIST_COMMIT:0:7}, checksum $CHECKSUM verified via ~/.netrc."
