#!/usr/bin/env bash
# build-testflight.sh — archive Carnet (iOS) and upload it to TestFlight.
#
# The same circuit as maurice/app/build-testflight.sh, cut down to one platform:
#   - version = ./VERSION (marketing version; Apple runs a beta review once
#     per version number, so builds of the same version ship without one),
#   - build   = asked of App Store Connect (asc-build-info.ts) + 1,
#   - signing = manual, with the profiles "Carnet iOS App Store" (the app),
#     "… Share", "… Notifications" and "… Safari" (its three extensions).
#     The team's API key has the App Manager role, which Apple does not let
#     sign with cloud-managed certificates ("Cloud signing permission error"),
#     and a key's role cannot be changed. PROVISIONING_PROFILE_IOS="<name>"
#     picks other profiles; PROVISIONING_PROFILE_IOS= (empty) tries automatic
#     signing. A profile expires after a year, and a new extension or
#     capability needs it regenerated: the script checks before archiving.
#
# One-time prerequisites (console state, not code):
#   1. App Store Connect → Apps → + : an app record for eu.chezmaurice.carnet.app.
#   2. An external tester group; the first 1.0.0 build goes through beta review.
#
# After the upload, asc-release-build.ts waits for processing and hands the
# build to every external group — the public beta gets every build, as with
# the Maurice app (internal groups get it on their own). Set SKIP_RELEASE=1
# to stop at the upload.
#
# Each upload is tagged v<version>-<build> on the commit it was built from,
# and the tag is pushed.
#
# Usage:
#   ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer uuid> ./build-testflight.sh
#   BUILD=12 ./build-testflight.sh             # force a build number
set -euo pipefail

# Xcode's IPA step runs /usr/bin/rsync, which spawns a second rsync through
# PATH; Homebrew's rsync 3.x rejects Apple's flags ("Copy failed"). System first.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/Carnet.xcodeproj"
SCHEME="Carnet"
BUNDLE="${IOS_BUNDLE_ID:-eu.chezmaurice.carnet.app}"
TEAM_ID="${TEAM_ID:-F5B4ZC8LEU}"
BUILD_DIR="$SCRIPT_DIR/build"

: "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect API Key ID)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect Issuer ID)}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[[ -f "$KEY_PATH" ]] || { echo "ERROR: API key not found at $KEY_PATH"; exit 1; }

AUTH=(-allowProvisioningUpdates
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID")

VERSION="${VERSION:-$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION" 2>/dev/null || true)}"
: "${VERSION:?no version: set VERSION= or write one into ./VERSION}"

if [[ -z "${BUILD:-}" ]]; then
  echo "▸ asking App Store Connect what has already been uploaded…"
  if ! asc_info="$(ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" IOS_BUNDLE_ID="$BUNDLE" \
                   bun run "$SCRIPT_DIR/asc-build-info.ts")"; then
    echo "ERROR: could not get build info from App Store Connect."
    echo "  Pass BUILD=<n> explicitly if you know it must exceed the last upload."
    exit 1
  fi
  read -r HIGHEST_BUILD HIGHEST_VERSION <<<"$asc_info"
  BUILD=$((HIGHEST_BUILD + 1))
  echo "  highest uploaded: build $HIGHEST_BUILD, version $HIGHEST_VERSION → building $VERSION ($BUILD)"
  ver_lt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" == "$1" && "$1" != "$2" ]]; }
  if ver_lt "$VERSION" "$HIGHEST_VERSION" && [[ -z "${ALLOW_VERSION_DOWNGRADE:-}" ]]; then
    echo "ERROR: $VERSION is lower than $HIGHEST_VERSION, already on App Store Connect."
    exit 1
  fi
fi

# Every upload is tagged v<version>-<build> on the commit it was built from,
# so the build Apple reviews can be found in git later. The commit is read
# now, before the archive, in case the checkout moves while it builds.
SOURCE_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
SOURCE_DIRTY=""
if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=no)" ]]; then
  SOURCE_DIRTY=1
  echo "WARNING: uncommitted changes; the tag will say so."
