#!/usr/bin/env bash
# build-visionos.sh
#
# Full App Store pipeline for the native SitiVision visionOS app (xcode/):
#   1. Generate  — xcodegen generate (SitiVision.xcodeproj is not checked in)
#   2. Archive   — xcodebuild archive (automatic signing, Splitfire AB team)
#   3. Export    — xcodebuild -exportArchive (method app-store-connect → .ipa)
#   4. Fixplist  — rewrite the beta host-OS stamp (BuildMachineOSBuild) + Mach-O
#                  LC_BUILD_VERSION, then re-sign — see do_fixplist for why
#   5. Upload    — xcrun altool (TestFlight / App Store Connect submission)
#
# Unlike build-ios.sh (Tauri + cargo-tauri), SitiVision is a plain XcodeGen
# project, so this pipeline is xcodebuild/xcodegen only — no cargo/pnpm steps.
# The fixplist step follows the same workaround as the sibling splitfire repo's
# Scripts/build_karokowe_appstore.sh (native tvOS/visionOS Xcode projects) and
# this repo's own build-ios.sh (Tauri iOS) — see do_fixplist for the mechanism.
#
# Every configurable value has a hardcoded default that can be overridden by
# setting the corresponding environment variable before invoking the script.
#
# Usage:
#   ./scripts/build-visionos.sh              # full pipeline
#   ./scripts/build-visionos.sh generate     # xcodegen generate only
#   ./scripts/build-visionos.sh archive      # archive only (assumes project generated)
#   ./scripts/build-visionos.sh export       # export .ipa only (assumes archive already built)
#   ./scripts/build-visionos.sh fixplist     # patch beta host-OS stamp + re-sign
#   ./scripts/build-visionos.sh upload       # upload only (assumes .ipa already exported)
#
#   make asvision           # full pipeline via Makefile
#   make asvision-generate
#   make asvision-archive
#   make asvision-export
#   make asvision-fixplist
#   make asvision-upload

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE_DIR="${REPO_ROOT}/xcode"
PROJECT="${XCODE_DIR}/SitiVision.xcodeproj"
BUILD_DIR="${XCODE_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/SitiVision.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
IPA_PATH="${EXPORT_DIR}/SitiVision.ipa"

