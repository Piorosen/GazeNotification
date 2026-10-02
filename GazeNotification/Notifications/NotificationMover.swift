import AppKit
import ApplicationServices

private let notificationCenterBundleID = "com.apple.notificationcenterui"
/// 배너(일반 알림)와 알림(버튼이 있는 지속형)의 AX subrole
private let bannerSubroles: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]
/// 알림 센터 패널(위젯 목록)이 열려 있을 때 위젯 요소의 AXIdentifier 접두사
private let widgetIdentifierPrefix = "widget-local"

/// NotificationCenter 의 알림 창을 Accessibility API 로 옮겨, 배너가 `targetProvider` 의 가로 위치에 뜨게 한다.
///
/// macOS 15 구조: 알림은 화면 전체 크기의 투명 창(AXSystemDialog) 안에서 오른쪽 끝(창 오른쪽 − 여백 − 배너 폭)으로
/// 슬라이드해 들어온다. 이 창은 알림이 없을 때도 유지되므로
/// - **알림이 없을 때 미리 창을 옮겨 두면(사전 배치)** 다음 알림이 처음부터 시선 위치에 뜬다 (지연·떨림 없음).
/// - 배너 자체가 아니라 창의 "배너 슬롯" 위치를 제어하므로 슬라이드 인/아웃 애니메이션과 싸우지 않는다.
///
/// 자원 절약: 알림이 없을 땐 AX 호출 없이 창 서버의 표시 여부(CGWindowList)만 가볍게 확인한다.
@MainActor
final class NotificationMover {
    /// 알림 중심이 놓일 화면 가로 위치 (0 = 왼쪽 끝, 1 = 오른쪽 끝). nil 이면 옮기지 않는다.
    var targetProvider: (@MainActor () -> Double?)?
    /// 떠 있는 알림이 시선을 따라 움직일지
    var followWhileVisible = true
    /// 떠 있는 알림은 목표가 화면 폭의 이 비율 이상 바뀔 때만 따라간다 (떨림 방지)
    var followThreshold: Double = 0.08
    /// 사람이 읽을 수 있는 이동 이벤트 설명
    var onMove: (@MainActor (String) -> Void)?
    /// 알림 창이 화면에 나타나거나 사라질 때 (알림이 떠 있는 동안 추적 속도를 올리는 데 사용)
    var onVisibilityChange: (@MainActor (Bool) -> Void)?

    /// 알림이 없을 때 창 서버에 표시 여부를 묻는 횟수/s. 낮추면 전력이 줄고, 알림 센터 패널을 열 때 원위치가 조금 늦어진다.
    var idleCheckHz: Double = 12 {
        didSet {
            idleInterval = 1 / idleCheckHz.clamped(to: 1...60)
            if isRunning, !isPaused, timerInterval != idleInterval, animation == nil, !wasOnscreen,
               CACurrentMediaTime() >= fastUntil {
                scheduleTimer(idleInterval)
            }
        }
    }

    /// 화면이 꺼지거나 잠겼을 때 감시를 멈춘다 (창 위치는 그대로 둔다)
    var isPaused = false {
        didSet {
            guard isPaused != oldValue, isRunning else { return }
            if isPaused {
                timer?.invalidate()
                timer = nil
                timerInterval = 0
                animation = nil
            } else {
                scheduleTimer(idleInterval)
                tick()
            }
        }
    }

    private(set) var isRunning = false

    // NotificationCenter 연결
    private var app: AXUIElement?
    private var pid: pid_t = 0
    private var observer: AXObserver?
    private var launchObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var lastAttachAttempt: Date = .distantPast

    // 창 서버 쪽 창 ID (표시 여부 확인용)
    private var windowIDs: [CGWindowID] = []
    private var lastWindowIDRefresh: CFTimeInterval = 0

