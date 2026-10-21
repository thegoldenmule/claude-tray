#!/usr/bin/env bash
# Build, sign, notarize and publish a ClaudeTray release.
#
#   make release VERSION=1.2.3            # full release
#   make release VERSION=1.2.3 DRY_RUN=1  # signed DMG only; nothing committed or published
#
# Environment:
#   VERSION         required. X.Y.Z (a dry run also accepts X.Y.Z-suffix).
#   DRY_RUN=1       build a signed DMG, skip version commit/tag, notarization, push, publish.
#                   Falls back to an "Apple Development" identity if no Developer ID exists.
#   DEVELOPER_ID    signing identity (name or SHA-1). Default: first "Developer ID Application".
#   NOTARY_PROFILE  notarytool keychain profile. Default: claude-tray-notary.
#
# Build number (CFBundleVersion): the number of commits on main including the release
# commit (`git rev-list --count HEAD` + 1), bumped past the current value if that would
# not increase it. Monotonic as long as main's history is never rewritten.
#
# A failed run publishes nothing: the commit and tag are pushed only after notarization
# succeeds, and on failure before that the script deletes the tag and drops the release
# commit it created (only if HEAD and the tag still point at it).

set -euo pipefail

APP_NAME=ClaudeTray
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST=Resources/Info.plist
DIST_DIR=dist
PLISTBUDDY=/usr/libexec/PlistBuddy
CO_AUTHOR="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"

VERSION="${VERSION:-}"
DRY_RUN="${DRY_RUN:-}"
DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-tray-notary}"
case "$DRY_RUN" in 1|true|yes) DRY_RUN=1 ;; *) DRY_RUN=0 ;; esac

cd "$REPO_ROOT"

# ---------------------------------------------------------------- output helpers

if [[ -t 1 ]]; then
    BOLD=$'\e[1m' RED=$'\e[31m' YELLOW=$'\e[33m' GREEN=$'\e[32m' RESET=$'\e[0m'
else
    BOLD="" RED="" YELLOW="" GREEN="" RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %sok%s  %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '    %swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
