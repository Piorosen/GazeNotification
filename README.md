# GazeNotification

메뉴 막대 앱 **GazeNoti** — 32:9 같은 초광폭 모니터에서 macOS 알림이 항상 오른쪽 위에 떠서 못 보는 문제를 해결하는 메뉴 막대 앱.
웹캠으로 얼굴·눈 방향을 추적해 **지금 보고 있는 가로 위치**의 화면 상단으로 알림 배너를 옮긴다.

## 동작 방식

```
카메라(AVFoundation, 800x448 비압축, 5~10fps)
  → Vision 얼굴/랜드마크 (코끝, 눈, 동공) — 신경망은 Neural Engine(ANE) 에서 실행
  → 특징: 코 오프셋(머리 yaw), 동공 오프셋, 얼굴 x, Vision yaw
  → 보정 모델(ridge 회귀) → One Euro 필터 → 시선 x (0…1)
  → NotificationMover: NotificationCenter 의 알림 창을 Accessibility API 로 평행 이동
```

- macOS 15 의 알림은 화면 전체 크기의 투명 창 안에서 오른쪽 끝으로 슬라이드해 들어온다. 이 창은 알림이 없어도 유지되므로
  **알림이 없을 때 미리 창을 시선 위치로 옮겨 둔다(사전 배치)** → 다음 알림이 처음부터 보고 있는 곳에 뜬다.
- 배너가 아니라 창의 "배너 슬롯"을 움직이므로 시스템의 슬라이드 인/아웃 애니메이션과 싸우지 않는다.
- 떠 있는 동안 시선이 화면 폭의 8% 이상 옮겨가면 부드럽게 따라간다(옵션).
- 알림 센터 패널(위젯 화면)이 열리면, 그리고 앱을 끄거나 비활성화하면 창을 원래 위치로 되돌린다.
- 카메라 영상은 메모리에서만 처리하고 저장하거나 전송하지 않는다.

## 자원 사용

측정값 (M4 Max, C922, `ps` 누적 CPU 시간 기준, 100% = 코어 1개):

| | 처음 버전 | 현재 |
| --- | --- | --- |
| GazeNoti (얼굴 있음) | 43.8% | 5.7~8.9% |
| GazeNoti (자리 비움) | — | 약 3.4% |
| UVCAssistant (카메라 드라이버) | 5.0% | 2.6% |
| Vision 프레임당 CPU | — | 4.9ms (ANE 대기 포함 wall 20ms) |

줄인 방법:

- **카메라 포맷 직접 지정**: 1920x1080 MJPEG(디코딩 필요)를 720p 로 줄이던 것을 800x448 비압축(yuvs)으로. 출력 크기도 고정해 추가 스케일링 없음.
- **장치 프레임레이트를 상황별로 조절**: 보정·카메라 미리보기 10fps / 평소 5fps / 시선이 3초 멈춤 2.5fps / 얼굴 없음 1.7fps.
  메뉴를 여는 것만으로는 속도를 바꾸지 않는다 (메뉴에 보이는 값 = 실제 동작).
- **Vision 신경망 단계를 Neural Engine 에 고정** (`setComputeDevice`), 얼굴 검출 결과를 랜드마크 요청에 넘겨 중복 검출 제거.
- **알림 창 감시는 창 서버 조회로**: 알림이 없을 땐 AX 호출 없이 `CGWindowListCreateDescriptionFromArray` 로 표시 여부만 확인. 알림이 떠 있을 때도 AX 는 2초에 한 번만 읽는다.
- **UI 는 메뉴가 열려 있을 때만 갱신** (SwiftUI 재계산 없음).

측정해 보고 효과가 없어서 채택하지 않은 것: 출력 픽셀 포맷(420f/yuvs/BGRA), 65점 랜드마크, 해상도 640x360, Release 최적화(모두 차이 1% 이내).

## 요구 사항

- macOS 14 이상 (개발 환경: macOS 15.6, Xcode 16.4)
- 모니터 위 중앙에 둔 웹캠 (C922 등). 카메라 목록에서 가상 카메라(OBS)는 자동 선택에서 뒤로 밀린다.

## 빌드 / 실행

```sh
scripts/run.sh            # Debug 빌드 → 서명 → 실행
scripts/run.sh Release    # 평소 사용
open GazeNoti.xcodeproj   # Xcode 에서 ⌘R (팀 서명이 될 때)
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
tccutil reset Accessibility party.udon.GazeNoti
tccutil reset Camera party.udon.GazeNoti
```

### 개발용 명령

실행 중인 앱(Debug 빌드, 또는 `defaults write party.udon.GazeNoti debugCommands -bool YES` 인 Release)에 터미널에서:

