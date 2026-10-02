#!/bin/zsh
# GitHub 릴리스 올리기.  사용법: scripts/publish-release.sh   (먼저 scripts/release.sh 로 build/release 를 만든다)
#
# 태그 v<버전> 의 릴리스를 만들고 DMG·체크섬을 올린다. 이미 있으면 파일을 바꿔 올리고 설명을 고친다.
# 홈페이지의 다운로드 버튼은 releases/latest/download/GazeNotification.dmg 를 가리키므로
# 시험판(prerelease)으로 올리지 않는다 — 시험판은 "latest" 가 되지 않는다.
# 릴리스 설명 첫 줄의 `signing: <상태>` 를 홈페이지가 읽어 Gatekeeper 안내를 보이거나 숨긴다.
# DRY_RUN=1 이면 설명만 만들어 보여 주고 올리지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=GazeNotification
OUT=build/release
REPO="${GITHUB_REPOSITORY:-Piorosen/GazeNotification}"
HOMEPAGE="https://piorosen.github.io/GazeNotification/"
[[ -f $OUT/version.txt && -f $OUT/signing.txt ]] || { echo "✗ $OUT 이 없습니다. 먼저 scripts/release.sh 를 실행하세요" >&2; exit 1; }
VERSION=$(<$OUT/version.txt)
SIGNING=$(<$OUT/signing.txt)
TAG="v$VERSION"
# CI 에서는 태그가 가리키는 커밋, 손으로 올릴 때는 (태그가 있으면 그 커밋, 없으면) 지금 커밋
TARGET="${GITHUB_SHA:-$(git rev-list -n 1 "$TAG" 2>/dev/null || git rev-parse HEAD)}"
PREVIOUS=$(git describe --tags --abbrev=0 --match 'v*' "$TARGET^" 2>/dev/null || true)
ASSETS=($OUT/$APP_NAME.dmg $OUT/$APP_NAME-$VERSION.dmg $OUT/$APP_NAME.dmg.sha256 $OUT/$APP_NAME-$VERSION.dmg.sha256)

NOTES=$OUT/notes.md
{
  echo "<!-- signing: $SIGNING -->"
  echo "## 설치 · Install"
  echo
  echo "1. **$APP_NAME.dmg** 를 내려받아 열고, $APP_NAME 을 응용 프로그램(Applications) 폴더로 끌어 놓습니다."
  echo "   Download **$APP_NAME.dmg**, open it, and drag $APP_NAME to Applications."
  echo "2. 처음 실행할 때 카메라와 손쉬운 사용 권한을 허용합니다."
  echo "   On first launch, allow Camera and Accessibility access."
  echo
  if [[ $SIGNING != notarized ]]; then
    echo "> [!IMPORTANT]"
    echo "> 이 버전은 Apple 공증을 받지 않았습니다. 처음 열면 \"확인할 수 없음\" 경고가 뜹니다 →"
    echo "> **시스템 설정 → 개인정보 보호 및 보안** 맨 아래에서 **그래도 열기** 를 누르세요."
    echo "> 업데이트한 뒤에는 손쉬운 사용 목록에서 $APP_NAME 을 껐다 다시 켜야 할 수 있습니다."
    echo ">"
    echo "> This build is not notarized by Apple. macOS will warn on first launch →"
    echo "> open **System Settings → Privacy & Security** and click **Open Anyway** at the bottom."
    echo "> After an update you may need to turn $APP_NAME off and on again under Accessibility."
    echo
  fi
  echo "macOS 14 이상 · Apple Silicon, Intel  /  macOS 14 or later · Apple Silicon and Intel"
  echo
  echo "## 변경 사항 · Changes"
  echo
  if [[ -n $PREVIOUS ]]; then
    git log --no-merges --format='- %s' "$PREVIOUS..$TARGET"
    echo
    echo "전체 비교 · Full diff: https://github.com/$REPO/compare/$PREVIOUS...$TAG"
  else
    echo "첫 공개 버전입니다. 기능 소개는 홈페이지에 있습니다."
    echo "First public release. See the website for what it does."
  fi
  echo
  echo "## SHA-256"
  echo
  echo '```'
  cat $OUT/$APP_NAME.dmg.sha256 $OUT/$APP_NAME-$VERSION.dmg.sha256
  echo '```'
  echo
  echo "홈페이지 · Website: $HOMEPAGE"
} > $NOTES

if [[ -n "${DRY_RUN:-}" ]]; then cat $NOTES; exit 0; fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "▶ $TAG 릴리스가 이미 있어 파일과 설명을 바꿉니다"
  gh release upload "$TAG" "${ASSETS[@]}" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "$APP_NAME $VERSION" --notes-file $NOTES --prerelease=false --draft=false
else
  echo "▶ $TAG 릴리스 만들기 (커밋 ${TARGET:0:7}, 서명 $SIGNING)"
  gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --target "$TARGET" \
    --title "$APP_NAME $VERSION" --notes-file $NOTES
fi
echo "✓ https://github.com/$REPO/releases/tag/$TAG"
echo "  최신 버전 링크: https://github.com/$REPO/releases/latest/download/$APP_NAME.dmg"