skip() { printf '    %s[DRY RUN] SKIPPED:%s %s\n' "$YELLOW" "$RESET" "$*"; }
note() { printf '    %s[DRY RUN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

setup_instructions() {
    cat >&2 <<EOF

One-time setup for notarized releases:

  1. Create a "Developer ID Application" certificate (requires the Account Holder role):
     Xcode > Settings > Accounts > select your team > Manage Certificates > + >
     "Developer ID Application". Check it with:
         security find-identity -v -p codesigning

  2. Create an app-specific password for your Apple ID at https://account.apple.com >
     Sign-In and Security > App-Specific Passwords.

  3. Store notarization credentials in the keychain (prompts for that password):
         xcrun notarytool store-credentials $NOTARY_PROFILE \\
             --apple-id <your Apple ID email> --team-id <TEAM_ID>
     TEAM_ID is the 10-character ID in parentheses at the end of the identity name,
     e.g. "Developer ID Application: Your Name (TEAM_ID)".

Then re-run: make release VERSION=$VERSION
To test the pipeline without any of this: make release VERSION=$VERSION DRY_RUN=1
EOF
}

# ---------------------------------------------------------------- failure handling

PREV_SHA=""      # HEAD before the release commit
RELEASE_SHA=""   # the release commit this run created
TAG=""
TAG_CREATED=0
PUSHED=0
MOUNT_POINT=""

on_exit() {
    local rc=$?
    if [[ -n "$MOUNT_POINT" ]]; then
        hdiutil detach -quiet "$MOUNT_POINT" 2>/dev/null || true
    fi
    [[ $rc -eq 0 ]] && return

    if [[ $PUSHED -eq 1 ]]; then
        cat >&2 <<EOF

${RED}Release failed after $TAG was pushed.${RESET} The notarized DMG is in $DIST_DIR/.
Finish publishing by hand:
    gh release create $TAG $DMG_PATH $SUM_PATH --verify-tag --title "$APP_NAME $VERSION" \\
        --generate-notes --notes-file $NOTES_PATH
EOF
        return
    fi
    [[ -z "$RELEASE_SHA" ]] && return

    printf '\n%sRelease failed before anything was pushed; rolling back local changes.%s\n' "$RED" "$RESET" >&2
    if [[ $TAG_CREATED -eq 1 ]]; then
        if [[ "$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null)" == "$RELEASE_SHA" ]]; then
            git tag -d "$TAG" >/dev/null && info "deleted local tag $TAG" >&2
        else
            warn "tag $TAG no longer points at the release commit; left it alone"
        fi
    fi
    if [[ "$(git rev-parse HEAD)" == "$RELEASE_SHA" ]] \
        && git reset --quiet --keep "$PREV_SHA"; then
        info "dropped release commit ${RELEASE_SHA:0:7}; HEAD is back at ${PREV_SHA:0:7}" >&2
    else
        warn "could not drop the release commit automatically. To undo it:"
        printf '        git tag -d %s 2>/dev/null; git reset --keep %s\n' "$TAG" "$PREV_SHA" >&2
    fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- preflight

step "Preflight"
[[ $DRY_RUN -eq 1 ]] && info "${YELLOW}DRY RUN${RESET}: builds a signed DMG; no commit, tag, notarization, push or release."

[[ -n "$VERSION" ]] || die "VERSION is required, e.g.: make release VERSION=1.2.3"
if [[ $DRY_RUN -eq 1 ]]; then
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
        || die "VERSION '$VERSION' must look like 1.2.3 (dry runs also accept 1.2.3-test)"
else
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "VERSION '$VERSION' must be MAJOR.MINOR.PATCH, e.g. 1.2.3 (CFBundleShortVersionString allows only digits and dots)"
fi
TAG="v$VERSION"
ok "version $VERSION (tag $TAG)"

for tool in swift codesign hdiutil xcrun git gh shasum lipo spctl "$PLISTBUDDY"; do
    command -v "$tool" >/dev/null || die "required tool not found: $tool"
done

# Fatal for a real release; only a warning for a dry run.
check() {
    if [[ $DRY_RUN -eq 1 ]]; then warn "$1 (would stop a real release)"; else die "$1"; fi
}

if [[ -n "$(git status --porcelain)" ]]; then
    check "working tree is not clean; commit or stash your changes first (git status)"
else
    ok "working tree clean"
fi

BRANCH="$(git symbolic-ref --quiet --short HEAD || echo "(detached)")"
if [[ "$BRANCH" != main ]]; then
    check "on branch '$BRANCH'; releases are cut from main (git switch main)"
else
    ok "on main"
fi

if ! git fetch --quiet origin main; then
    check "could not fetch origin/main; check your network and remote"
elif [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    check "main is not in sync with origin/main (ahead $(git rev-list --count origin/main..HEAD), behind $(git rev-list --count HEAD..origin/main)); pull/push first"
else
    ok "in sync with origin/main"
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    check "tag $TAG already exists locally (git tag -d $TAG if it is stale)"
elif git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    check "tag $TAG already exists on origin; pick a new VERSION"
else
    ok "tag $TAG is unused (local and origin)"
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGN_IDENTITY=""
SIGN_LABEL=""
if [[ -n "$DEVELOPER_ID" ]]; then
    line="$(grep -F -- "$DEVELOPER_ID" <<<"$IDENTITIES" | head -n1 || true)"
    if [[ -z "$line" ]]; then
        check "DEVELOPER_ID '$DEVELOPER_ID' is not a valid codesigning identity in your keychain"
    elif [[ "$line" != *'"Developer ID Application'* && $DRY_RUN -eq 0 ]]; then
        die "DEVELOPER_ID '$DEVELOPER_ID' is not a \"Developer ID Application\" identity; notarization requires one"
    fi
    if [[ -n "$line" ]]; then
        SIGN_IDENTITY="$(awk '{print $2}' <<<"$line")"
        SIGN_LABEL="$(sed -E 's/^[^"]*"(.*)"$/\1/' <<<"$line")"
    fi
else
    line="$(grep -F '"Developer ID Application' <<<"$IDENTITIES" | head -n1 || true)"
    if [[ -n "$line" ]]; then
        SIGN_IDENTITY="$(awk '{print $2}' <<<"$line")"
        SIGN_LABEL="$(sed -E 's/^[^"]*"(.*)"$/\1/' <<<"$line")"
    elif [[ $DRY_RUN -eq 0 ]]; then
        printf '\n%serror:%s no "Developer ID Application" signing identity found in your keychain.\n' "$RED" "$RESET" >&2
        setup_instructions
        exit 1
    fi
fi
if [[ -z "$SIGN_IDENTITY" ]]; then   # dry run only
    warn "no Developer ID Application identity (would stop a real release); falling back for the dry run"
    line="$(grep -F '"Apple Development' <<<"$IDENTITIES" | head -n1 || true)"
    if [[ -n "$line" ]]; then
        SIGN_IDENTITY="$(awk '{print $2}' <<<"$line")"
        SIGN_LABEL="$(sed -E 's/^[^"]*"(.*)"$/\1/' <<<"$line")"
    else
        SIGN_IDENTITY="-"
        SIGN_LABEL="ad-hoc"
    fi
