import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

/// Monotonic time and sleeping, injectable so the scheduler is testable.
public protocol OwlClock: Sendable {
    /// Seconds on a monotonic timeline.
    var now: TimeInterval { get }
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: OwlClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

public struct PowerState: Sendable, Equatable {
    public var onBattery: Bool
    /// 0–100, nil when there is no battery.
    public var batteryPercent: Int?
    public var lowPowerMode: Bool

    public init(onBattery: Bool, batteryPercent: Int?, lowPowerMode: Bool) {
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
    }

    public static let mains = PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false)

    /// The scheduler's power gate: no checks in Low Power Mode, or on
    /// battery below `minimumBattery` percent.
    public func allowsChecks(minimumBattery: Int = 20) -> Bool {
        if lowPowerMode { return false }
        if onBattery, let p = batteryPercent, p < minimumBattery { return false }
        return true
    }
}

public protocol PowerSource: Sendable {
    func current() -> PowerState
}

/// Reads IOKit's power-source list and ProcessInfo's Low Power Mode flag.
public struct SystemPowerSource: PowerSource {
    public init() {}

    public func current() -> PowerState {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if canImport(IOKit)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: lowPower)
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPSBatteryPowerValue
        var percent: Int?
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = cur * 100 / max
        }
        return PowerState(onBattery: onBattery, batteryPercent: percent, lowPowerMode: lowPower)
        #else
        return PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: lowPower)
        #endif
    }
}
