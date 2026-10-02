#!/bin/zsh
# 단위 테스트 + UI 테스트.  사용법: scripts/test.sh [unit|ui|all] [추가 xcodebuild 인자...]
#
# Apple Development 인증서가 없으면 ad-hoc 으로 서명하고 Hardened Runtime 을 끈다
# (ad-hoc 서명끼리는 팀 ID 가 없어 Hardened Runtime 의 라이브러리 검증이 테스트 번들 로드를 막는다).
# UI 테스트는 앱을 -uiTesting 모드(가상 카메라, 별도 설정 저장소)로 띄우며, 실행 중인 GazeNotification 은 종료된다.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WHICH="${1:-all}"; shift 2>/dev/null || true

ONLY=()
case "$WHICH" in
  unit) ONLY=(-only-testing:GazeNotificationTests) ;;
  ui)   ONLY=(-only-testing:GazeNotificationUITests) ;;
  all)  ;;
  *)    echo "usage: scripts/test.sh [unit|ui|all]"; exit 2 ;;
esac

SIGN=()
if ! security find-identity -v -p codesigning | grep -q "Apple Development"; then
  SIGN=(DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="-" ENABLE_HARDENED_RUNTIME=NO)
fi

xcodebuild test -project GazeNotification.xcodeproj -scheme GazeNotification -configuration Debug \
  -derivedDataPath build/tests -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "build/tests/Results-$(date +%Y%m%d-%H%M%S).xcresult" \
  "${ONLY[@]}" "${SIGN[@]}" "$@"