    /// 배너가 들어 있는 전체 화면 창
    private var container: Container?
    private struct Container {
        let window: AXUIElement
        /// 창이 원래 덮는 화면 (AX 좌표). 복구 위치 = screen.minX
        let screen: CGRect
        let width: CGFloat
        let y: CGFloat
        var bannerWidth: CGFloat = 344
        /// 창 오른쪽 끝과 배너 오른쪽 끝 사이 여백 (측정해서 갱신)
        var rightMargin: CGFloat = 16
        /// 현재 창 위치 기준으로 배너가 멈추는 x. nil = 원위치(모름)
        var slotX: CGFloat?
    }

    private var bannerVisible = false
    private var panelOpen = false
    private var wasOnscreen = false
    private var onscreenSince: CFTimeInterval = 0
    private var fastUntil: CFTimeInterval = 0
    private var lastFullScan: CFTimeInterval = 0
    private var lastPreposition: CFTimeInterval = 0
    private var marginCheckAt: CFTimeInterval?
    private var animation: Animation?
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var dumpedBannerTree = false
    private var dumpedMissingBanner = false
    private var reportedPlacementFailure = false

    // 메뉴 표시용 누적 카운터
    private var tickCount = 0
    private var windowCheckCount = 0
    private var moveCount = 0

    private struct Animation {
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval
    }

    private var idleInterval: TimeInterval = 1.0 / 12.0     // 표시 여부만 확인 (AX 호출 없음)
    private let visibleInterval: TimeInterval = 1.0 / 5.0   // 알림 표시 중: 따라가기 판단
    private let fastInterval: TimeInterval = 1.0 / 30.0     // 알림이 막 떴을 때
    private let animationInterval: TimeInterval = 1.0 / 60.0
    private let animationDuration: CFTimeInterval = 0.22
    private let edgeMargin: CGFloat = 16
    /// 알림이 없을 때 사전 배치를 다시 하는 최소 변화량 (화면 폭 비율)
    private let prepositionThreshold: Double = 0.04

    // MARK: - 수명

    func start() {
        guard !isRunning else { return }
        isRunning = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let launched = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard launched?.bundleIdentifier == notificationCenterBundleID else { return }
            MainActor.assumeIsolated { self?.reattach() }
        }

