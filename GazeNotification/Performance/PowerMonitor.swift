import AppKit
import IOKit.ps

/// 전원·발열·화면 상태
struct PowerState: Equatable {
    var onBattery = false
    /// 배터리 잔량 % (배터리가 없으면 nil)
    var batteryLevel: Int?
    var lowPowerMode = false
    var thermal: ProcessInfo.ThermalState = .nominal
    /// 디스플레이가 꺼졌거나 화면이 잠겼거나 시스템이 잠자기 중 — 카메라를 쓸 이유가 없다
    var screenUnavailable = false

    var powerText: String {
        guard onBattery else { return batteryLevel.map { "전원 연결 (\($0)%)" } ?? "전원 연결" }
        return batteryLevel.map { "배터리 \($0)%" } ?? "배터리"
    }

    var thermalText: String {
        switch thermal {
        case .nominal: "정상"
        case .fair: "약간 높음"
        case .serious: "높음"
        case .critical: "매우 높음"
        @unknown default: "알 수 없음"
        }
    }
}

/// 전원 공급원(IOKit), 저전력 모드, 발열 상태, 디스플레이 잠자기·화면 잠금을 감시한다.
@MainActor
final class PowerMonitor {
    private(set) var state = PowerState()
    var onChange: (@MainActor (PowerState) -> Void)?

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var displayAsleep = false
    private var screenLocked = false
    private var systemSleeping = false
    private var sessionInactive = false

    func start() {
        screenLocked = Self.isScreenLocked()
        refresh(log: true)

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh(log: true) }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }

        observe(.default, Notification.Name.NSProcessInfoPowerStateDidChange) { $0.refresh(log: true) }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { $0.refresh(log: true) }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true; $0.refresh(log: true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false; $0.refresh(log: true) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemSleeping = true; $0.refresh(log: true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemSleeping = false; $0.refresh(log: true) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true; $0.refresh(log: true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false; $0.refresh(log: true) }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true; $0.refresh(log: true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false; $0.refresh(log: true) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (PowerMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }

    private func refresh(log: Bool) {
        var next = PowerState()
        let battery = Self.readPowerSource()
        next.onBattery = battery.onBattery
        next.batteryLevel = battery.level
        next.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        next.thermal = ProcessInfo.processInfo.thermalState
        next.screenUnavailable = displayAsleep || screenLocked || systemSleeping || sessionInactive
        guard next != state else { return }
        let previous = state
        state = next
        if log, previous.onBattery != next.onBattery || previous.lowPowerMode != next.lowPowerMode
            || previous.thermal != next.thermal || previous.screenUnavailable != next.screenUnavailable {
            Log.info("전원 상태: \(next.powerText) · 저전력 모드 \(next.lowPowerMode ? "켬" : "끔") · 발열 \(next.thermalText)"
                + (next.screenUnavailable ? " · 화면 꺼짐/잠김" : ""))
        }
        onChange?(next)
    }

    private static func readPowerSource() -> (onBattery: Bool, level: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var level: Int?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            level = current * 100 / max
        }
        return (providing == kIOPSBatteryPowerValue, level)
    }

    /// 앱이 잠긴 화면에서 시작된 경우를 위해 현재 세션의 잠금 여부를 읽는다
    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
