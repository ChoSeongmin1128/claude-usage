//
//  PowerMonitor.swift
//  ClaudeUsage
//
//  Phase 4: 배터리 상태 모니터링
//

import Foundation
import Combine
import IOKit.ps

class PowerMonitor: ObservableObject {
    static let shared = PowerMonitor()

    @Published private(set) var isOnBattery: Bool = false

    private var runLoopSource: CFRunLoopSource?

    private init() {
        updateBatteryState()
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Battery State

    private func updateBatteryState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let firstSource = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, firstSource)?.takeUnretainedValue() as? [String: Any],
              let powerSource = description[kIOPSPowerSourceStateKey] as? String else {
            isOnBattery = false
            return
        }

        let newState = (powerSource == kIOPSBatteryPowerValue)
        if newState != isOnBattery {
            isOnBattery = newState
            Logger.info("전원 상태 변경: \(newState ? "배터리" : "전원 연결")")
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.updateBatteryState()
            }
        }, context)?.takeRetainedValue()

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            Logger.info("배터리 모니터링 시작")
        }
    }

    private func stopMonitoring() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
    }

    /// 현재 상태에 맞는 새로고침 간격 반환
    var effectiveRefreshInterval: TimeInterval {
        let settings = AppSettings.shared
        if isOnBattery && settings.reducedRefreshOnBattery {
            return max(settings.refreshInterval, 30)  // 배터리 시 최소 30초
        }
        return settings.refreshInterval
    }
}