        // 해상도·배치가 바뀌면 NotificationCenter 가 알림 창 크기를 바꾸므로 다시 잡는다
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        attachIfNeeded()
        guard !isPaused else { return }
        scheduleTimer(idleInterval)
        tick()
    }

    private func screensChanged() {
        let screens = NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ", ")
        Log.info("화면 구성 변경 (\(screens)) — 알림 창 다시 확보")
        container = nil
        bannerVisible = false
        animation = nil
        windowIDs = []
        // 창이 새 크기로 바뀐 뒤 찾도록 잠시 후 재탐색
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.container == nil, let app = self.app else { return }
                for window in AX.windows(of: app).windows where self.container == nil {
                    self.adoptContainerIfFullScreen(window)
                }
            }
        }
    }

    /// 중지하면서 알림 창을 원래 위치(오른쪽 위)로 되돌린다.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        timerInterval = 0
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        restoreContainer()
        detach()
        if wasOnscreen {
            wasOnscreen = false
            onVisibilityChange?(false)
        }
    }

    // MARK: - NotificationCenter 연결

    private func attachIfNeeded() {
        guard app == nil, Date().timeIntervalSince(lastAttachAttempt) > 1 else { return }
        lastAttachAttempt = Date()

        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: notificationCenterBundleID).first else {
            Log.error("NotificationCenter 프로세스를 찾지 못함")
            return
        }
        pid = running.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        app = element
        windowIDs = []
        lastWindowIDRefresh = 0

        var newObserver: AXObserver?
        if AXObserverCreate(pid, axObserverCallback, &newObserver) == .success, let newObserver {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(newObserver, element, kAXWindowCreatedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
            observer = newObserver
        }

        // 알림 창은 알림이 없어도 존재하므로 바로 찾아 두면 첫 알림부터 사전 배치된다.
        for window in AX.windows(of: element).windows where container == nil {
            adoptContainerIfFullScreen(window)
        }
        Log.info("NotificationCenter(pid \(pid)) 연결, 알림 창 \(container == nil ? "미발견(첫 알림 때 탐색)" : "발견")")
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        app = nil
        container = nil
        bannerVisible = false
        animation = nil
    }

    private func reattach() {
        Log.info("NotificationCenter 재시작 감지 — 재연결")
        detach()
        lastAttachAttempt = .distantPast
        attachIfNeeded()
    }

    fileprivate func windowCreated() {
        guard isRunning, !isPaused else { return }
        fastUntil = CACurrentMediaTime() + 1.5
        if timerInterval != fastInterval { scheduleTimer(fastInterval) }
        tick()
    }

    private func scheduleTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        timerInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 느린 주기는 다른 타이머와 합쳐 깨어나도록 허용 (전력 절약)
        timer.tolerance = interval >= visibleInterval ? interval * 0.3 : interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - 주기 처리

    private func tick() {
        guard isRunning, !isPaused else { return }
        tickCount += 1
        if app == nil {
            attachIfNeeded()
            if app == nil { return }
        }
        let now = CACurrentMediaTime()

        let onscreen = notificationWindowsOnscreen(now: now)
        if onscreen && !wasOnscreen {
            onscreenSince = now
            fastUntil = max(fastUntil, now + 1.0)
        }
        if onscreen != wasOnscreen { onVisibilityChange?(onscreen) }
        wasOnscreen = onscreen

        if onscreen || now < fastUntil {
            handleVisible(now: now)
        } else {
            if bannerVisible || panelOpen {
                bannerVisible = false
                panelOpen = false
                animation = nil
            }
            preposition(now: now)
        }

        let wanted: TimeInterval
        if animation != nil {
            wanted = animationInterval
        } else if now < fastUntil {
            wanted = fastInterval
        } else if onscreen {
            wanted = visibleInterval
        } else {
            wanted = idleInterval
        }
        if wanted != timerInterval { scheduleTimer(wanted) }
    }

    /// 창 서버에 NotificationCenter 창이 화면에 보이는지 묻는다 (AX IPC 보다 훨씬 가벼움).
    private func notificationWindowsOnscreen(now: CFTimeInterval) -> Bool {
        windowCheckCount += 1
        if windowIDs.isEmpty || now - lastWindowIDRefresh > 5 {
            lastWindowIDRefresh = now
            let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            windowIDs = all.compactMap { info in
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid else { return nil }
                return info[kCGWindowNumber as String] as? CGWindowID
            }
        }
        guard !windowIDs.isEmpty else { return true } // 모르면 AX 로 직접 확인
        var values: [UnsafeRawPointer?] = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &values, values.count, nil),
              let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return true }
        return descriptions.contains { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
    }

    // MARK: - 알림이 보일 때

    /// 배너를 한 번 찾은 뒤에는 AX 를 거의 읽지 않는다: 슬롯 위치는 시선으로 계산되고,
    /// 사라짐은 창 서버(표시 여부)로 알 수 있다. 패널 열림·스택 변화만 2초마다 확인.
    private func handleVisible(now: CFTimeInterval) {
        guard let app else { return }

        let scanEvery: CFTimeInterval = bannerVisible ? 2.0 : (now < fastUntil ? 0.05 : 1.0)
        if now - lastFullScan >= scanEvery {
            lastFullScan = now
            let result = scanWindows(of: app)

            if result.panel {
                if !panelOpen {
                    panelOpen = true
                    animation = nil
                    restoreContainer()
                    Log.info("알림 센터 패널 열림 — 알림 창 원위치")
                }
                bannerVisible = false
                return
            }
            panelOpen = false

            guard let (window, banner) = result.banner, let frame = AX.frame(banner), frame.width > 40 else {
                bannerVisible = false
                if !dumpedMissingBanner, wasOnscreen, now - onscreenSince > 1.5 {
                    dumpedMissingBanner = true
                    let url = dumpAllWindows(named: "ax-dump-nobanner.txt")
                    Log.error("알림 창이 보이는데 배너를 찾지 못함 — \(url?.path ?? "덤프 실패")")
                }
                return
            }
            if container.map({ !CFEqual($0.window, window) }) ?? true { adoptContainer(window) }
            container?.bannerWidth = frame.width
            if !dumpedBannerTree {
                dumpedBannerTree = true
                dumpWindow(window, name: "ax-dump-banner.txt")
            }
            if !bannerVisible {
                bannerVisible = true
                bannerAppeared(frame: frame, now: now)
            }
            if let checkAt = marginCheckAt, now >= checkAt {
                marginCheckAt = nil
                calibrateMargin(bannerFrame: frame)
            }
        }

        guard bannerVisible, let container else { return }

        if let checkAt = marginCheckAt, now >= checkAt {
            // 여백 측정만을 위해 배너 위치를 한 번 읽는다
            marginCheckAt = nil
            if let banner = scanWindows(of: app).banner?.1, let frame = AX.frame(banner) {
                calibrateMargin(bannerFrame: frame)
            }
        }

        if let animation {
            step(animation, now: now)
        } else if let desired = desiredSlotX() {
            if container.slotX == nil {
                // 알림이 뜰 때 시선 정보가 없었던 경우 등 → 정보가 생기는 즉시 배치
                placeSlot(at: desired)
            } else if followWhileVisible, let slot = container.slotX,
                      abs(desired - slot) > CGFloat(followThreshold) * container.screen.width {
                animation = Animation(from: slot, to: desired, start: now)
            }
        }
    }

    private func bannerAppeared(frame: CGRect, now: CFTimeInterval) {
        marginCheckAt = now + 0.9 // 슬라이드 인이 끝난 뒤 실제 여백 측정
        guard let desired = desiredSlotX(), let container else { return }
        let normalized = targetProvider?() ?? 0
        if let slot = container.slotX, abs(slot - desired) < CGFloat(followThreshold) * container.screen.width {
            onMove?(String(localized: "새 알림 → 화면 \(Int((normalized * 100).rounded()))% 위치 (사전 배치)"))
            Log.info("새 알림: 사전 배치 적중 (슬롯 \(Int(slot)), 목표 \(Int(desired)))")
            return
        }
        // 사전 배치가 없거나 빗나감 → 즉시 이동 (막 슬라이드 인 하는 중이라 점프가 덜 보임)
        if placeSlot(at: desired) {
            onMove?(String(localized: "새 알림 → 화면 \(Int((normalized * 100).rounded()))% 위치"))
            Log.info("새 알림: 즉시 이동 → 슬롯 \(Int(desired)) (배너 \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))")
        }
    }

    /// 슬라이드 인이 끝난 배너의 실제 위치로 창 오른쪽 여백을 측정해 이후 예측에 쓴다.
    private func calibrateMargin(bannerFrame: CGRect) {
        guard var container, let window = AX.frame(container.window) else { return }
        let measured = window.maxX - bannerFrame.maxX
        guard measured >= 0, measured < 200, abs(measured - container.rightMargin) > 1 else { return }
        Log.info("알림 오른쪽 여백 측정: \(Int(container.rightMargin)) → \(Int(measured))")
        container.rightMargin = measured
        self.container = container
        if let desired = desiredSlotX() { placeSlot(at: desired) }
    }

    private func step(_ animation: Animation, now: CFTimeInterval) {
        let t = min(1, (now - animation.start) / animationDuration)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        placeSlot(at: animation.from + (animation.to - animation.from) * CGFloat(eased))
        if t >= 1 { self.animation = nil }
    }

    // MARK: - 알림이 없을 때: 사전 배치

    private func preposition(now: CFTimeInterval) {
        guard !panelOpen, now - lastPreposition >= 0.25, let container, let desired = desiredSlotX() else { return }
        if let slot = container.slotX, abs(slot - desired) < CGFloat(prepositionThreshold) * container.screen.width {
            return
        }
        lastPreposition = now
        if !placeSlot(at: desired), !reportedPlacementFailure {
            reportedPlacementFailure = true
            Log.error("알림 창 사전 배치 실패 — 알림이 뜬 뒤 옮기는 방식으로 동작")
        }
    }

    // MARK: - 위치 계산 / 이동

    /// 목표 배너 x (화면 안으로 제한)
    private func desiredSlotX() -> CGFloat? {
        guard let container, let normalized = targetProvider?() else { return nil }
        return Self.slotX(normalized: normalized, screen: container.screen, bannerWidth: container.bannerWidth,
                          edgeMargin: edgeMargin)
    }

    /// 배너 가운데가 화면 가로 위치 `normalized` 에 오도록 하는 배너 왼쪽 x (화면 양 끝 여백 안으로 제한)
    nonisolated static func slotX(normalized: Double, screen: CGRect, bannerWidth width: CGFloat, edgeMargin: CGFloat) -> CGFloat {
        let center = screen.minX + CGFloat(normalized.clamped(to: 0...1)) * screen.width
        let minX = screen.minX + edgeMargin
        let maxX = max(minX, screen.maxX - width - edgeMargin)
        return (center - width / 2).clamped(to: minX...maxX)
    }

    /// 배너가 `slotX` 에 멈추게 하는 창 x. 배너는 창 오른쪽 끝 − 여백 − 배너 폭 자리로 슬라이드해 들어온다.
    nonisolated static func windowX(slotX: CGFloat, rightMargin: CGFloat, bannerWidth: CGFloat, windowWidth: CGFloat) -> CGFloat {
        slotX + rightMargin + bannerWidth - windowWidth
    }

    /// 배너가 멈추는 위치가 x 가 되도록 창을 옮긴다. 창 폭/높이는 고정이므로 AX 호출 1회.
    @discardableResult
    private func placeSlot(at x: CGFloat) -> Bool {
        guard var container else { return false }
        let windowX = Self.windowX(slotX: x, rightMargin: container.rightMargin, bannerWidth: container.bannerWidth,
                                   windowWidth: container.width)
        let result = AX.setPosition(container.window, CGPoint(x: windowX, y: container.y))
        guard result == .success else {
            if result == .invalidUIElement { self.container = nil }
            return false
        }
        container.slotX = x
        self.container = container
        moveCount += 1
        return true
    }

    private func restoreContainer() {
        guard var container else { return }
        if AX.setPosition(container.window, CGPoint(x: container.screen.minX, y: container.y)) == .success {
            container.slotX = nil
            self.container = container
        }
    }

    private func adoptContainer(_ window: AXUIElement) {
        guard let frame = AX.frame(window) else { return }
        let screens: [CGRect] = NSScreen.screens.map(\.axFrame)
        let matching: CGRect? = screens.first { (rect: CGRect) -> Bool in
            abs(rect.width - frame.width) < 2 && abs(rect.height - frame.height) < 2
        }
        let screen: CGRect = matching ?? NSScreen.main?.axFrame ?? frame
        let previous = container
        container = Container(window: window, screen: screen, width: frame.width, y: frame.minY,
                              bannerWidth: previous?.bannerWidth ?? 344,
                              rightMargin: previous?.rightMargin ?? edgeMargin, slotX: nil)
        Log.info("알림 창 확보: \(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY))")
    }

    /// 알림이 없을 때도 존재하는 전체 화면 AXSystemDialog 창이면 컨테이너로 채택
    private func adoptContainerIfFullScreen(_ window: AXUIElement) {
        guard AX.string(window, kAXSubroleAttribute) == "AXSystemDialog", let frame = AX.frame(window),
              NSScreen.screens.contains(where: { abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2 })
        else { return }
        adoptContainer(window)
    }

    /// 모든 창에서 배너와 위젯(패널)을 찾는다.
    private func scanWindows(of app: AXUIElement) -> (banner: (AXUIElement, AXUIElement)?, panel: Bool) {
        var found: (AXUIElement, AXUIElement)?
        for window in AX.windows(of: app).windows {
            let result = scan(window)
            if result.isPanel { return (nil, true) }
            if found == nil, let banner = result.banner { found = (window, banner) }
        }
        return (found, false)
    }

    private func scan(_ window: AXUIElement) -> (banner: AXUIElement?, isPanel: Bool) {
        var banner: AXUIElement?
        var isPanel = false
        var visited = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard !isPanel, visited < 600, depth <= 14 else { return }
            visited += 1
            if let identifier = AX.string(element, kAXIdentifierAttribute), identifier.hasPrefix(widgetIdentifierPrefix) {
                isPanel = true
                return
            }
            if banner == nil, let subrole = AX.string(element, kAXSubroleAttribute), bannerSubroles.contains(subrole) {
                banner = element
                return
            }
            for child in AX.children(element) { visit(child, depth: depth + 1) }
        }

        visit(window, depth: 0)
        return (banner, isPanel)
    }

    // MARK: - 상태 (메뉴 표시용)

    func status() -> MoverStatus {
        let mode: MoverStatus.Mode
        if !isRunning {
            mode = .stopped
        } else if panelOpen {
            mode = .panel
        } else if animation != nil {
            mode = .following
        } else if CACurrentMediaTime() < fastUntil {
            mode = .arriving
        } else if bannerVisible {
            mode = .visible
        } else {
            mode = .idle
        }
        return MoverStatus(mode: mode, tickHz: timerInterval > 0 ? 1 / timerInterval : 0,
                           containerFound: container != nil, slotX: container?.slotX.map(Double.init),
                           screenMinX: Double(container?.screen.minX ?? 0),
                           screenWidth: Double(container?.screen.width ?? 0),
                           ticks: tickCount, windowChecks: windowCheckCount, moves: moveCount,
                           axCalls: AX.callCount)
    }

    // MARK: - 진단

    /// 현재 NotificationCenter 의 모든 창 AX 트리를 파일로 저장.
    @discardableResult
    func dumpAllWindows(named name: String = "ax-dump.txt") -> URL? {
        attachIfNeeded()
        guard let app else { return nil }
        var output = header()
        for (index, window) in AX.windows(of: app).windows.enumerated() {
            output += "\n=== window \(index) ===\n"
            AX.describe(window, into: &output)
        }
        return Log.writeDump(named: name, contents: output)
    }

    private func dumpWindow(_ window: AXUIElement, name: String) {
        var output = header()
        AX.describe(window, into: &output)
        if let url = Log.writeDump(named: name, contents: output) {
            Log.info("배너 AX 구조 저장: \(url.path)")
        }
    }

    private func header() -> String {
        let screens = NSScreen.screens.map { "\($0.localizedName) ax=\($0.axFrame)" }.joined(separator: ", ")
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let slot = container?.slotX.map { "\(Int($0))" } ?? "원위치"
        return "NotificationCenter AX dump @ \(Date())\nmacOS \(os)\nscreens: \(screens)\nslot: \(slot)\n\n"
    }
}

/// AXObserver 콜백 (메인 런루프에서 호출됨)
private let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let mover = Unmanaged<NotificationMover>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { mover.windowCreated() }
}

struct MoverStatus: Equatable {
    enum Mode: String {
        case stopped, idle, arriving, visible, following, panel

        var title: String {
            switch self {
            case .stopped: String(localized: "중지됨")
            case .idle: String(localized: "대기 — 알림 없음, 창을 시선 위치에 미리 배치")
            case .arriving: String(localized: "알림 막 뜸 — 빠르게 확인 중")
            case .visible: String(localized: "알림 표시 중")
            case .following: String(localized: "시선을 따라 이동 중")
            case .panel: String(localized: "알림 센터 패널 열림 — 원위치")
            }
        }
    }

    var mode: Mode
    var tickHz: Double
    var containerFound: Bool
    var slotX: Double?
    var screenMinX: Double
    var screenWidth: Double
    // 누적 카운터 (초당 값은 두 시점의 차이로 계산)
    var ticks: Int
    var windowChecks: Int
    var moves: Int
    var axCalls: Int
}
