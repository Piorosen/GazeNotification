#!/bin/zsh
# 실행 중인 GazeNotification(Debug 빌드)에 명령 보내기.
#   scripts/debug.sh test    GazeNotification 이름으로 테스트 알림 즉시 전송
#   scripts/debug.sh dump    NotificationCenter AX 트리 → ~/Library/Logs/GazeNotification/ax-dump.txt
#   scripts/debug.sh status  현재 시선/카메라/권한 상태를 로그에 기록
#   scripts/debug.sh snapshot              메뉴 패널을 그려 menu.png 로 저장
#   scripts/debug.sh settings-performance  설정 창 탭을 그려 settings-performance.png 로 저장 (limits, ai, calibration 도 같음)
#   scripts/debug.sh mode-precise          AI 모드 얼굴 분석 방식 바꾸기 (precise, light, headPose)
#   scripts/debug.sh device-gpu            Vision 연산 장치 바꾸기 (automatic, neuralEngine, gpu, cpu)
#   scripts/debug.sh profile-balanced      성능 프로필 바꾸기 (automatic, performance, balanced, saver, custom)
#   scripts/debug.sh snapshot-calibration  보정 화면을 32:9 로 그려 calibration-screen.png 로 저장
#   scripts/debug.sh history               성능 기록(최근 10분)을 performance-history.json 으로 내보내기 (홈페이지 그래프용)
set -euo pipefail
CMD="${1:?usage: debug.sh test|dump|status|snapshot|settings-<탭>|mode-<방식>|device-<장치>}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift - <<EOF
import Foundation
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("party.udon.GazeNotification.debug.$CMD"), object: nil, userInfo: nil, deliverImmediately: true)
EOF
sleep 0.5
tail -3 ~/Library/Logs/GazeNotification/gazenotification.log