```sh
scripts/debug.sh test     # GazeNoti 이름으로 테스트 알림
scripts/debug.sh dump     # NotificationCenter AX 트리 → ~/Library/Logs/GazeNoti/ax-dump.txt
scripts/debug.sh status   # 시선·카메라·권한·단계별 처리 통계를 로그에 기록
scripts/debug.sh snapshot # 메뉴 패널을 그려 ~/Library/Logs/GazeNoti/menu.png 로 저장
```

## 처음 사용

1. 실행하면 메뉴 막대에 👁 아이콘이 생긴다 (Dock 아이콘 없음).
2. **손쉬운 사용** 권한 허용: 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → GazeNoti 켜기.
3. **카메라** 권한 허용.
4. 메뉴에서 **시선 보정**: 화면 위쪽에 점 5개가 왼쪽부터 나온다. 평소처럼 바라보면 된다 (고개를 돌려도 됨). 약 15초.
5. **테스트 알림**: 3초 뒤 알림이 온다. 그 사이 화면 왼쪽 등을 보고 있으면 그쪽에 떠야 한다.

자리를 크게 옮기거나 카메라 위치를 바꾸면 다시 보정한다.

## 메뉴의 "AI 연산 상세"

메뉴가 열려 있는 동안 1초마다(시선 계산은 프레임마다) 갱신된다. 닫혀 있을 땐 계산만 하고 화면 갱신은 하지 않는다.

| 칸 | 보여 주는 것 |
| --- | --- |
| 지금 하는 일 | 추적 속도 단계(실시간/평소/절전/자리 비움)와 이유, 카메라 fps·처리 간격·AI 추론 주기, 실제 측정한 받은/처리/얼굴 프레임 수, 실행 후 평균 처리 횟수와 단계별 시간 비율 |
| 1프레임 처리 순서 | ① 카메라 → ② 얼굴 검출(ANE) → ③ 랜드마크 76점(ANE) → ④ 특징 계산 → ⑤ 선형 회귀 → ⑥ One Euro 필터. 단계별 초당 횟수, 1회 시간(경과·CPU) |
| 시선 계산 | 특징 4개(코 방향·동공 위치·얼굴 위치·머리 yaw)의 현재 값, 기울기, x 기여도와 합산 과정 → 필터 후 x → 화면 pt |
| 알림 배치 | 이동기 상태, 창 서버 확인·AX 호출·창 이동 횟수/s, 다음 알림이 뜰 x |
| 비용 | 초당 신경망 추론 횟수, AI 파이프라인 CPU, 프레임당 시간 중 CPU/ANE 대기, 앱 전체 CPU |

## 메뉴 설정

| 항목 | 설명 |
| --- | --- |
| 위치 기준 | 시선 / 마우스 커서 (카메라 없이 쓰는 대안) |
| 알림이 떠 있는 동안 계속 따라오기 | 끄면 처음 뜰 때만 옮긴다 |
| 화면 상단에 알림 위치 표시 | 추정 시선 위치를 얇은 막대로 표시 (보정 확인용) |
| 진단 → 알림 창 AX 구조 저장 | `~/Library/Logs/GazeNoti/ax-dump.txt` (알림 본문은 길이만 기록) |

로그: `~/Library/Logs/GazeNoti/gazenoti.log`. 처음 잡힌 배너의 AX 구조는 `ax-dump-banner.txt` 에 저장된다.

## 코드 구조

```
GazeNoti/
  App/            GazeNotiApp (MenuBarExtra), AppModel (전체 연결·설정)
  Camera/         CameraService — 캡처 세션, 장치 선택, 포맷·장치 fps·처리 간격 조절
  Gaze/           FaceFeatureExtractor (Vision), GazeModel (기본식·ridge 보정·One Euro)
  Calibration/    전체 화면 보정 UI + 샘플 수집
  Notifications/  NotificationMover (사전 배치·창 서버 감시·원위치 복구), AXHelpers
  Overlay/        알림 위치 표시 막대
  UI/             메뉴 패널, AI 연산 상세(PipelineView), 카메라 미리보기
Config/           Info.plist, entitlements (샌드박스 끔 — 다른 앱 창을 옮기려면 필요)
```

## 한계

- 시선은 **가로 위치만** 추정한다 (알림은 항상 화면 상단).
- 웹캠 기반이라 정밀한 시선 추적은 아니다. 머리 방향 위주로 추정하며, 32:9 화면을 3~5구역 정도로 구분하는 수준을 목표로 한다.
- 알림 창 이동은 비공개 AX 구조(`AXNotificationCenterBanner` subrole)에 의존하므로 macOS 업데이트로 깨질 수 있다. 그럴 땐 AX 구조 덤프로 확인한다.
- 추적하는 동안 카메라가 계속 켜져 있다 (카메라 표시등 켜짐).
- 앱이 비정상 종료되면 알림 창이 옮겨진 자리에 남는다. 다시 실행하거나 `killall NotificationCenter` 로 원위치된다.

## 라이선스

MIT — [LICENSE](LICENSE)
