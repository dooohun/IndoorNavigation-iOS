import Testing
import simd
import Foundation
@testable import IndoorNavigation_iOS

struct InferenceCadenceControllerTests {

    // MARK: - Helpers

    /// 위치(translation)만 들어 있는 4x4 transform. 회전 없음.
    private func makeTransform(x: Float, y: Float, z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = simd_float4(x, y, z, 1)
        return m
    }

    /// Y축 yaw 회전(라디안)을 가진 4x4 transform. 위치 0.
    /// 분류기는 columns.0.z, columns.0.x를 사용해 yaw = atan2(c0.z, c0.x)로 계산.
    /// Y-up 회전 R_y(θ) 의 첫 열은 (cosθ, 0, -sinθ) 이므로, atan2(-sinθ, cosθ) = -θ.
    private func makeYawTransform(yawRad: Float, tx: Float = 0, ty: Float = 0, tz: Float = 0) -> simd_float4x4 {
        let c = cos(yawRad)
        let s = sin(yawRad)
        var m = matrix_identity_float4x4
        m.columns.0 = simd_float4(c, 0, -s, 0)
        m.columns.1 = simd_float4(0, 1,  0, 0)
        m.columns.2 = simd_float4(s, 0,  c, 0)
        m.columns.3 = simd_float4(tx, ty, tz, 1)
        return m
    }

    // MARK: - 1) 정지 상태 → 1.5Hz 간격 호출만 true

    @Test("정지 상태에서는 1.5Hz(=0.667s) 이상 간격일 때만 추론 허용")
    func stationary_runsAtConfiguredHz() {
        let ctrl = InferenceCadenceController()
        let pose = makeTransform(x: 0, y: 0, z: 0)

        // 첫 호출은 lastInferenceTimestamp == -inf 이므로 무조건 통과 (앵커 호출).
        let first = ctrl.shouldRunInference(cameraTransform: pose, timestamp: 0.0, thermalState: .nominal)
        #expect(first == true)
        #expect(ctrl.lastMotionState == .stationary)

        // 0.5초 뒤: 1.5Hz의 minInterval(0.667s) 미만 → false.
        let tooSoon = ctrl.shouldRunInference(cameraTransform: pose, timestamp: 0.5, thermalState: .nominal)
        #expect(tooSoon == false)

        // 0.7초 뒤: 0.667s 초과 → true.
        let okay = ctrl.shouldRunInference(cameraTransform: pose, timestamp: 0.7, thermalState: .nominal)
        #expect(okay == true)
    }

    // MARK: - 2) walking → 5Hz 간격

    @Test("walking 상태에서는 5Hz(=0.2s) 간격으로 추론 허용")
    func walking_runsAt5Hz() {
        let ctrl = InferenceCadenceController()

        // 1프레임당 0.05초 동안 0.05m 이동 → 1 m/s, walking 영역(>0.3 m/s).
        // 첫 호출로 lastTransform 시드 + 추론 1회.
        _ = ctrl.shouldRunInference(
            cameraTransform: makeTransform(x: 0, y: 0, z: 0),
            timestamp: 0.0,
            thermalState: .nominal
        )

        // 두번째: 충분한 이동 + 0.05초 경과 (0.2s 미만) → walking 분류, but 간격 미달 → false
        let m1 = ctrl.shouldRunInference(
            cameraTransform: makeTransform(x: 0.05, y: 0, z: 0),
            timestamp: 0.05,
            thermalState: .nominal
        )
        #expect(ctrl.lastMotionState == .walking)
        #expect(m1 == false)

        // 0.25초 시점: 0.2s 초과 → true
        let m2 = ctrl.shouldRunInference(
            cameraTransform: makeTransform(x: 0.25, y: 0, z: 0),
            timestamp: 0.25,
            thermalState: .nominal
        )
        #expect(ctrl.lastMotionState == .walking)
        #expect(m2 == true)
    }

    // MARK: - 3) turning → 10Hz 간격

