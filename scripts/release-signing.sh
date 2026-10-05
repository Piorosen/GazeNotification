#!/bin/zsh
# 배포판 서명용 자체 서명 인증서를 만들고 GitHub Actions 비밀 값으로 올린다.  사용법: scripts/release-signing.sh
#
# 왜: ad-hoc 서명은 빌드마다 서명(cdhash)이 바뀐다. 손쉬운 사용 권한은 서명에 묶이므로, 업데이트하면
#     목록에는 GazeNotification 이 켜진 채로 보이는데 앱은 허용되지 않는다 (껐다 켜도 안 풀림).
#     같은 인증서로 계속 서명하면 designated requirement 가 "번들 ID + 인증서 해시"로 고정돼 업데이트해도 권한이 유지된다.
#     Gatekeeper 에는 ad-hoc 과 똑같다 (공증이 없으니 처음 열 때 "그래도 열기"). Developer ID 를 넣으면 그쪽이 우선한다.
#
# 하는 일 (이미 된 단계는 건너뜀):
#   1. .signing/release.p12 + release.password 에 인증서·개인 키 (git 제외. 잃어버리면 새로 만들고, 사용자는 권한을 한 번 다시 준다)
#   2. 개발용 키체인(.signing/dev.keychain-db)에도 넣는다 → scripts/run.sh 의 개발 빌드가 배포판과 같은 서명을 써서
#      같은 Mac 에서 번갈아 실행해도 권한이 풀리지 않는다. scripts/release.sh 를 손으로 돌릴 때도 이것을 쓴다
#   3. GitHub 저장소 비밀 값 SELF_SIGNED_P12_BASE64, SELF_SIGNED_P12_PASSWORD (gh 로그인 필요, NO_UPLOAD=1 이면 건너뜀)
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=GazeNotification   # 인증서 이름 (scripts/release.sh, run.sh 가 이 이름으로 찾는다)
DIR=.signing
P12=$DIR/release.p12
PASSWORD_FILE=$DIR/release.password
KC="$PWD/$DIR/dev.keychain-db"
KC_PASS="gazenotification-dev"

mkdir -p $DIR
chmod 700 $DIR

# 새 저장소에 받았거나 .signing/ 을 지웠을 때 실수로 인증서를 바꾸지 않게 (바꾸면 모든 사용자가 권한을 다시 설정해야 함)
if [[ ! -f $P12 && -z "${NO_UPLOAD:-}" && -z "${FORCE:-}" ]] && gh secret list 2>/dev/null | grep -q '^SELF_SIGNED_P12_BASE64'; then
  echo "✗ GitHub 에는 이미 인증서가 있는데 $P12 가 없습니다." >&2
  echo "  백업해 둔 release.p12·release.password 를 $DIR/ 에 넣고 다시 실행하세요. 정말 새 인증서로 바꾸려면 FORCE=1" >&2
  exit 1
fi

if [[ ! -f $P12 ]]; then
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
  # 인증서가 바뀌면 사용자 권한이 풀리므로 넉넉하게 (서명 검사는 만료일을 보지 않지만 혹시 모를 도구를 위해)
  openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
  openssl rand -base64 24 > $PASSWORD_FILE
  # macOS security 가 읽을 수 있도록 legacy(3DES/SHA1) 형식으로 내보냄
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out $P12 -passout file:$PASSWORD_FILE -name "$NAME"
  chmod 600 $P12 $PASSWORD_FILE
  echo "생성: $P12 ($(openssl x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2))"
else
  echo "이미 있음: $P12"
fi
PASSWORD=$(<$PASSWORD_FILE)

# 2. 개발용 키체인에 넣기
[[ -f $KC ]] || scripts/dev-signing.sh
security unlock-keychain -p "$KC_PASS" "$KC"
if security find-identity -p codesigning "$KC" | grep -q "\"$NAME\""; then
  echo "개발용 키체인에 이미 있음"
else
  security import $P12 -k "$KC" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null
  echo "개발용 키체인에 넣음: $KC"
fi
security find-identity -p codesigning "$KC" | grep "\"$NAME\""

# 3. GitHub 비밀 값
if [[ -n "${NO_UPLOAD:-}" ]]; then
  echo "GitHub 에는 올리지 않음 (NO_UPLOAD)"
  exit 0
fi
base64 -i $P12 | gh secret set SELF_SIGNED_P12_BASE64
gh secret set SELF_SIGNED_P12_PASSWORD --body "$PASSWORD"
echo "✓ GitHub 비밀 값 SELF_SIGNED_P12_BASE64, SELF_SIGNED_P12_PASSWORD 를 올렸습니다. 다음 태그부터 이 인증서로 서명합니다."
