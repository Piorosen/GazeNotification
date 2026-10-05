#!/bin/zsh
# 배포용 DMG 만들기.  사용법: scripts/release.sh [버전]   (기본: 프로젝트의 MARKETING_VERSION)
#
# 결과 (build/release/):
#   GazeNotification.dmg            홈페이지의 "최신 버전 받기"가 가리키는 이름 (릴리스마다 같음)
#   GazeNotification-<버전>.dmg      버전을 붙인 사본
#   *.sha256, signing.txt           체크섬, 서명 상태 (notarized | developer-id | self-signed | adhoc)
#
# Apple Silicon·Intel 공용(universal) Release 빌드 → Hardened Runtime 서명 → (가능하면) 공증·staple → DMG.
#
# 서명 인증서는 이 순서로 고른다:
#   1. Developer ID     DEVELOPER_ID(인증서 이름), 없으면 키체인의 "Developer ID Application". 공증까지 하면 Gatekeeper 경고 없음
#   2. 자체 서명         검색 목록의 키체인이나 .signing/dev.keychain-db 에 있는 "GazeNotification" (scripts/release-signing.sh).
#                       공증은 못 하지만 서명이 버전마다 같아서 업데이트해도 손쉬운 사용·카메라 권한이 유지된다
#   3. ad-hoc           빌드마다 서명이 바뀌어 업데이트하면 권한을 다시 설정해야 한다 (미리보기용)
# 공증:
#   NOTARY_PROFILE        `xcrun notarytool store-credentials` 로 저장한 프로필 이름
#   또는 NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID   (App Store Connect API 키 .p8)
#   REQUIRE_NOTARIZATION=1  공증까지 못 하면 실패로 끝낸다
#   REQUIRE_SIGNING=1       ad-hoc 으로 떨어지면 실패로 끝낸다 (인증서를 넣었는데 못 찾은 경우)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME=GazeNotification
ENTITLEMENTS=Config/GazeNotification.entitlements
VERSION="${1:-$(xcodebuild -project $APP_NAME.xcodeproj -target $APP_NAME -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" {print $3; exit}')}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
OUT=build/release
rm -rf "$OUT" build/release-dd
mkdir -p "$OUT"

SELF_SIGNED_NAME=GazeNotification
SIGNING=adhoc
IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
  SIGNING=developer-id
else
  # 손으로 돌릴 때는 개발용 키체인을 잠깐 검색 목록에 넣는다 (codesign 은 검색 목록에서만 identity 를 찾음)
  LOCAL_KC="$PWD/.signing/dev.keychain-db"
  if [[ -f $LOCAL_KC ]]; then
    security unlock-keychain -p gazenotification-dev "$LOCAL_KC"
    ORIGINAL_KEYCHAINS=(${(f)"$(security list-keychains -d user | tr -d ' "')"})
    trap 'security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"' EXIT
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$LOCAL_KC"
  fi
  # 자체 서명 인증서는 신뢰 체인이 없어 -v(유효한 것만)에 안 나오므로 빼고 찾는다. 같은 이름이 여럿이면 첫 번째 (SHA-1 로 지정)
  IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
    | awk -F'"' -v name="$SELF_SIGNED_NAME" '$2 == name {split($1, f, " "); print f[2]; exit}')
  if [[ -n "$IDENTITY" ]]; then SIGNING=self-signed; fi
fi
if [[ "${REQUIRE_SIGNING:-}" == 1 && $SIGNING == adhoc ]]; then
  echo "✗ 서명 인증서를 찾지 못했습니다 (Developer ID 또는 자체 서명 \"$SELF_SIGNED_NAME\")" >&2
  exit 1
fi
NOTARY=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  NOTARY=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

echo "▶ $APP_NAME $VERSION (빌드 $BUILD_NUMBER) · 서명: $SIGNING ${IDENTITY:+($IDENTITY)} · 공증: $([[ $SIGNING == developer-id && ${#NOTARY} -gt 0 ]] && echo 함 || echo 안 함)"

# 1. universal Release 빌드 (서명은 아래에서 직접)
xcodebuild -project $APP_NAME.xcodeproj -scheme $APP_NAME -configuration Release \
  -derivedDataPath build/release-dd -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  -quiet build
APP="$OUT/$APP_NAME.app"
ditto "build/release-dd/Build/Products/Release/$APP_NAME.app" "$APP"
echo "  아키텍처: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

# 2. Hardened Runtime 서명 (공증 조건: Developer ID + 보안 타임스탬프 + Hardened Runtime)
sign() {
  case $SIGNING in
    developer-id) codesign --force --timestamp "$@" --sign "$IDENTITY" ;;
    self-signed)  codesign --force --timestamp=none "$@" --sign "$IDENTITY" ;;
    *)            codesign --force --timestamp=none "$@" --sign - ;;
  esac
}
sign --options runtime --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=1 "$APP"
# 손쉬운 사용·카메라 권한이 묶이는 값. ad-hoc 이면 cdhash 라서 빌드마다 바뀐다
echo "  $(codesign -d -r- "$APP" 2>&1 | grep designated)"

notarize() {
  echo "  공증 제출: $1"
  xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --timeout 30m
}

if [[ $SIGNING == developer-id ]]; then
  if (( ${#NOTARY} )); then
    # 앱을 먼저 공증·staple 해야 DMG 에서 꺼내 오프라인으로 처음 열어도 Gatekeeper 가 통과시킨다
    ditto -c -k --keepParent "$APP" "$OUT/app.zip"
    notarize "$OUT/app.zip"
    xcrun stapler staple "$APP"
    rm "$OUT/app.zip"
    SIGNING=notarized
  fi
fi

# 3. DMG (앱 + 응용 프로그램 폴더 바로가기)
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/$APP_NAME.dmg"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov -quiet "$DMG"
rm -rf "$STAGE"
# DMG 는 Developer ID 일 때만 서명한다 (자체 서명 인증서로 서명한 DMG 는 Gatekeeper 가 열기 전에 막을 수 있음)
if [[ $SIGNING == developer-id || $SIGNING == notarized ]]; then
  sign "$DMG"
  if [[ $SIGNING == notarized ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=1 "$DMG"
  fi
fi
hdiutil verify -quiet "$DMG"

if [[ "${REQUIRE_NOTARIZATION:-}" == 1 && $SIGNING != notarized ]]; then
  echo "✗ 공증이 필요하지만 서명 인증서나 공증 정보가 없습니다 (DEVELOPER_ID, NOTARY_*)" >&2
  exit 1
fi

cp "$DMG" "$OUT/$APP_NAME-$VERSION.dmg"
(cd "$OUT" && for f in $APP_NAME.dmg $APP_NAME-$VERSION.dmg; do shasum -a 256 "$f" > "$f.sha256"; done)
echo "$SIGNING" > "$OUT/signing.txt"
echo "$VERSION" > "$OUT/version.txt"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '), $SIGNING)"
[[ $SIGNING == adhoc || $SIGNING == self-signed ]] && echo "  ⚠️ 공증 없음: 다운로드한 사람은 처음 열 때 시스템 설정 → 개인정보 보호 및 보안 → '그래도 열기' 가 필요합니다."
[[ $SIGNING == adhoc ]] && echo "  ⚠️ ad-hoc 서명: 빌드마다 서명이 바뀌어 업데이트하면 손쉬운 사용 권한을 다시 설정해야 합니다 (scripts/release-signing.sh 참고)."
exit 0