fi
TAG="v$VERSION-$BUILD"

mkdir -p "$BUILD_DIR"
archive="$BUILD_DIR/Carnet_ios.xcarchive"
opts="$BUILD_DIR/exportOptions_ios.plist"
profile="${PROVISIONING_PROFILE_IOS-Carnet iOS App Store}"

# The four profiles must be installed and still valid; say which is not
# before spending minutes on an archive.
if [[ -n "$profile" ]]; then
  now=$(date +%s)
  missing=()
  for name in "$profile" "$profile Share" "$profile Notifications" "$profile Safari"; do
    found=""
    for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision \
             "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
      [[ -f "$f" ]] || continue
      plist="$(security cms -D -i "$f" 2>/dev/null)" || continue
      [[ "$(/usr/libexec/PlistBuddy -c 'Print :Name' /dev/stdin <<<"$plist" 2>/dev/null)" == "$name" ]] || continue
      expiry="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' /dev/stdin <<<"$plist" 2>/dev/null)"
      if [[ -n "$expiry" ]] && (( $(date -j -f "%a %b %d %T %Z %Y" "$expiry" +%s 2>/dev/null || echo 0) > now )); then
        found=1; break
      fi
    done
    [[ -n "$found" ]] || missing+=("$name")
  done
  if (( ${#missing[@]} )); then
    echo "ERROR: no valid provisioning profile named:"
    printf '         - %s\n' "${missing[@]}"
    echo "       Create or renew it at developer.apple.com → Profiles (App Store Connect,"
    echo "       Apple Distribution), then download it in Xcode → Settings → Accounts."
    exit 1
  fi
fi

echo "==> Archiving $SCHEME — version $VERSION build $BUILD ..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$archive" "${AUTH[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD" MARKETING_VERSION="$VERSION" \
  INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO archive

if [[ -n "$profile" ]]; then
  echo "    export: manual signing, profile '$profile' (+ '$profile Share', '$profile Notifications' and '$profile Safari' for the extensions)"
  cat > "$opts" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>${TEAM_ID}</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>${BUNDLE}</key><string>${profile}</string>
		<key>${BUNDLE}.share</key><string>${profile} Share</string>
		<key>${BUNDLE}.notifications</key><string>${profile} Notifications</string>
		<key>${BUNDLE}.safari</key><string>${profile} Safari</string>
	</dict>
</dict>
</plist>
PLIST
else
  echo "    export: automatic (cloud) signing"
  cat > "$opts" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>${TEAM_ID}</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
fi

echo "==> Exporting + uploading to TestFlight..."
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$opts" "${AUTH[@]}"
echo "==> Uploaded. App Store Connect processes the build in a few minutes."

# Tag the uploaded build and push the tag. A failure here is reported but does
# not fail the run: the build is already on App Store Connect.
tag_msg="Carnet $VERSION (build $BUILD), iOS, uploaded $(date +%F)"
[[ -n "$SOURCE_DIRTY" ]] && tag_msg+=$'\n\nBuilt with uncommitted changes: this commit is close to, not exactly, the upload.'
if git -C "$SCRIPT_DIR" tag -a "$TAG" "$SOURCE_COMMIT" -m "$tag_msg" \
   && git -C "$SCRIPT_DIR" push -q origin "$TAG"; then
  echo "==> Tagged $SOURCE_COMMIT as $TAG and pushed the tag."
else
  echo "WARNING: could not tag or push $TAG; tag $SOURCE_COMMIT by hand."
fi

if [[ -z "${SKIP_RELEASE:-}" ]]; then
  echo "==> Handing build $BUILD to the external TestFlight groups..."
  ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ASC_KEY_PATH="$KEY_PATH" IOS_BUNDLE_ID="$BUNDLE" \
    bun run "$SCRIPT_DIR/asc-release-build.ts" "$BUILD" ios
fi
echo "==> Done. The public invite link stays stable across builds."