# Auto-load the untracked .env.appstore (signing identities + ASC creds) so
# `make asvision` works without the caller exporting them first. See
# .env.appstore.example for the expected keys.
if [[ -f "${REPO_ROOT}/.env.appstore" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/.env.appstore"
  set +a
fi

# Xcode toolchain. App Store Connect rejects binaries built with a beta Xcode or
# beta SDK, so pin a release Xcode here regardless of the global `xcode-select`.
# Override: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-visionos.sh
pick_release_xcode() {
  local active; active="$(xcode-select -p 2>/dev/null)"
  if [[ -n "$active" && "$active" != *[Bb]eta* ]]; then
    printf '%s\n' "$active"; return
  fi
  local app
  for app in /Applications/Xcode*.app; do
    case "$app" in *[Bb]eta*) continue ;; esac
    [[ -d "$app/Contents/Developer" ]] && { printf '%s\n' "$app/Contents/Developer"; return; }
  done
}
DEVELOPER_DIR="${DEVELOPER_DIR:-$(pick_release_xcode)}"
export DEVELOPER_DIR

# ── Overridable config ─────────────────────────────────────────────────────────

# Apple Developer team (Splitfire AB — same team as the Tauri app's iOS/macOS
# builds; see project.yml's DEVELOPMENT_TEAM and ../src-tauri/tauri.conf.json).
TEAM_ID="${TEAM_ID:-2TQF86ZACD}"

# App Store Connect API credentials. Used both for -allowProvisioningUpdates
# (so archive/export can fetch/create the distribution profile headlessly,
# without a signed-in Xcode account) and for the altool upload.
# ASC_API_KEY   — Key ID shown in App Store Connect → Users & Access → Keys.
# ASC_ISSUER_ID — Issuer UUID on the same page.
# The private key (.p8) must be present at:
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_API_KEY>.p8  (Xcode's default), or
#   set ASC_PRIVATE_KEY_PATH to override.
ASC_API_KEY="${ASC_API_KEY:-L84N624YQH}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-b4e8d369-8b7d-4538-8435-643b73237575}"
ASC_PRIVATE_KEY_PATH="${ASC_PRIVATE_KEY_PATH:-${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY}.p8}"

# Re-sign identity used by the fixplist step (distribution cert for the same
# team as TEAM_ID). Not secret — safe to commit once known.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Distribution: Splitfire AB (2TQF86ZACD)}"

# A shipping macOS build number to stamp for BuildMachineOSBuild during
# fixplist (matches the constant already used by build-ios.sh and the
# sibling splitfire repo's Scripts/build_karokowe_appstore.sh).
RELEASE_OS_BUILD="${RELEASE_OS_BUILD:-25A354}"

# ── Helpers ───────────────────────────────────────────────────────────────────

step() { echo ""; echo "── $* ──────────────────────────────────────────────"; }
ok()   { echo "✅  $*"; }
fail() { printf "❌  %b\n" "$*" >&2; exit 1; }

# True when an Apple build number is a pre-release (beta) seed. Apple stamps
# seeds with a trailing lowercase letter (e.g. 26A5353q); shipping builds
# never carry one (e.g. 25A354).
is_beta_build() {
  [[ "${1:-}" =~ [a-z]$ ]]
}

require_release_xcode() {
  [[ -n "${DEVELOPER_DIR}" && -d "${DEVELOPER_DIR}" ]] \
    || fail "No release Xcode found.\n       Install a release Xcode, or set DEVELOPER_DIR to its Contents/Developer dir."
  case "${DEVELOPER_DIR}" in
    *[Bb]eta*)
      fail "DEVELOPER_DIR points at a beta Xcode:\n       ${DEVELOPER_DIR}\n       App Store Connect rejects beta-built binaries. Point DEVELOPER_DIR at a release Xcode." ;;
  esac
  echo "🛠   Xcode  → $(xcodebuild -version 2>/dev/null | head -1)  [${DEVELOPER_DIR}]"
}

require_asc_key() {
  [[ -f "${ASC_PRIVATE_KEY_PATH}" ]] \
    || fail "ASC API private key not found: ${ASC_PRIVATE_KEY_PATH}\n       Download it from App Store Connect → Users & Access → Integrations → App Store Connect API (once — Apple won't let you re-download), or set ASC_PRIVATE_KEY_PATH."
}

# Release toolchain stamps used by fixplist to rewrite a bundle's Info.plist
# so App Store Connect reads it as a release-Xcode/SDK build. Derived from the
# pinned release Xcode (DEVELOPER_DIR); every value is overridable via env.
derive_release_toolchain() {
  local xv sv xver xbuild sdkver sdkbuild d
  xv="$(xcodebuild -version 2>/dev/null)"
  sv="$(xcodebuild -version -sdk xros 2>/dev/null)"
  xver="$(printf '%s\n' "$xv" | awk '/^Xcode/{print $2}')"
  xbuild="$(printf '%s\n' "$xv" | awk '/Build version/{print $3}')"
  sdkver="$(printf '%s\n' "$sv" | awk -F': ' '/SDKVersion/{print $2; exit}')"
  sdkbuild="$(printf '%s\n' "$sv" | awk -F': ' '/ProductBuildVersion/{print $2; exit}')"
  d="${xver//./}"; while [[ -n "$d" && ${#d} -lt 4 ]]; do d="${d}0"; done
  REL_DTXCODE="${RELEASE_DTXCODE:-$d}"
  REL_XCODE_BUILD="${RELEASE_XCODE_BUILD:-$xbuild}"
  REL_SDK_VERSION="${RELEASE_SDK_VERSION:-$sdkver}"
  REL_SDK_NAME="${RELEASE_SDK_NAME:-xros${sdkver}}"
  REL_SDK_BUILD="${RELEASE_SDK_BUILD:-$sdkbuild}"
  [[ -n "$REL_DTXCODE" && -n "$REL_XCODE_BUILD" && -n "$REL_SDK_BUILD" ]] \
    || fail "Could not determine release toolchain stamps from ${DEVELOPER_DIR}."
}

patch_bundle_plist() {
  local plist="$1"
  pl()    { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || echo ""; }
  setpl() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist" 2>/dev/null \
              || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist"; }
  setpl BuildMachineOSBuild "${RELEASE_OS_BUILD}"
  setpl DTXcode "${REL_DTXCODE}"; setpl DTXcodeBuild "${REL_XCODE_BUILD}"
  setpl DTSDKName "${REL_SDK_NAME}"; setpl DTSDKBuild "${REL_SDK_BUILD}"
  setpl DTPlatformBuild "${REL_SDK_BUILD}"; setpl DTPlatformVersion "${REL_SDK_VERSION}"
}

# ── Steps ─────────────────────────────────────────────────────────────────────

do_generate() {
  step "Generate"

  command -v xcodegen >/dev/null || fail "xcodegen not found.\n       Install with: brew install xcodegen"

  ( cd "${XCODE_DIR}" && xcodegen generate )
  [[ -d "$PROJECT" ]] || fail "xcodegen ran but ${PROJECT} was not created"
  ok "Xcode project generated → ${PROJECT}"
}

do_archive() {
  step "Archive"

  require_release_xcode
  require_asc_key
  [[ -d "$PROJECT" ]] || fail "Xcode project not found at ${PROJECT}\n       Run 'generate' step first."

  # CURRENT_PROJECT_VERSION: unix-seconds build number.
  #   Strictly increasing across builds → satisfies App Store Connect's
  #   "each build must have a higher build number than the last" requirement.
  BUILD_NUMBER="$(date -u +"%s")"

  mkdir -p "${BUILD_DIR}"
  rm -rf "${ARCHIVE_PATH}"

  echo "🏷   buildNumber  → ${BUILD_NUMBER}"
  echo "👥  team         → ${TEAM_ID}"
  echo ""

  xcodebuild archive \
    -project "${PROJECT}" \
    -scheme SitiVision \
    -destination "generic/platform=visionOS" \
    -archivePath "${ARCHIVE_PATH}" \
    -configuration Release \
    -allowProvisioningUpdates \
    -authenticationKeyPath "${ASC_PRIVATE_KEY_PATH}" \
    -authenticationKeyID "${ASC_API_KEY}" \
    -authenticationKeyIssuerID "${ASC_ISSUER_ID}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    DEVELOPMENT_TEAM="${TEAM_ID}"

  [[ -d "$ARCHIVE_PATH" ]] || fail "Archive succeeded but not found at: $ARCHIVE_PATH"
  ok "Archive complete → ${ARCHIVE_PATH}"
}

do_export() {
  step "Export"

  require_release_xcode
  require_asc_key
  [[ -d "$ARCHIVE_PATH" ]] || fail "Archive not found: ${ARCHIVE_PATH}\n       Run 'archive' step first."

  # exportOptionsPlist: automatic signing re-resolves to a *distribution*
  # certificate + App Store profile for method app-store-connect, even though
  # the archive step itself signs with a development identity (expected —
  # Xcode always archives with the dev cert; export re-signs per method).
  cat > "${EXPORT_OPTIONS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST

  rm -rf "${EXPORT_DIR}"

  xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "${ASC_PRIVATE_KEY_PATH}" \
    -authenticationKeyID "${ASC_API_KEY}" \
    -authenticationKeyIssuerID "${ASC_ISSUER_ID}"

  [[ -f "$IPA_PATH" ]] || fail "Export succeeded but .ipa not found at: $IPA_PATH"
  ok "Export complete → ${IPA_PATH}"
}

# Why this is needed even with a release Xcode pinned via DEVELOPER_DIR:
# xcodebuild fully respects DEVELOPER_DIR, so DTXcode/DTXcodeBuild/DTSDKBuild
# and every Mach-O's embedded LC_BUILD_VERSION sdk field all come out
# clean/release automatically. But `BuildMachineOSBuild` reflects the literal
# host macOS build — this Mac itself, regardless of which Xcode.app performs
# the build. When the host OS is a beta seed (a build number with a trailing
# lowercase letter, e.g. `26A5353q`), that field alone is enough to make App
# Store Connect's REVIEW-SUBMISSION validation — a separate, stricter pass
# than TestFlight build processing — reject the binary as "Invalid Binary"
# with no further detail, even though TestFlight processing itself reports
# the build as valid. Mirrors build-ios.sh's fixplist step and the sibling
# splitfire repo's Scripts/build_karokowe_appstore.sh, adapted for a plain
# xcodebuild archive/export instead of `cargo tauri ios build`.
do_fixplist() {
  step "Fixplist (beta host OS → release)"

  [[ -f "$IPA_PATH" ]] || fail ".ipa not found: ${IPA_PATH}\n       Run 'export' step first."
  command -v /usr/libexec/PlistBuddy >/dev/null || fail "PlistBuddy not found"

  local work app_dir os_cur
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN

  unzip -q "$IPA_PATH" -d "$work"
  app_dir="$(find "$work/Payload" -maxdepth 1 -name '*.app' -print -quit)"
  [[ -n "$app_dir" && -d "$app_dir" ]] || fail "No .app found inside ${IPA_PATH}"

  os_cur="$(/usr/libexec/PlistBuddy -c 'Print :BuildMachineOSBuild' "$app_dir/Info.plist" 2>/dev/null || echo "")"
  if [[ -z "${FORCE_FIXPLIST:-}" ]] && ! is_beta_build "$os_cur"; then
    ok "BuildMachineOSBuild (${os_cur}) is already a release seed — no patch needed."
    return 0
  fi

  require_release_xcode
  derive_release_toolchain
  echo "🛠   xcode → ${REL_DTXCODE}/${REL_XCODE_BUILD}   sdk → ${REL_SDK_NAME}/${REL_SDK_BUILD}"
  echo "🔁   BuildMachineOSBuild ${os_cur:-<unset>} → ${RELEASE_OS_BUILD}"
  echo "🔏  identity → ${SIGN_IDENTITY}"
  echo ""

  # Patch every bundle's Info.plist: the main .app and any nested extensions.
  local bundles=("$app_dir")
  while IFS= read -r appex; do bundles+=("$appex"); done \
    < <(find "$app_dir" -name '*.appex' -type d)
  local bundle
  for bundle in "${bundles[@]}"; do
    [[ -f "$bundle/Info.plist" ]] && patch_bundle_plist "$bundle/Info.plist"
  done

  # Critical: App Store Connect's review-stage validation reads the `sdk`
  # baked into each executable's Mach-O LC_BUILD_VERSION, not just the
  # Info.plist DTSDK* keys. Patch every Mach-O in the bundle; minos is
  # preserved, only the sdk is (re)set to the release SDK.
  local macho minos_cur
  while IFS= read -r macho; do
    [[ -z "$macho" ]] && continue
    minos_cur="$(xcrun vtool -show-build "$macho" 2>/dev/null | awk '/minos/{print $2; exit}')"
    minos_cur="${minos_cur:-2.0}"
    echo "🔁   Mach-O sdk → ${REL_SDK_VERSION} (minos ${minos_cur}): ${macho#"$app_dir"/}"
    xcrun vtool -set-build-version visionos "${minos_cur}" "${REL_SDK_VERSION}" \
      -replace -output "${macho}.vt" "$macho" >/dev/null 2>&1 \
      && mv "${macho}.vt" "$macho" \
      || fail "vtool failed to patch LC_BUILD_VERSION on ${macho#"$app_dir"/}"
  done < <(find "$app_dir" -type f -exec sh -c 'file "$1" | grep -q Mach-O' _ {} \; -print)

  # Re-sign nested code deepest-first, then the .app last — editing the
  # plist/Mach-O invalidates the original signature.
  local nested ent
  while IFS= read -r nested; do
    [[ -z "$nested" ]] && continue
    ent="${work}/$(basename "$nested" | tr '/' '_').entitlements"
    echo "✍️   sign nested → ${nested#"$app_dir"/}"
    if codesign -d --entitlements :"$ent" "$nested" 2>/dev/null && [[ -s "$ent" ]]; then
      codesign --force --timestamp=none --sign "$SIGN_IDENTITY" --entitlements "$ent" "$nested"
    else
      codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$nested"
    fi
  done < <(find "$app_dir" \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' \) -print \
             | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

  ent="${work}/app.entitlements"
  if codesign -d --entitlements :"$ent" "$app_dir" 2>/dev/null && [[ -s "$ent" ]]; then
    codesign --force --timestamp=none --sign "$SIGN_IDENTITY" --entitlements "$ent" "$app_dir"
  else
    codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$app_dir"
  fi
  codesign --verify --deep --strict "$app_dir" || fail "Re-signed app failed signature verification"
  echo "🔁  now: DTXcodeBuild=$(/usr/libexec/PlistBuddy -c 'Print :DTXcodeBuild' "$app_dir/Info.plist" 2>/dev/null)  BuildMachineOSBuild=$(/usr/libexec/PlistBuddy -c 'Print :BuildMachineOSBuild' "$app_dir/Info.plist" 2>/dev/null)"

  rm -f "$IPA_PATH"
  ( cd "$work" && zip -qry "$IPA_PATH" Payload )
  [[ -f "$IPA_PATH" ]] || fail "Repack failed: $IPA_PATH"

  ok "Patched + re-signed → ${IPA_PATH}"
}

do_upload() {
  step "Upload"

  [[ -f "$IPA_PATH" ]] || fail ".ipa not found: ${IPA_PATH}\n       Run 'export' step first."

  echo "📤  file    → ${IPA_PATH}"
  echo "🔑  apiKey  → ${ASC_API_KEY}"
  echo "🏢  issuer  → ${ASC_ISSUER_ID}"
  echo ""

  xcrun altool \
    --upload-app \
    --type visionos \
    --file "${IPA_PATH}" \
    --apiKey "${ASC_API_KEY}" \
    --apiIssuer "${ASC_ISSUER_ID}"

  ok "Uploaded to App Store Connect"
}

# ── Entry point ───────────────────────────────────────────────────────────────

STEP="${1:-all}"

case "$STEP" in
  generate) do_generate ;;
  archive)  do_archive  ;;
  export)   do_export   ;;
  fixplist) do_fixplist ;;
  upload)   do_upload   ;;
  all)
    do_generate
    do_archive
    do_export
    do_fixplist
    do_upload
    echo ""
    echo "🎉  Pipeline complete: built and uploaded SitiVision to App Store Connect."
    ;;
  *)
    echo "Usage: $0 [generate|archive|export|fixplist|upload|all]" >&2
    exit 1
    ;;
esac
