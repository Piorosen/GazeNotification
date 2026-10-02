#!/bin/zsh
# 실행 중인 GazeNotification(Debug 빌드)에 명령 보내기.
#   scripts/debug.sh test    GazeNotification 이름으로 테스트 알림 즉시 전송
#   scripts/debug.sh dump    NotificationCenter AX 트리 → ~/Library/Logs/GazeNotification/ax-dump.txt
#   scripts/debug.sh status  현재 시선/카메라/권한 상태를 로그에 기록
#   scripts/debug.sh snapshot              메뉴 패널을 그려 menu.png 로 저장
#   scripts/debug.sh settings-performance  설정 창(성능 그래프)을 열어 settings-performance.png 로 저장 (limits, calibration 도 같음)
set -euo pipefail
CMD="${1:?usage: debug.sh test|dump|status|snapshot|settings-performance|settings-limits|settings-calibration}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift - <<EOF
import Foundation
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("party.udon.GazeNotification.debug.$CMD"), object: nil, userInfo: nil, deliverImmediately: true)
EOF
sleep 0.5
tail -3 ~/Library/Logs/GazeNotification/gazenotification.log