fi
ok "signing identity: $SIGN_LABEL ($SIGN_IDENTITY)"

notary_out="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1 >/dev/null)" && notary_rc=0 || notary_rc=$?
if [[ $notary_rc -eq 0 ]]; then
    ok "notarytool profile '$NOTARY_PROFILE'"
elif grep -q "No Keychain password item found" <<<"$notary_out"; then
    if [[ $DRY_RUN -eq 1 ]]; then
        warn "notarytool keychain profile '$NOTARY_PROFILE' not found (would stop a real release)"
    else
        printf '\n%serror:%s notarytool keychain profile "%s" not found.\n' "$RED" "$RESET" "$NOTARY_PROFILE" >&2
        setup_instructions
        exit 1
    fi
else
    check "notarytool could not use profile '$NOTARY_PROFILE': $(head -n3 <<<"$notary_out")"
fi

if gh auth status >/dev/null 2>&1; then
    ok "gh authenticated"
else
    check "gh is not authenticated; run: gh auth login"
fi

# ---------------------------------------------------------------- version

CURRENT_BUILD="$("$PLISTBUDDY" -c "Print :CFBundleVersion" "$INFO_PLIST")"
BUILD_NUMBER=$(( $(git rev-list --count HEAD) + 1 ))
if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] && (( BUILD_NUMBER <= CURRENT_BUILD )); then
    BUILD_NUMBER=$(( CURRENT_BUILD + 1 ))
fi

step "Version $VERSION (build $BUILD_NUMBER)"
mkdir -p "$DIST_DIR"
if [[ $DRY_RUN -eq 1 ]]; then
    # Stamp a copy so the bundle carries the version without touching the repo.
    BUNDLE_PLIST="$DIST_DIR/Info.plist"
    cp "$INFO_PLIST" "$BUNDLE_PLIST"
    "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$BUNDLE_PLIST"
    info "stamped a copy at $BUNDLE_PLIST"
    skip "commit of $INFO_PLIST and tag $TAG"
else
    BUNDLE_PLIST="$INFO_PLIST"
    "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
    PREV_SHA="$(git rev-parse HEAD)"
    git commit --quiet -m "Release $TAG" -m "$CO_AUTHOR" -- "$INFO_PLIST"
    RELEASE_SHA="$(git rev-parse HEAD)"
    git tag -a "$TAG" -m "$APP_NAME $VERSION"
    TAG_CREATED=1
    ok "committed ${RELEASE_SHA:0:7} \"Release $TAG\" and tagged $TAG (local only until notarized)"
fi

# ---------------------------------------------------------------- build + bundle + sign

STAGE_DIR="$DIST_DIR/$APP_NAME-$VERSION"   # becomes the DMG's root
APP_PATH="$STAGE_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
SUM_PATH="$DMG_PATH.sha256"
NOTES_PATH="$DIST_DIR/release-notes-$VERSION.md"
rm -rf "$STAGE_DIR" "$DMG_PATH" "$SUM_PATH"

TIMESTAMP_FLAG=--timestamp
[[ "$SIGN_IDENTITY" == "-" ]] && TIMESTAMP_FLAG=--timestamp=none

step "Build universal app bundle and sign (hardened runtime)"
make --no-print-directory app \
    BUILD_DIR="$STAGE_DIR" \
    ARCHS="arm64 x86_64" \
    INFO_PLIST="$BUNDLE_PLIST" \
    SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODESIGN_TIMESTAMP="$TIMESTAMP_FLAG"

ARCHS_FOUND="$(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")"
[[ "$ARCHS_FOUND" == *arm64* && "$ARCHS_FOUND" == *x86_64* ]] \
    || die "expected a universal binary, got architectures: $ARCHS_FOUND"
ok "architectures: $ARCHS_FOUND"

BUNDLE_VERSION="$("$PLISTBUDDY" -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || die "bundle version is $BUNDLE_VERSION, expected $VERSION"
ok "bundle version $BUNDLE_VERSION ($("$PLISTBUDDY" -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist"))"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvv "$APP_PATH" 2>&1 | grep -E '^(Authority|TeamIdentifier|Timestamp|CodeDirectory)' | sed 's/^/    /' || true

# ---------------------------------------------------------------- DMG