    @Test("turning(yaw rate > 25°/s)에서는 10Hz(=0.1s) 간격으로 추론 허용")
    func turning_runsAt10Hz() {
        let ctrl = InferenceCadenceController()

        // 첫 호출 (시드).
        _ = ctrl.shouldRunInference(
            cameraTransform: makeYawTransform(yawRad: 0),
            timestamp: 0.0,
            thermalState: .nominal
        )

        // dt=0.05s 동안 yaw 30° 변화 → yaw rate 600°/s (turning 영역).
        let yaw30 = Float(30.0 * .pi / 180.0)
        let t1 = ctrl.shouldRunInference(
            cameraTransform: makeYawTransform(yawRad: yaw30),
            timestamp: 0.05,
            thermalState: .nominal
        )
        #expect(ctrl.lastMotionState == .turning)
        // 0.05s < 0.1s minInterval → false
        #expect(t1 == false)

        // 0.15s 시점: 0.1s 초과 → true (단 turning 분류 유지를 위해 yaw 더 변경)
        let yaw60 = Float(60.0 * .pi / 180.0)
        let t2 = ctrl.shouldRunInference(
            cameraTransform: makeYawTransform(yawRad: yaw60),
            timestamp: 0.15,
            thermalState: .nominal
        )
        #expect(ctrl.lastMotionState == .turning)
        #expect(t2 == true)
    }

    // MARK: - 4) thermal .critical → 0.3배 감쇠

    @Test("thermal .critical은 base hz를 0.3배로 감쇠")
    func thermalCritical_throttlesHz() {
        let ctrl = InferenceCadenceController()

        // 정지 상태 base 1.5Hz × 0.3 = 0.45Hz → minInterval 약 2.222s.
        // 첫 호출 (앵커).
        let first = ctrl.shouldRunInference(
            cameraTransform: makeTransform(x: 0, y: 0, z: 0),
            timestamp: 0.0,
            thermalState: .critical
        )
        #expect(first == true)

        // 1초 시점: 1.0s < 2.222s → false (감쇠 없을 시 0.667s에서는 true였을 것).
        let t1s = ctrl.shouldRunInference(
            cameraTransform: makeTransform(x: 0, y: 0, z: 0),
            timestamp: 1.0,
            thermalState: .critical
        )
        #expect(t1s == false)

        // 2.3초 시점: 2.3s > 2.222s → true.
        let t2_3 = ctrl.shouldRunInference(
            cameraTransform: makeTransform(x: 0, y: 0, z: 0),
            timestamp: 2.3,
            thermalState: .critical
        )
        #expect(t2_3 == true)
    }

    // MARK: - 5) setHint → ttl 내에는 hint hz 우선

    @Test("setHint 호출 후 ttl 내에는 hint hz가 base hz보다 우선")
    func setHint_overridesWithinTTL() {
        let ctrl = InferenceCadenceController()

        // 정지 상태(base 1.5Hz)에서 hint 10Hz, ttl 1.0s 부여.
        ctrl.setHint(hz: 10.0, ttl: 1.0, now: 0.0)

        // 앵커 호출.
        let first = ctrl.shouldRunInference(
            cameraTransform: makeTransform(x: 0, y: 0, z: 0),
            timestamp: 0.0,
            thermalState: .nominal
        )
        #expect(first == true)

        // hint 10Hz의 minInterval=0.1s. ttl 만료 전(0.5s)에 0.15s 후에 호출 → true.
        let inHint = ctrl.shouldRunInference(
            cameraTransform: makeTransform(x: 0, y: 0, z: 0),
            timestamp: 0.15,
            thermalState: .nominal
        )
        #expect(inHint == true)
        #expect(ctrl.lastMotionState == .stationary)

        // ttl 만료 후(timestamp 1.5s, hintExpiresAt=1.0). base 1.5Hz minInterval 0.667s.
        // 마지막 추론이 0.15s에서 일어났으므로 1.5 - 0.15 = 1.35s > 0.667s → true.
        // 주의: 이 케이스는 base 적용 후에도 통과하므로 base/hint 구분에는 부적합.
        // 대신 ttl 만료 직후 base 미달 시점 검증.
        ctrl.setHint(hz: 10.0, ttl: 0.3, now: 0.0)
        let ctrl2 = InferenceCadenceController()
        ctrl2.setHint(hz: 10.0, ttl: 0.3, now: 0.0)
        _ = ctrl2.shouldRunInference(
            cameraTransform: makeTransform(x: 0, y: 0, z: 0),
            timestamp: 0.0,
            thermalState: .nominal
        )
        // 0.4s 시점: ttl 만료(0.3s 지남) → base 1.5Hz 적용. lastInference=0.0, 0.4-0.0=0.4 < 0.667 → false.
        let afterExpire = ctrl2.shouldRunInference(
            cameraTransform: makeTransform(x: 0, y: 0, z: 0),
            timestamp: 0.4,
            thermalState: .nominal
        )
        #expect(afterExpire == false)
    }
}
