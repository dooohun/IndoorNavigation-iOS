import Foundation
import simd

enum MotionState: String {
    case stationary
    case walking
    case turning
}

struct InferenceCadenceConfig {
    var hzStationary: Double = 1.5
    var hzWalking: Double = 5.0
    var hzTurning: Double = 10.0
    var stationaryVelocityThreshold: Float = 0.3
    var turningYawRateThreshold: Float = 25.0
    var thermalThrottle: [ProcessInfo.ThermalState: Double] = [
        .nominal: 1.0, .fair: 1.0, .serious: 0.6, .critical: 0.3
    ]
}

final class InferenceCadenceController {

    private let config: InferenceCadenceConfig
    private var lastTransform: simd_float4x4?
    private var lastTimestamp: TimeInterval?
    private var lastInferenceTimestamp: TimeInterval = -.infinity
    private(set) var lastMotionState: MotionState = .stationary
    private var hintExpiresAt: TimeInterval = -.infinity
    private var hintHz: Double?

    init(config: InferenceCadenceConfig = InferenceCadenceConfig()) {
        self.config = config
    }

    func shouldRunInference(
        cameraTransform: simd_float4x4,
        timestamp: TimeInterval,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        let motion = classifyMotion(transform: cameraTransform, timestamp: timestamp)
        lastMotionState = motion
        let baseHz: Double
        switch motion {
        case .stationary: baseHz = config.hzStationary
        case .walking:    baseHz = config.hzWalking
        case .turning:    baseHz = config.hzTurning
        }
        let hint = (timestamp < hintExpiresAt) ? (hintHz ?? baseHz) : baseHz
        let throttle = config.thermalThrottle[thermalState] ?? 1.0
        let effectiveHz = max(0.5, hint * throttle)
        let minInterval = 1.0 / effectiveHz

        let elapsed = timestamp - lastInferenceTimestamp
        if elapsed >= minInterval {
            lastInferenceTimestamp = timestamp
            return true
        }
        return false
    }

    func setHint(hz: Double, ttl: TimeInterval, now: TimeInterval) {
        hintHz = hz
        hintExpiresAt = now + ttl
    }

    private func classifyMotion(transform: simd_float4x4, timestamp: TimeInterval) -> MotionState {
        defer { lastTransform = transform; lastTimestamp = timestamp }
        guard let prev = lastTransform, let prevT = lastTimestamp, timestamp > prevT else {
            return .stationary
        }
        let dt = Float(timestamp - prevT)
        guard dt > 1e-3 else { return lastMotionState }

        let dxyz = transform.columns.3 - prev.columns.3
        let speed = simd_length(simd_float3(dxyz.x, dxyz.y, dxyz.z)) / dt

        let yawCur = atan2(transform.columns.0.z, transform.columns.0.x)
        let yawPrev = atan2(prev.columns.0.z, prev.columns.0.x)
        var dyaw = yawCur - yawPrev
        if dyaw > .pi { dyaw -= 2 * .pi }
        if dyaw < -.pi { dyaw += 2 * .pi }
        let yawRateDeg = abs(dyaw) * 180.0 / .pi / dt

        if yawRateDeg > config.turningYawRateThreshold {
            return .turning
        }
        if speed < config.stationaryVelocityThreshold {
            return .stationary
        }
        return .walking
    }
}