step "Create and sign $DMG_PATH"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE_DIR" -fs HFS+ -format UDZO -ov "$DMG_PATH"
codesign --force $TIMESTAMP_FLAG -s "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"
ok "signed $DMG_PATH"

# ---------------------------------------------------------------- notarize + staple

step "Notarize and staple"
if [[ $DRY_RUN -eq 1 ]]; then
    skip "xcrun notarytool submit $DMG_PATH --keychain-profile $NOTARY_PROFILE --wait"
    skip "xcrun stapler staple $DMG_PATH"
else
    SUBMIT_JSON="$DIST_DIR/notarize-$VERSION.json"
    info "submitting to Apple (usually a few minutes)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json >"$SUBMIT_JSON" || true
    SUBMISSION_ID="$(plutil -extract id raw -o - "$SUBMIT_JSON" 2>/dev/null || true)"
    STATUS="$(plutil -extract status raw -o - "$SUBMIT_JSON" 2>/dev/null || true)"
    info "submission ${SUBMISSION_ID:-?}: ${STATUS:-unknown}"
    if [[ "$STATUS" != Accepted ]]; then
        cat "$SUBMIT_JSON" >&2 || true
        if [[ -n "$SUBMISSION_ID" ]]; then
            printf '\nNotarization log:\n' >&2
            xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        die "notarization failed (status: ${STATUS:-unknown})"
    fi
    ok "notarization accepted"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    ok "ticket stapled to $DMG_PATH"
fi

# ---------------------------------------------------------------- verify

step "Verify DMG"
# Gatekeeper assessment. Expected to be rejected in a dry run (not notarized).
gatekeeper() {
    if "$@" 2>&1 | sed 's/^/    /'; [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        return 0
    elif [[ $DRY_RUN -eq 1 ]]; then
        note "expected rejection: dry-run builds are not notarized"
    else
        die "Gatekeeper rejected: $*"
    fi
}
gatekeeper spctl -a -t open --context context:primary-signature -v "$DMG_PATH"

TMP_ROOT="${TMPDIR:-/tmp}"
MOUNT_POINT="$(mktemp -d "${TMP_ROOT%/}/claudetray-dmg.XXXXXX")"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH"
[[ -d "$MOUNT_POINT/$APP_NAME.app" ]] || die "DMG does not contain $APP_NAME.app"
[[ -L "$MOUNT_POINT/Applications" && "$(readlink "$MOUNT_POINT/Applications")" == /Applications ]] \
    || die "DMG does not contain an Applications symlink"
ok "DMG contains $APP_NAME.app and Applications -> /Applications"
codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME.app"
ok "mounted app signature verifies"
gatekeeper spctl -a -vv "$MOUNT_POINT/$APP_NAME.app"
hdiutil detach -quiet "$MOUNT_POINT"
rmdir "$MOUNT_POINT" 2>/dev/null || true
MOUNT_POINT=""

(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" >"$(basename "$SUM_PATH")")
ok "sha256 $(awk '{print $1}' "$SUM_PATH")"

# ---------------------------------------------------------------- publish

cat >"$NOTES_PATH" <<EOF
## Install

1. Download \`$APP_NAME-$VERSION.dmg\` below.
2. Open it and drag **$APP_NAME** to **Applications**.
3. Open $APP_NAME from Applications. It appears in the menu bar.

Requires macOS 14 or later and [Claude Code](https://docs.claude.com/en/docs/claude-code)
logged in with a Claude Pro or Max subscription. Verify the download with
\`shasum -a 256 -c $APP_NAME-$VERSION.dmg.sha256\`.
EOF

step "Publish"
if [[ $DRY_RUN -eq 1 ]]; then
    skip "git push --atomic origin main $TAG"
    skip "gh release create $TAG $DMG_PATH $SUM_PATH --title \"$APP_NAME $VERSION\" --generate-notes (notes: $NOTES_PATH)"
    printf '\n%sDry run complete.%s Signed DMG: %s\n' "$GREEN" "$RESET" "$DMG_PATH"
    exit 0
fi

git push --atomic origin main "$TAG"
PUSHED=1
ok "pushed main and $TAG"
gh release create "$TAG" "$DMG_PATH" "$SUM_PATH" --verify-tag \
    --title "$APP_NAME $VERSION" --generate-notes --notes-file "$NOTES_PATH"
printf '\n%sReleased %s%s: %s\n' "$GREEN" "$TAG" "$RESET" "$(gh release view "$TAG" --json url -q .url)"
