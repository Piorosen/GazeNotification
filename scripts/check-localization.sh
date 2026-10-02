#!/bin/zsh
# 언어팩 점검: 코드에서 추출한 번역 문구 중 언어별로 번역이 빠진 것을 보여 준다 (빠진 게 있으면 종료 코드 1).
#   scripts/check-localization.sh
# 새 문구를 추가했다면 Xcode 에서 Localizable.xcstrings 를 열어 번역을 채우면 된다 (빌드하면 새 키가 카탈로그에 들어감).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT=build/localization-check
rm -rf "$OUT"
LANGS=(en ja zh-Hans)
EXPORT=()
for lang in $LANGS; do EXPORT+=(-exportLanguage "$lang"); done
xcodebuild -exportLocalizations -project GazeNotification.xcodeproj -localizationPath "$OUT" \
  "${EXPORT[@]}" DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="-" >/dev/null 2>&1
python3 - "$OUT" "${LANGS[@]}" <<'PY'
import glob, sys, xml.etree.ElementTree as ET
out, langs = sys.argv[1], sys.argv[2:]
ns = {'x': 'urn:oasis:names:tc:xliff:document:1.2'}
missing = 0
for lang in langs:
    f = glob.glob(f'{out}/{lang}.xcloc/Localized Contents/*.xliff')[0]
    units = [u for u in ET.parse(f).getroot().iterfind('.//x:trans-unit', ns)
             if (u.findtext('x:source', '', ns) or '').strip()]
    todo = [u.get('id') for u in units if not (u.findtext('x:target', '', ns) or '').strip()]
    print(f'{lang}: {len(units) - len(todo)}/{len(units)} 번역됨')
    for key in todo:
        print(f'  - {key}')
    missing += len(todo)
sys.exit(1 if missing else 0)
PY
