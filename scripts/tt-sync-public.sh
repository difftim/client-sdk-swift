#!/bin/bash
# Sync one released LiveKit.xcframework from the private distribution repo
# (difftim/client-sdk-swift-xcframework) to the public one (TempTalkOrg/client-sdk-swift-xcframework).
# The zip is copied byte for byte; only the LiveKit url in Package.swift changes.
#
#   bash scripts/tt-sync-public.sh <version>
#
# Run it only when you decide the open-source app gets <version>: it pushes and publishes
# without asking. Needs ~/.netrc for api.github.com to download the private zip.
# TT_SYNC_TAMPER=1 flips one byte of the downloaded zip, to test that the checksum check stops the sync.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIVATE_REPO="difftim/client-sdk-swift-xcframework"
PUBLIC_REPO="TempTalkOrg/client-sdk-swift-xcframework"
ZIP_NAME="LiveKit.xcframework.zip"

die() { echo "Error: $*" >&2; exit 1; }
tt_xcframework() { xcrun swift run --package-path "$ROOT_DIR/scripts/tt-xcframework" -c release tt-xcframework "$@"; }
checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }
info_field() { plutil -extract "$2" raw -o - "$1"; }
# url or checksum of the LiveKit binaryTarget in a Package.swift rendered by tt-xcframework.
livekit_target_field() {
    awk -v key="$2" 'prev ~ /\.binaryTarget\($/ && /name: "LiveKit",/ { found = 1 }
        found && $0 ~ key ": \"" { sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit }
        { prev = $0 }' "$1"
}

