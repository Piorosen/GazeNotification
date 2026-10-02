# GazeNotification

메뉴 막대 앱 **GazeNotification** — 32:9 같은 초광폭 모니터에서 macOS 알림이 항상 오른쪽 위에 떠서 못 보는 문제를 해결하는 메뉴 막대 앱.
웹캠으로 얼굴·눈 방향을 추적해 **지금 보고 있는 가로 위치**의 화면 상단으로 알림 배너를 옮긴다.

**내려받기**: [홈페이지](https://blog.udon.party/GazeNotification/) · [GazeNotification.dmg (최신 버전)](https://github.com/Piorosen/GazeNotification/releases/latest/download/GazeNotification.dmg) · [모든 릴리스](https://github.com/Piorosen/GazeNotification/releases)

## 동작 방식

```
카메라(AVFoundation, 800x448 비압축, 장치 fps 는 목표 처리 횟수에 맞춰 5~10fps)
  → 시간 기준으로 처리할 프레임만 골라 Vision 으로 (초당 0.1~15회, 상황·프로필별)
  → 얼굴 검출(N 번에 1번, 사이는 직전 얼굴 상자를 눈에 맞춰 옮겨 추적) → 랜드마크 76/65점 — Neural Engine 에서 실행
  → 특징: 코 오프셋(머리 yaw), 동공 오프셋, 얼굴 x, Vision yaw
  → 추정 모델(선형·곡선 회귀·점별 보간 중 선택) → 수동 조정(이동·범위·가중치) → One Euro 필터 → 시선 x (0…1)
  → NotificationMover: NotificationCenter 의 알림 창을 Accessibility API 로 평행 이동
```

- macOS 15 의 알림은 화면 전체 크기의 투명 창 안에서 오른쪽 끝으로 슬라이드해 들어온다. 이 창은 알림이 없어도 유지되므로
  **알림이 없을 때 미리 창을 시선 위치로 옮겨 둔다(사전 배치)** → 다음 알림이 처음부터 보고 있는 곳에 뜬다.
- 배너가 아니라 창의 "배너 슬롯"을 움직이므로 시스템의 슬라이드 인/아웃 애니메이션과 싸우지 않는다.
- 떠 있는 동안 시선이 화면 폭의 8% 이상 옮겨가면 부드럽게 따라간다(옵션).
- 알림 센터 패널(위젯 화면)이 열리면, 그리고 앱을 끄거나 비활성화하면 창을 원래 위치로 되돌린다.
- 카메라 영상은 메모리에서만 처리하고 저장하거나 전송하지 않는다.

## 자원 사용

측정값 (M4 Max, C922, 얼굴이 보이는 상태에서 60초 동안 `ps` 누적 CPU 시간, 100% = 코어 1개, Debug 빌드):

| | CPU | Vision 처리 |
| --- | --- | --- |
| 이전 버전 | 8.7~8.8% | 초당 4.9회, 검출 매번 |
| 이전 버전, 카메라 미리보기를 한 번 열었다 닫은 뒤 | 약 35% | 장치가 30fps 로 풀려 초당 15회 |
| **절전** 프로필 | 3.1% | 초당 2.5회 (머물면 1회), 검출 6번에 1번 |
| **균형** 프로필 (전원 연결 시 자동) | 6.9~7.5% | 초당 5회 (머물면 2.5회), 검출 3번에 1번 |
| 성능 우선 프로필 | 16.2% | 초당 10회, 검출 매번 |

같은 처리 횟수(초당 5회)에서 얼굴 검출만 바꾸면 매번 9.8% → 3번에 1번 7.2%. 검출 1회는 프로세스 CPU 약 9ms + Neural Engine 대기 약 11ms,
랜드마크 1회는 CPU 약 5ms (Vision 은 자기 작업 스레드에서 계산하므로 호출한 스레드 CPU 가 아니라 프로세스 CPU 로 잰다).

AI 모드별 (초당 5회, 검출 3번에 1번): 정밀 76점 7.0% · 가벼움 65점 7.2% · 머리 방향만 7.1% (Neural Engine) /
정밀 76점을 GPU 로 7.7% · CPU 로 27.7%. 이 Mac 에서는 분석 방식보다 연산 장치가 차이를 만든다.

줄인 방법:

- **카메라 포맷 직접 지정**: 1920x1080 MJPEG(디코딩 필요)를 720p 로 줄이던 것을 800x448 비압축(yuvs)으로. 출력 크기도 고정해 추가 스케일링 없음.
- **처리 여부를 시간 기준으로**: "N 프레임마다 1번" 대신 목표 처리 간격으로 고른다. 장치가 5fps 밑으로 못 내려가거나 다른 앱·미리보기 때문에 fps 가 바뀌어도 처리 횟수는 목표를 넘지 않는다.
- **장치 fps 는 목표 이상에서 카메라가 지원하는 가장 낮은 값**(C922: 5·7.5·10·15·20·24·30). 세션 재구성으로 30fps 로 풀리면 받은 프레임 수로 감지해 다시 적용한다.
- **얼굴 검출 건너뛰기**: 검출은 N 번에 1번, 그 사이는 직전 얼굴 상자를 두 눈 위치에 맞춰 옮겨 랜드마크만 찾는다. 랜드마크 신뢰도가 0.5 아래거나 고개를 크게 돌리면(코 방향 변화 > 0.06) 바로 다시 검출.
- **상황별 처리 횟수**: 활동 중 / 시선 고정 / 자리 비움 / 실시간(보정·미리보기·보정 조정) 상태마다 다르게, 알림이 떠 있는 동안은 올려서 빨리 따라간다.
- **전원 상태 반영**: 배터리·저전력 모드·발열이 높으면 자동으로 절전. 화면이 꺼지거나 잠기면 카메라를 끄고, 오래 자리를 비우면 카메라를 껐다가 키보드·마우스 입력이 생기면 다시 켠다.
- **CPU 한도**: 영상 처리 CPU(메인 스레드 제외)가 정한 값을 넘으면 처리 횟수를 비례해 줄인다.
- **Vision 신경망 단계를 Neural Engine 에 고정** (`setComputeDevice`), 얼굴 검출 결과를 랜드마크 요청에 넘겨 중복 검출 제거.
- **알림 창 감시는 창 서버 조회로**: 알림이 없을 땐 AX 호출 없이 `CGWindowListCreateDescriptionFromArray` 로 표시 여부만 확인 (초당 4~20회, 프로필별). 알림이 떠 있을 때도 AX 는 2초에 한 번만 읽는다.
- **UI 는 메뉴·설정 창이 보일 때만 갱신** (SwiftUI 재계산 없음). 성능 기록은 1초에 한 번 배열에 쌓기만 한다.

측정해 보고 효과가 없어서 채택하지 않은 것: 출력 픽셀 포맷(420f/yuvs/BGRA), 해상도 640x360, Release 최적화(모두 차이 1% 이내),
`VNSequenceRequestHandler` 재사용(검출 1회 CPU 차이 없음), 추적 프레임에서 코 방향 변화로 yaw 보정(오히려 오차 증가: 그대로 0.6~3° vs 보정 1.4~9.7°).

## 요구 사항

- macOS 14 이상 (개발 환경: macOS 15.6, Xcode 16.4)
- 모니터 위 중앙에 둔 웹캠 (C922 등). 카메라 목록에서 가상 카메라(OBS)는 자동 선택에서 뒤로 밀린다.

## 빌드 / 실행

```sh
scripts/run.sh            # Debug 빌드 → 서명 → 실행
scripts/run.sh Release    # 평소 사용
open GazeNotification.xcodeproj   # Xcode 에서 ⌘R (팀 서명이 될 때)
```

`scripts/run.sh` 는 `DEVELOPER_DIR` 를 Xcode.app 으로 지정해서, `xcode-select` 가 CommandLineTools 를 가리켜도 빌드된다.
시스템 전체를 바꾸려면: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`

### 서명과 권한 유지

손쉬운 사용·카메라 권한은 **코드 서명**에 묶인다. ad-hoc 서명은 빌드마다 서명이 바뀌어 재빌드할 때마다 권한을 다시 줘야 한다.

- `scripts/run.sh` 는 유효한 Apple Development 인증서가 없으면 `scripts/dev-signing.sh` 로 만든 **로컬 개발 인증서**(`.signing/`, git 제외)로 다시 서명한다.
  서명 요구조건이 "번들 ID + 인증서 해시"로 고정돼 **재빌드해도 권한이 유지**된다. 로그인 키체인은 건드리지 않는다.
- Xcode → Settings → Accounts 에 Apple ID 로 로그인돼 있으면 팀 서명(Personal Team)을 쓴다. 이 경우 Xcode ⌘R 로도 권한이 유지된다.
  (팀 서명으로 바꾸면 서명이 달라지므로 권한을 한 번 다시 허용해야 한다.)

권한이 꼬였을 때:

```sh
tccutil reset Accessibility party.udon.GazeNotification
tccutil reset Camera party.udon.GazeNotification
```

### 테스트

```sh
scripts/test.sh unit   # 단위 테스트 (Swift Testing, 화면을 건드리지 않음, 약 3초)
scripts/test.sh ui     # UI 테스트 (XCUITest) — ⚠️ 실제 화면에서 마우스·키보드를 움직인다, 약 5분
scripts/test.sh        # 둘 다
```

- **단위 테스트**(`GazeNotificationTests`): 회귀·곡선·점별 보간·교차검증, 보정 저장(NaN 포함)·예전 형식 이전, 수동 보정·구역,
  프로필 규칙·제한값·CPU 상한 수렴, 처리 간격(장치 fps 와 무관하게 목표 ±5%)·30fps 풀림 감시·장치 fps 선택,
  추적 상자·알림 슬롯 계산, 가상 카메라, AppModel 설정 전환·저장·손상된 값 처리,
  언어팩(세 언어가 모두 들어 있는지, 언어마다 같은 문구인지, 숫자 자리표시자·% 기호가 원문과 같은지, 번역에 한글이 남지 않았는지, 언어 선택 저장).
- **UI 테스트**(`GazeNotificationUITests`): 앱을 `-uiTesting` 모드로 띄운다 — 카메라 대신 가상 사용자(보정 중엔 화면의 점을 보고,
  그 밖엔 좌우로 오감), 알림 창 이동·권한 요청 없음, 설정은 별도 저장소. 메뉴 상태·켜고 끄기·위치 기준·미리보기,
  설정 창 네 탭의 컨트롤, 그래프 기록·마우스 선택, 보정(전체·빠른 위치 맞춤·ESC 취소)을 끝에서 끝까지, 다시 실행 후 설정 유지,
  언어 선택 → 다시 시작 안내, 영어·일본어·중국어로 띄웠을 때 메뉴와 설정 창 네 탭에 한글이 남지 않는지.
  테스트는 `-AppleLanguages (ko)` 로 띄워 시스템 언어와 관계없이 같은 문구로 확인한다.
- macOS UI 테스트에는 iOS 시뮬레이터 같은 가상 화면이 없어 로그인한 화면을 직접 조작한다. 그래서 확인을 묻고 시작한다
  (`GAZE_UI_TEST_OK=1` 이면 묻지 않음). 실행 중인 일반 GazeNotification 은 건드리지 않는다.
- Apple Development 인증서가 없으면 ad-hoc 서명 + Hardened Runtime 끔으로 빌드한다 (결과: `build/tests/*.xcresult`).

### 개발용 명령

실행 중인 앱(Debug 빌드, 또는 `defaults write party.udon.GazeNotification debugCommands -bool YES` 인 Release)에 터미널에서:

```sh
scripts/debug.sh test     # GazeNotification 이름으로 테스트 알림
scripts/debug.sh dump     # NotificationCenter AX 트리 → ~/Library/Logs/GazeNotification/ax-dump.txt
scripts/debug.sh status   # 시선·카메라·권한·단계별 처리 통계를 로그에 기록
scripts/debug.sh snapshot # 메뉴 패널을 그려 ~/Library/Logs/GazeNotification/menu.png 로 저장
scripts/debug.sh settings-performance   # 설정 창 탭을 그려 settings-<탭>.png 로 저장 (limits, ai, calibration)
scripts/debug.sh mode-light             # AI 모드 분석 방식 바꾸기 (precise, light, headPose)
scripts/debug.sh device-gpu             # Vision 연산 장치 바꾸기 (automatic, neuralEngine, gpu, cpu)
scripts/debug.sh profile-balanced       # 성능 프로필 바꾸기 (automatic, performance, balanced, saver, custom)
scripts/debug.sh snapshot-calibration   # 보정 화면을 32:9 로 그려 calibration-screen.png 로 저장 (배경 투명)
scripts/debug.sh history                # 성능 기록(최근 10분)을 performance-history.json 으로 내보내기
```

## 배포

Mac App Store 에는 올릴 수 없다 — App Store 앱은 App Sandbox 가 필수인데, 샌드박스 안에서는 손쉬운 사용(AX) API 로
다른 앱(NotificationCenter)의 창을 옮길 수 없다. 그래서 **Developer ID 서명 + 공증** 으로 직접 배포한다 (GitHub Releases).

```sh
git tag v0.2.0 && git push origin v0.2.0      # → Actions 가 테스트·빌드·서명·릴리스까지 (release.yml)

scripts/release.sh 0.2.0                      # 손으로: universal DMG 만들기 (build/release/)
scripts/publish-release.sh                    # 손으로: GitHub 릴리스 올리기 (gh 로그인 필요, DRY_RUN=1 이면 설명만 보기)
```

- `release.sh`: Apple Silicon·Intel 공용 Release 빌드 → Hardened Runtime 서명 → (가능하면) 앱·DMG 공증과 staple → DMG.
  버전은 인자(태그의 `v` 는 뗌), 빌드 번호는 커밋 수. 결과는 `GazeNotification.dmg`(홈페이지가 가리키는 고정 이름)와 `GazeNotification-<버전>.dmg`, 체크섬.
- `publish-release.sh`: 태그 `v<버전>` 릴리스를 만들고(있으면 파일 교체) 설치 안내·변경 사항(이전 태그부터의 커밋)·체크섬을 붙인다.
  홈페이지 다운로드 버튼이 `releases/latest/download/GazeNotification.dmg` 라서 **시험판으로 올리지 않는다**.
- 서명 인증서가 없으면 ad-hoc 서명으로 만든다. 받은 사람은 처음 열 때 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기** 가 필요하고,
  릴리스 설명과 홈페이지에 그 안내가 자동으로 붙는다 (릴리스 설명의 `signing: adhoc | developer-id | notarized` 를 홈페이지가 읽음).
  ad-hoc 은 빌드마다 서명이 바뀌어 업데이트 후 손쉬운 사용 권한을 다시 켜야 할 수 있다.

### 공증된 릴리스 만들기

Apple Developer Program(유료)에 가입한 뒤 저장소 **Settings → Secrets and variables → Actions** 에 다섯 개를 넣으면,
다음 태그부터 Actions 가 공증까지 하고 Gatekeeper 안내가 사라진다. 하나라도 빠져 공증을 못 하면 릴리스를 올리지 않고 실패한다.

| 이름 | 내용 |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | 키체인에서 내보낸 "Developer ID Application" 인증서+개인 키(.p12): `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | .p12 를 내보낼 때 정한 암호 |
| `NOTARY_KEY_P8_BASE64` | App Store Connect → 사용자 및 액세스 → 통합 → App Store Connect API 에서 만든 키(.p8): `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `NOTARY_KEY_ID` | 그 키의 ID |
| `NOTARY_ISSUER_ID` | 같은 화면의 Issuer ID |

손으로 공증할 때는 `xcrun notarytool store-credentials gaze` 로 한 번 저장한 뒤 `NOTARY_PROFILE=gaze scripts/release.sh 0.2.0`.

### 홈페이지

`site/` (정적 HTML·CSS·JS, 빌드 없음) → `main` 에 올리면 `pages.yml` 이 GitHub Pages 로 배포한다: <https://blog.udon.party/GazeNotification/> (계정 사이트의 사용자 지정 도메인 아래. `piorosen.github.io/GazeNotification/` 도 여기로 넘어온다)

- 한국어·English·日本語·简体中文 (`site/i18n.js`, 브라우저 언어로 고르고 `?lang=ja` 로 지정 가능).
- 최신 릴리스의 버전·크기는 GitHub API 로 읽어 다운로드 버튼 밑에 보여 준다.
- "화면 살펴보기"의 앱 화면(`site/assets/tour/<언어>/*.webp`)은 실제 앱을 언어별로 띄워 화면 밖에 그린 뒤 기능별로 자른 것이고,
  성능 그래프는 앱에서 내보낸 실제 기록(`site/assets/performance-history.json`, 1초 간격 10분)을 `site/perf.js` 가 그린다.
  다시 만들기: `scripts/site-screenshots.sh` (기록까지: `scripts/site-screenshots.sh history`, 약 13분).
- 로컬에서 보기: `python3 -m http.server -d site 8000`

CI(`ci.yml`)는 `main` 푸시와 PR 마다 단위 테스트와 언어팩 점검을 돌린다. UI 테스트는 화면을 직접 조작하므로 CI 에서 돌리지 않는다.

## 처음 사용

1. 실행하면 메뉴 막대에 👁 아이콘이 생긴다 (Dock 아이콘 없음).
2. **손쉬운 사용** 권한 허용: 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → GazeNotification 켜기.
3. **카메라** 권한 허용.
4. 메뉴에서 **시선 보정**: 화면 위쪽에 점 5개(설정에서 3~9개)가 왼쪽부터 나온다. 평소처럼 바라보면 된다 (고개를 돌려도 됨). 약 15초.
   보정 한 번으로 세 가지 분석 방식 × 세 가지 추정 모델을 모두 학습한다.
5. **테스트 알림**: 3초 뒤 알림이 온다. 그 사이 화면 왼쪽 등을 보고 있으면 그쪽에 떠야 한다.

자리를 크게 옮기거나 카메라 위치를 바꾸면 다시 보정한다.

## 메뉴의 "처리 상세 정보"

메뉴가 열려 있는 동안 1초마다(시선 계산은 프레임마다) 갱신된다. 닫혀 있을 땐 계산만 하고 화면 갱신은 하지 않는다.

| 칸 | 보여 주는 것 |
| --- | --- |
| 현재 상태 | 추적 상태(실시간/활동 중/시선 고정/자리 비움/일시 정지)와 이유, 프로필·카메라 프레임·목표/실제 처리·얼굴 검출·얼굴 감지 횟수, 실행 후 평균과 상태별 시간 비율 |
| 프레임 처리 단계 | 카메라 → 얼굴 검출 → 랜드마크(76/65개 또는 사용 안 함) → 특징 계산 → 시선 추정(고른 모델) → 스무딩(One Euro 필터). 단계별 내용·장치, 초당 횟수, 소요 시간(경과·CPU) |
| 시선 계산 | 특징 4개(코 방향·동공 위치·얼굴 위치·머리 회전)의 현재 값, 기울기(수동 배율), 기여도, 모델 출력·점별 보간·수동 조정·스무딩 후 값, 화면 위치(pt) |
| 알림 배치 | 이동기 상태, 창 확인(창 서버)·창 이동·손쉬운 사용 API 호출 횟수, 다음 알림 위치 |
| 리소스 사용량 | 초당 Vision 처리 횟수, 프레임당 시간(CPU), 앱 전체·영상 처리·메인 스레드 CPU |

## 설정 창

메뉴의 **성능 및 제한** / **보정 조정** 버튼으로 연다. 창이 가려지거나 닫히면 값 갱신을 멈춘다.

| 탭 | 내용 |
| --- | --- |
| 성능 | 최근 1/5/10분의 CPU(앱 전체·영상 처리·메인 스레드, 한도선), 처리 횟수(처리·얼굴 검출·카메라 프레임·목표), 1회 처리 시간(검출·랜드마크). 마우스를 올리면 세 그래프가 같은 시각을 가리키고 툴팁에 값·프로필·단계. 기간 평균 요약 |
| 연산 제한 | 프로필(자동/성능 우선/균형/절전/사용자 지정), 상태별 처리 횟수, 시선 고정·자리 비움 전환 시간, 알림이 표시되는 동안 활동 중 처리 횟수 사용, 얼굴 검출 간격, 영상 처리 CPU 한도, 알림 창 확인 횟수, 자리 비움 시 카메라 끄기. 값을 바꾸면 사용자 지정으로 바뀐다 |
| AI 모드 | 얼굴 분석 방식(정밀 76개 / 경량 65개 / 머리 방향만), 연산 장치(자동 / Neural Engine / GPU / CPU), 시선 추정 모델(자동 / 선형 회귀 / 곡선 회귀(3차) / 점별 보간 / 기본 추정식). 방식별 실측 처리 비용과 보정 오차, 모델별 학습·교차검증 오차 비교표 |
| 보정 조정 | 실시간 미리보기(조정 전 vs 조정 후)와 화면 상단 위치 막대, 다시 보정 · 빠른 위치 맞춤(3점으로 이동·범위만), 보정 점 개수·점당 응시 시간, 좌우 이동, 왼쪽/오른쪽 범위, 특징 가중치(0~200%), 반응 속도·빠른 움직임 반응(One Euro), 화면 구역(2~6개), 표시 중인 알림 이동 기준 |

자동 프로필: 전원 연결 → 균형, 배터리·저전력 모드·발열 높음 → 절전.
교차검증 오차는 안쪽 보정 점을 하나씩 빼고 학습해 그 점을 맞혀 본 값이다 (양 끝 점은 빼지 않음 — 외삽이 되어 보간 성능과 무관하게 나빠 보이므로).
곡선 회귀는 세제곱 항을 쓴다. 고개를 돌린 각도와 화면 위치의 관계(tan)는 좌우 대칭으로 휘어 제곱 항으로는 못 맞춘다
(합성 데이터 교차검증: 선형 3.8% · 제곱 8.3% · 세제곱 1.8%).

## 언어

한국어 · English · 日本語 · 简体中文. 메뉴의 **언어**에서 고르고 다시 시작하면 바뀐다 ("시스템 언어"면 macOS 의 언어 순서를 따른다 —
시스템 언어 목록에서 영어가 한국어보다 위에 있으면 영어로 뜬다).

- 문구는 String Catalog(`GazeNotification/Localizable.xcstrings`, 카메라 권한 안내는 `InfoPlist.xcstrings`)에 있다. 한국어가 개발 언어라 키가 곧 한국어 문구다.
- 숫자를 끼워 넣는 문구는 `"초당 \(fixed(v))회"` 처럼 숫자를 미리 글자로 만들어 넣는다 → 키 `"초당 %@회"`, 언어마다 어순을 바꿀 수 있다 (`%1$@`, `%2$@`). 초당 횟수는 `perSecond(_:)`, 짧은 나열은 `listText(_:)`(일본어·중국어는 "、").
- 새 문구를 추가하면 빌드할 때 카탈로그에 키가 생긴다. Xcode 에서 카탈로그를 열어 번역을 채우고 `scripts/check-localization.sh` 로 빠진 번역을 확인한다.
- 언어팩 추가: 프로젝트 정보 → Localizations 에 언어를 더하고 카탈로그에서 번역을 채운다. `AppLanguage` 에 항목을 더하면 메뉴에서 고를 수 있다.
- 진단 로그(`gazenotification.log`)는 개발자용이라 한국어 그대로 남긴다.

문구 규칙 (macOS 앱의 일반적인 문체):

- 버튼·메뉴 항목은 동작으로 ("다시 보정", "시스템 설정 열기"), 항목 이름은 명사구로 ("얼굴 검출 간격"), 상태 값은 "켜짐/꺼짐/허용됨/허용 안 됨/사용 안 함".
- 설명은 "~합니다.", 사용자가 할 일은 "~하세요."로 끝나는 완결된 문장. 한두 문장으로 쓰고 괄호 속 부연·예시·수치 근거는 넣지 않는다.
- 오류는 무엇을 할 수 없는지와 해결 방법을 함께: "알림 창 구조를 읽을 수 없습니다. 손쉬운 사용 권한을 확인하세요."
- 기호 `—` `→` `①` `Σ` 와 가운뎃점으로 값 이어 붙이기를 쓰지 않는다. 여러 값은 표(이름–값)나 쉼표로. 메뉴 경로는 "시스템 설정 > 알림".
- 내부 용어(ridge, yaw, RMSE, AX, UVC, 창 서버, Vision API 이름)는 화면에 쓰지 않는다. 영어 단어 뒤 조사는 붙여 쓴다 ("GazeNotification을").

## 메뉴 설정

| 항목 | 설명 |
| --- | --- |
| 위치 기준 | 시선 / 마우스 커서 (카메라 없이 쓰는 대안) |
| 표시 중인 알림을 시선에 따라 이동 | 끄면 처음 뜰 때만 옮긴다 |
| 화면 상단에 알림 위치 표시 | 추정 시선 위치를 얇은 막대로 표시 (보정 확인용) |
| 언어 | 시스템 언어 / 한국어 / English / 日本語 / 简体中文 (다시 시작하면 적용) |
| 진단 > 알림 창 구조 저장 | `~/Library/Logs/GazeNotification/ax-dump.txt` (알림 본문은 길이만 기록) |

로그: `~/Library/Logs/GazeNotification/gazenotification.log`. 처음 잡힌 배너의 AX 구조는 `ax-dump-banner.txt` 에 저장된다.

## 코드 구조

```
GazeNotification/
  App/            GazeNotificationApp (MenuBarExtra), AppModel (전체 연결·설정·정책·CPU 상한)
  Support/        AppLanguage (언어 선택), AppEnvironment (실행 환경), Formatting (번역 문구용 숫자 글자), Log, …
  Camera/         CameraService — 캡처 세션, 장치 선택, 포맷·장치 fps·시간 기준 처리·fps 감시,
                  FrameScheduling (처리 간격·감시·fps 선택), SimulatedFaceSource (UI 테스트용 가상 카메라)
  Gaze/           FaceFeatureExtractor (Vision, 분석 방식·추적), AIMode (방식·장치·모델 종류),
                  GazeModel (기본식·ridge·One Euro), GazeEstimators (모델·교차검증·보정 묶음), GazeAdjustment (수동 보정)
  Performance/    PerformanceSettings (프로필·제한값), PowerMonitor (전원·발열·화면), PerformanceHistory (기록·CPU 측정),
                  CPUGovernor (CPU 상한)
  Calibration/    전체 화면 보정 UI + 샘플 수집 (전체 보정 · 빠른 위치 맞춤)
  Notifications/  NotificationMover (사전 배치·창 서버 감시·원위치 복구), AXHelpers
  Overlay/        알림 위치 표시 막대
  UI/             메뉴 패널, 처리 상세 정보(PipelineView), 카메라 미리보기,
                  설정 창(SettingsWindow · PerformanceView · LimitsView · AIModeView · CalibrationAdjustView)
  Assets.xcassets 앱 아이콘 (swift scripts/make-icon.swift 로 다시 그림)
Config/           Info.plist, entitlements (샌드박스 끔 — 다른 앱 창을 옮기려면 필요)
GazeNotification/Localizable.xcstrings, InfoPlist.xcstrings   언어팩 (String Catalog)
GazeNotificationTests/    단위 테스트 (Swift Testing)
GazeNotificationUITests/  UI 테스트 (XCUITest)
scripts/          run · test · release · publish-release · check-localization · debug
site/             홈페이지 (GitHub Pages)
.github/workflows/ ci (단위 테스트) · release (태그 → DMG → 릴리스) · pages (홈페이지)
```

## 한계

- 시선은 **가로 위치만** 추정한다 (알림은 항상 화면 상단).
- 웹캠 기반이라 정밀한 시선 추적은 아니다. 머리 방향 위주로 추정하며, 32:9 화면을 3~5구역 정도로 구분하는 수준을 목표로 한다.
- 알림 창 이동은 비공개 AX 구조(`AXNotificationCenterBanner` subrole)에 의존하므로 macOS 업데이트로 깨질 수 있다. 그럴 땐 AX 구조 덤프로 확인한다.
- 추적하는 동안 카메라가 켜져 있다 (카메라 표시등 켜짐). 화면이 꺼지거나 잠기면, 그리고 설정에 따라 오래 자리를 비우면 끈다.
- C922 처럼 5fps 밑으로 내려가지 않는 카메라는 처리 횟수를 줄여도 5fps 만큼의 카메라 수신 비용은 그대로다.
- "머리 방향만" 방식은 눈만 움직여 보는 것은 따라가지 못한다. 추적 프레임은 마지막 검출 때의 yaw 를 쓴다 (검출 간격만큼 늦을 수 있음).
- 앱이 비정상 종료되면 알림 창이 옮겨진 자리에 남는다. 다시 실행하거나 `killall NotificationCenter` 로 원위치된다.

## 라이선스

MIT — [LICENSE](LICENSE)
