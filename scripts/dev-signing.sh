#!/bin/zsh
# 로컬 개발용 자체 서명 인증서를 프로젝트 안(.signing/)에 만든다.
#
# 왜: ad-hoc 서명은 빌드마다 서명(cdhash)이 바뀌어서 손쉬운 사용/카메라 권한이 매번 풀린다.
#     이 인증서로 서명하면 designated requirement 가 "번들 ID + 인증서 해시"로 고정돼 권한이 유지된다.
#     Xcode 에 Apple ID 가 로그인돼 있어 팀 서명이 되면 이 스크립트는 필요 없다.
#
# 로그인 키체인은 건드리지 않는다. 전용 키체인 파일을 .signing/ 에 만들고,
# 서명할 때만 잠깐 검색 목록에 넣었다가 되돌린다 (scripts/run.sh 참고).
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=.signing
KC="$PWD/$DIR/dev.keychain-db"
KC_PASS="gazenoti-dev"
NAME="GazeNoti Local Dev"

if [[ -f "$KC" ]]; then
  echo "이미 있음: $KC"
  security find-identity -p codesigning "$KC" | grep "$NAME" || true
  exit 0
fi

mkdir -p "$DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# macOS security 가 읽을 수 있도록 legacy(3DES/SHA1) 형식으로 내보냄
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:tmp -name "$NAME"

# create-keychain 은 검색 목록을 바꿀 수 있으니 원래 목록을 저장했다가 복구
ORIGINAL=(${(f)"$(security list-keychains -d user | tr -d ' "')"})
security create-keychain -p "$KC_PASS" "$KC"
security list-keychains -d user -s "${ORIGINAL[@]}"
security set-keychain-settings "$KC"   # 자동 잠금 끔
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P tmp -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null

echo "생성 완료: $KC"
security find-identity -p codesigning "$KC" | grep "$NAME"
