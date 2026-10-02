#!/bin/zsh
# 홈페이지 "화면 살펴보기"의 앱 스크린샷(site/assets/tour/<언어>/*.webp)과 성능 기록(site/assets/performance-history.json) 만들기.
#   scripts/site-screenshots.sh          스크린샷만 (언어마다 앱을 다시 띄워 약 3분)
#   scripts/site-screenshots.sh history  성능 기록도 (자동 프로필 6분 + 원래 프로필 4분을 더 기록)
#
# 실행 중인 Debug 앱을 언어별로 다시 띄우고 개발용 명령(scripts/debug.sh)으로 화면 밖에 그린다. 카메라가 켜지고,
# 촬영하는 동안은 성능 프로필을 "자동"으로 바꿨다가 끝나면 원래대로 돌린다. 필요: cwebp (brew install webp)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DOMAIN=party.udon.GazeNotification
APP=build/Build/Products/Debug/GazeNotification.app
LOGS=~/Library/Logs/GazeNotification
WORK=build/site-screenshots
mkdir -p $WORK/bin
for tool in cards crop; do swiftc -O -o $WORK/bin/$tool scripts/tools/$tool.swift; done
ORIGINAL=$(defaults read $DOMAIN performance.profile 2>/dev/null || echo automatic)
trap 'scripts/debug.sh profile-$ORIGINAL >/dev/null 2>&1 || defaults write $DOMAIN performance.profile $ORIGINAL' EXIT

scripts/run.sh
snap() {  # 명령 결과 파일이 생길 때까지 기다렸다가 복사
  rm -f "$LOGS/$2"; scripts/debug.sh $1 >/dev/null
  for i in {1..40}; do [[ -f "$LOGS/$2" ]] && break; sleep 0.5; done
  cp "$LOGS/$2" "$3"
}
for lang in ko en ja zh-Hans; do
  pkill -x GazeNotification || true; sleep 1
  open "$APP" --args -AppleLanguages "($lang)"; sleep 6
  scripts/debug.sh profile-automatic >/dev/null; sleep 35   # 값이 안정되고 기록이 쌓이도록
  mkdir -p $WORK/$lang
  snap snapshot menu.png $WORK/$lang/menu.png
  for tab in limits ai calibration; do snap settings-$tab settings-$tab.png $WORK/$lang/$tab.png; done
  snap snapshot-calibration calibration-screen.png $WORK/$lang/calibration-screen.png
done

# 카드(설정 창 묶음, 메뉴의 상세 칸) 위치를 찾아 기능별로 자른다
python3 - "$WORK" <<'PY'
import os, subprocess, sys
work = sys.argv[1]
def cards(path, x):
    out = subprocess.run([f'{work}/bin/cards', path, str(x)], capture_output=True, text=True, check=True).stdout.split('\n')[1:]
    return [tuple(map(int, l.split()[:2])) for l in out if l.strip()]
for lang in ['ko', 'en', 'ja', 'zh-Hans']:
    src, out = f'{work}/{lang}', f'site/assets/tour/{lang}'
    os.makedirs(out, exist_ok=True)
    m, l, a, c = cards(f'{src}/menu.png', 40), cards(f'{src}/limits.png', 200), cards(f'{src}/ai.png', 200), cards(f'{src}/calibration.png', 200)
    jobs = {  # 이름: (원본, x, y, 폭, 높이) — 2배 해상도 px
        'menu-panel': ('menu.png', 0, 0, 840, m[2][1] + 24),
        'menu-processing': ('menu.png', 0, m[2][1] + 24, 840, m[4][1] - m[2][1] - 8),
        'menu-gaze': ('menu.png', 0, m[4][1] + 8, 840, m[7][1] - m[4][1] + 8),
        'limits': ('limits.png', 120, 0, 1280, l[4][0] - 76),
        'ai': ('ai.png', 120, 0, 1280, a[3][0] - 40),
        'tuning': ('calibration.png', 120, 0, 1280, c[2][0] - 70),
        'weights': ('calibration.png', 120, c[3][0] - 66, 1280, (c[4][0] - 70 if len(c) > 4 else c[3][1] + 110) - (c[3][0] - 66)),
    }
    for name, (file, x, y, w, h) in jobs.items():
        png = f'{work}/{lang}-{name}.png'
        subprocess.run([f'{work}/bin/crop', f'{src}/{file}', png, str(x), str(y), str(w), str(h)], check=True)
        subprocess.run(['cwebp', '-quiet', '-q', '90', '-sharp_yuv', png, '-o', f'{out}/{name}.webp'], check=True)
    subprocess.run(['cwebp', '-quiet', '-q', '90', f'{src}/calibration-screen.png', '-o', f'{out}/calibration-screen.webp'], check=True)
    print('✓', out)
PY

if [[ "${1:-}" == history ]]; then
  pkill -x GazeNotification || true; sleep 1; open "$APP"; sleep 5
  scripts/debug.sh profile-automatic >/dev/null; echo "성능 기록 중: 자동 6분"; sleep 360
  scripts/debug.sh profile-$ORIGINAL >/dev/null; echo "성능 기록 중: $ORIGINAL 4분"; sleep 245
  rm -f $LOGS/performance-history.json; scripts/debug.sh history >/dev/null; sleep 1
  python3 - "$LOGS/performance-history.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
json.dump(d, open('site/assets/performance-history.json', 'w'), separators=(',', ':'))
print('✓ site/assets/performance-history.json', len(d['samples']), '개')
PY
fi
pkill -x GazeNotification || true; sleep 1; open "$APP"