if [ $# -ne 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi
VERSION=$1
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "Invalid version: $VERSION"

# ── Preflight ────────────────────────────────────────────────────────
gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"
gh api "repos/$PRIVATE_REPO/git/ref/tags/$VERSION" >/dev/null 2>&1 \
    || die "$PRIVATE_REPO has no tag $VERSION; release it with tt-release.sh first."
grep -qs 'machine api.github.com' "$HOME/.netrc" \
    || die "~/.netrc has no 'machine api.github.com' entry; it is needed to download the private zip."

# ── Download the private zip and check it against both records ──────
WORK=$(mktemp -d)
gh repo clone "$PRIVATE_REPO" "$WORK/private" -- -q --depth 1 --branch "$VERSION"
[ "$(info_field "$WORK/private/build-info.json" version)" = "$VERSION" ] \
    || die "$PRIVATE_REPO $VERSION has build-info.json for another version."
PRIVATE_URL=$(livekit_target_field "$WORK/private/Package.swift" url)
MANIFEST_CHECKSUM=$(livekit_target_field "$WORK/private/Package.swift" checksum)
INFO_CHECKSUM=$(info_field "$WORK/private/build-info.json" checksum)
[ -n "$PRIVATE_URL" ] && [ -n "$MANIFEST_CHECKSUM" ] || die "Cannot read the LiveKit target from $PRIVATE_REPO $VERSION Package.swift."

curl --netrc -fsSL --retry 3 --retry-all-errors -H 'Accept: application/octet-stream' \
    -o "$WORK/$ZIP_NAME" "$PRIVATE_URL" || die "Downloading $PRIVATE_URL with ~/.netrc failed."
if [ "${TT_SYNC_TAMPER:-0}" = "1" ]; then
    printf '\x00' | dd of="$WORK/$ZIP_NAME" bs=1 seek=100 count=1 conv=notrunc 2>/dev/null
fi
ZIP_CHECKSUM=$(checksum "$WORK/$ZIP_NAME")
if [ "$ZIP_CHECKSUM" != "$INFO_CHECKSUM" ] || [ "$ZIP_CHECKSUM" != "$MANIFEST_CHECKSUM" ]; then
    die "Checksum mismatch for $VERSION (zip $ZIP_CHECKSUM, build-info.json $INFO_CHECKSUM, Package.swift $MANIFEST_CHECKSUM); nothing was pushed."
fi

# ── Public repo preflight (after the private zip checks out) ────────
gh repo view "$PUBLIC_REPO" >/dev/null 2>&1 || die "Cannot read $PUBLIC_REPO with the current gh login."
if gh release view "$VERSION" -R "$PUBLIC_REPO" >/dev/null 2>&1; then
    die "Release $VERSION already exists on $PUBLIC_REPO."
fi
if gh api "repos/$PUBLIC_REPO/git/ref/tags/$VERSION" >/dev/null 2>&1; then
    die "$PUBLIC_REPO already has tag $VERSION."
fi

# ── Commit the public files, then publish the same zip ──────────────
PUBLIC_URL="https://github.com/$PUBLIC_REPO/releases/download/$VERSION/$ZIP_NAME"
gh repo clone "$PUBLIC_REPO" "$WORK/public" -- -q
tt_xcframework manifest --info "$WORK/private/build-info.json" --livekit-url "$PUBLIC_URL" --output "$WORK/public/Package.swift"
for f in build-info.json README.md LICENSE NOTICE; do cp "$WORK/private/$f" "$WORK/public/$f"; done
git -C "$WORK/public" add -A
git -C "$WORK/public" commit -q -m "[chore][release] LiveKit $VERSION"
git -C "$WORK/public" push -q origin HEAD:main
COMMIT=$(git -C "$WORK/public" rev-parse HEAD)

# Release notes: the private ones, pointed at the public repo, without the private-only lines.
NOTES_FILE="$WORK/notes.md"
gh release view "$VERSION" -R "$PRIVATE_REPO" --json body -q .body \
    | sed -e "s#$PRIVATE_REPO#$PUBLIC_REPO#g" -e '/~\/\.netrc/d' -e '/完整对比/d' > "$NOTES_FILE"

on_failure() {
    local status=$?
    [ "$status" -eq 0 ] && return
    echo "" >&2
    echo "Sync interrupted: $PUBLIC_REPO main has \"[chore][release] LiveKit $VERSION\" ($COMMIT), but the Release is not published." >&2
    echo "  Check:  gh release view $VERSION -R $PUBLIC_REPO" >&2
    echo "  If the draft has the zip: gh release edit $VERSION -R $PUBLIC_REPO --draft=false" >&2
    echo "  Otherwise: gh release delete $VERSION -R $PUBLIC_REPO --yes, then upload $ZIP_NAME from $PRIVATE_REPO $VERSION by hand:" >&2
    echo "          gh release create $VERSION <zip> -R $PUBLIC_REPO --draft --target $COMMIT --title $VERSION && gh release edit $VERSION -R $PUBLIC_REPO --draft=false" >&2
    exit "$status"
}
trap on_failure EXIT
# Publishing creates the tag on COMMIT, so the tag and the zip become visible together.
gh release create "$VERSION" "$WORK/$ZIP_NAME" -R "$PUBLIC_REPO" --draft --target "$COMMIT" --title "$VERSION" --notes-file "$NOTES_FILE"
gh release edit "$VERSION" -R "$PUBLIC_REPO" --draft=false
trap - EXIT

# ── Verify anonymously ──────────────────────────────────────────────
git -C "$WORK/public" fetch -q origin "refs/tags/$VERSION:refs/tags/$VERSION"
[ "$(git -C "$WORK/public" rev-parse "$VERSION^{commit}")" = "$COMMIT" ] || die "$PUBLIC_REPO tag $VERSION does not point at $COMMIT."
VERIFY_DIR=$(mktemp -d)
env -i HOME="$VERIFY_DIR" PATH="$PATH" curl -fsSL --retry 3 --retry-all-errors -o "$VERIFY_DIR/$ZIP_NAME" "$PUBLIC_URL" \
    || die "Release $VERSION is published, but the anonymous download of $PUBLIC_URL failed; retry and compare shasum -a 256 with $ZIP_CHECKSUM."
[ "$(checksum "$VERIFY_DIR/$ZIP_NAME")" = "$ZIP_CHECKSUM" ] || die "The zip downloaded from $PUBLIC_URL does not match $ZIP_CHECKSUM."
rm -rf "$VERIFY_DIR" "$WORK"

echo "Synced LiveKit $VERSION to $PUBLIC_REPO: tag at ${COMMIT:0:7}, anonymous download checksum $ZIP_CHECKSUM verified."
