#!/bin/zsh
# GazeNotification 빌드 후 실행.  사용법: scripts/run.sh [Debug|Release]
#
# 서명:
#   - 유효한 "Apple Development" 인증서가 있으면 프로젝트 설정(팀 서명)대로 빌드
#   - 없으면 ad-hoc 으로 빌드한 뒤 .signing/ 의 로컬 개발 인증서로 다시 서명
#     (권한이 재빌드 후에도 유지되도록). 강제: GAZENOTIFICATION_SIGNING=team|dev
set -euo pipefail
cd "$(dirname "$0")/.."

# xcode-select 가 CommandLineTools 를 가리켜도 Xcode.app 으로 빌드되게 함
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-Debug}"
APP="build/Build/Products/$CONFIG/GazeNotification.app"
COMMON=(-project GazeNotification.xcodeproj -scheme GazeNotification -configuration "$CONFIG"
        -derivedDataPath build -destination 'platform=macOS,arch=arm64' -quiet)

SIGNING="${GAZENOTIFICATION_SIGNING:-}"
if [[ -z "$SIGNING" ]]; then
  if security find-identity -v -p codesigning | grep -q "Apple Development"; then SIGNING=team; else SIGNING=dev; fi
fi

if [[ "$SIGNING" == team ]]; then
  xcodebuild "${COMMON[@]}" -allowProvisioningUpdates build
else
  xcodebuild "${COMMON[@]}" DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="-" build

  [[ -f .signing/dev.keychain-db ]] || scripts/dev-signing.sh
  KC="$PWD/.signing/dev.keychain-db"
  security unlock-keychain -p gazenotification-dev "$KC"
  HASH=$(security find-identity -p codesigning "$KC" | awk '/GazeNotification Local Dev/ {print $2; exit}')

  # codesign 은 검색 목록에 있는 키체인에서만 identity 를 찾으므로 잠깐 추가했다가 복구
  ORIGINAL=(${(f)"$(security list-keychains -d user | tr -d ' "')"})
  trap 'security list-keychains -d user -s "${ORIGINAL[@]}"' EXIT
  security list-keychains -d user -s "${ORIGINAL[@]}" "$KC"

  for lib in "$APP"/Contents/MacOS/*.dylib(N); do
    codesign --force --sign "$HASH" --timestamp=none "$lib"
  done
  codesign --force --sign "$HASH" --timestamp=none --options runtime \
    --entitlements Config/GazeNotification.entitlements "$APP"

  security list-keychains -d user -s "${ORIGINAL[@]}"
  trap - EXIT
fi

codesign -d -r- "$APP" 2>&1 | grep designated || true

pkill -x GazeNotification 2>/dev/null && sleep 0.5 || true
open "$APP"
echo "실행: $APP ($SIGNING 서명)"
