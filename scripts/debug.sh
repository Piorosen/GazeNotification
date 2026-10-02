#!/bin/zsh
# 실행 중인 GazeNotification(Debug 빌드)에 명령 보내기.
#   scripts/debug.sh test    GazeNotification 이름으로 테스트 알림 즉시 전송
#   scripts/debug.sh dump    NotificationCenter AX 트리 → ~/Library/Logs/GazeNotification/ax-dump.txt
#   scripts/debug.sh status  현재 시선/카메라/권한 상태를 로그에 기록
set -euo pipefail
CMD="${1:?usage: debug.sh test|dump|status}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift - <<EOF
import Foundation
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("party.udon.GazeNotification.debug.$CMD"), object: nil, userInfo: nil, deliverImmediately: true)
EOF
sleep 0.5
tail -3 ~/Library/Logs/GazeNotification/gazenotification.log
