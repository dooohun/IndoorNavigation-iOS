import ARKit
import CoreGraphics
import Foundation
import simd

// MARK: - Delegate

protocol WallCenteringControllerDelegate: AnyObject {
    /// world origin 보정이 적용된 후 호출. shift 는 AR world XZ 평면 변위 (m).
    /// caller (ARNavigationLogic) 는 캐시한 matchedARPose 등을 동일 양만큼 보정해야 한다.
    func wallCenteringDidApplyShift(_ shift: simd_float3)
}

// MARK: - Controller

/// LiDAR scene mesh 좌우 raycast 결과로 사용자가 복도 가운데에 있도록 ARKit world origin 을 천천히 보정.
/// `start` → 0.2s 주기 tick → 좌·우 벽 거리 측정 → EMA 평활 후 `setWorldOrigin` 호출.
/// 폴리곤 안에 있을 때만 적용. LiDAR 미지원 단말이면 start 시 no-op.
/// V3 재측위 in-flight 동안은 `suspend()` 로 일시 정지.
final class WallCenteringController {

    // MARK: 상수

    private let tickIntervalSec: TimeInterval = 0.2
    private let emaAlpha: Float = 0.05
    private let minDistM: Float = 0.3
    private let maxDistM: Float = 3.0
    private let minSideRatio: Float = 0.5
    private let wallNormalUpDotMax: Float = 0.3
    private let shiftSkipThresholdM: Float = 0.005
    private let cumulativeShiftLimitM: Float = 1.0
    private let rayMaxDistanceM: Float = 4.0

    // MARK: 상태

    weak var session: ARSession?
    weak var delegate: WallCenteringControllerDelegate?
    private var polygonRings: [[CGPoint]] = []
    private var serverFromARWorldXZ: ((simd_float3) -> CGPoint)?
    private var emaOffset: Float = 0
    private var cumulativeShiftM: Float = 0
    private var isSuspended: Bool = false
    private var timer: Timer?

    // MARK: - API

    /// LiDAR 가능 단말에서만 timer 시작. 이미 timer 가 있으면 stop 후 재시작.
    func start(session: ARSession,
               polygonRings: [[CGPoint]],
               serverFromARWorldXZ: @escaping (simd_float3) -> CGPoint) {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("[Wall] LiDAR 미지원 — controller disabled")
            return
        }
        if timer != nil {
            stop()
        }
        self.session = session
        self.polygonRings = polygonRings
        self.serverFromARWorldXZ = serverFromARWorldXZ
        self.emaOffset = 0
        self.cumulativeShiftM = 0
        self.isSuspended = false

        timer = Timer.scheduledTimer(withTimeInterval: tickIntervalSec, repeats: true) { [weak self] _ in
            self?.tick()
        }
        print("[Wall] controller 시작 — tick=\(tickIntervalSec)s, polygonRings=\(polygonRings.count)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        emaOffset = 0
        cumulativeShiftM = 0
        isSuspended = false
    }

    func suspend() {
        isSuspended = true
    }

    /// 일시정지 해제. V3 재측위 성공 직후엔 cumulative 누적치 리셋(보정 베이스가 변경됐으므로),
    /// 단순 timeout/실패 복귀 시는 누적치 유지.
    func resume(resetCumulative: Bool) {
        isSuspended = false
        if resetCumulative {
            cumulativeShiftM = 0
            emaOffset = 0
        }
    }

    func updatePolygonRings(_ rings: [[CGPoint]]) {
        self.polygonRings = rings
    }

    // MARK: - Tick

    private func tick() {
        guard !isSuspended else { return }
        guard let session, let frame = session.currentFrame else { return }
        guard let serverFromARWorldXZ else { return }

        // 폴리곤이 아직 fetch 되지 않은 케이스 — 보수적으로 skip.
        if polygonRings.isEmpty {
            print("[Wall] skip — polygon not ready")
            return
        }

        // 카메라 transform 에서 position(p) 와 horizontal right vector(r) 추출
        let transform = frame.camera.transform
        let p = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        // 카메라 local right = columns.0. 수평 성분만 사용(y=0) 후 정규화.
        let rRaw = SIMD3<Float>(transform.columns.0.x, 0, transform.columns.0.z)
        let rLen = simd_length(rRaw)
        guard rLen > 0.000001 else {
            print("[Wall] skip — right vector 수평 길이 0")
            return
        }
        let r = rRaw / rLen

        // ARMeshAnchor 추출 — 0개면 LiDAR 활성 전이거나 단말 미지원.
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        if meshAnchors.isEmpty {
            print("[Wall] skip — no ARMeshAnchor")
            return
        }

        // 폴리곤 contains 가드 — 모든 ring 에 미포함이면 복도 밖 (계단/엘리베이터 등) → 보정 X.
        let serverXY = serverFromARWorldXZ(p)
        let insideAny = polygonRings.contains(where: { FloorNavigationMapMath.contains(serverXY, in: $0) })
        if !insideAny {
            print("[Wall] skip — outside polygon")
            return
        }

        // 좌·우 ray cast (-r / +r)
        let leftHit = MeshRaycaster.raycast(
            origin: p, direction: -r, anchors: meshAnchors,
            maxDistance: rayMaxDistanceM
        )
        let rightHit = MeshRaycaster.raycast(
            origin: p, direction: r, anchors: meshAnchors,
            maxDistance: rayMaxDistanceM
        )

        guard let l = leftHit, let rH = rightHit else {
            print("[Wall] skip — 양쪽 hit 부족 (L=\(leftHit?.distance.formatted ?? "nil") R=\(rightHit?.distance.formatted ?? "nil"))")
            return
        }

        let dL = l.distance
        let dR = rH.distance

        // 거리 범위 가드 — 너무 가깝거나 멀면 노이즈로 간주.
        if dL < minDistM || dL > maxDistM || dR < minDistM || dR > maxDistM {
            print("[Wall] skip — 거리 범위 밖 L=\(dL) R=\(dR) (min=\(minDistM) max=\(maxDistM))")
            return
        }

        // 대칭성 가드 — 작은쪽/큰쪽 비율이 minSideRatio 미만이면 한쪽이 빈 공간일 가능성.
        let ratio = min(dL, dR) / max(dL, dR)
        if ratio < minSideRatio {
            print("[Wall] skip — 대칭성 불충분 ratio=\(ratio) (< \(minSideRatio))")
            return
        }

        // 수직 벽 가드 — normal 의 up 성분이 크면 바닥/천장 hit. |n·up| 이 임계 초과면 skip.
        let upDotL = abs(l.normal.y)
        let upDotR = abs(rH.normal.y)
        if upDotL > wallNormalUpDotMax || upDotR > wallNormalUpDotMax {
            print("[Wall] skip — 비수직 벽 |n·up| L=\(upDotL) R=\(upDotR) (> \(wallNormalUpDotMax))")
            return
        }

        // 보정량 계산 — 오른쪽이 더 멀면 사용자는 왼쪽 치우침 → 오른쪽으로 shift.
        let rawOffset = (dR - dL) / 2.0
        emaOffset += emaAlpha * (rawOffset - emaOffset)

        if abs(emaOffset) < shiftSkipThresholdM {
            print(String(format: "[Wall] skip — EMA |%.4fm| < %.4fm (raw=%.3f)", emaOffset, shiftSkipThresholdM, rawOffset))
            return
        }

        // cumulative 한계 — 한 측위 사이클 동안 1m 이상 누적 보정 시 stop (over-correction 방어).
        let nextCumulative = abs(cumulativeShiftM + emaOffset)
        if nextCumulative > cumulativeShiftLimitM {
            print(String(format: "[Wall] cumulative 초과 — |Σ|=%.3f > %.3f. stop().", nextCumulative, cumulativeShiftLimitM))
            stop()
            return
        }

        // shift = r * emaOffset, XZ 만 — Y 성분은 보존.
        let shift = SIMD3<Float>(r.x * emaOffset, 0, r.z * emaOffset)

        // setWorldOrigin(relativeTransform: T) — 새 world = T^-1 * 옛 world. caller 가 캐시한 pose 도 동반 갱신해야 함.
        var T = matrix_identity_float4x4
        T.columns.3 = SIMD4<Float>(shift.x, 0, shift.z, 1)
        session.setWorldOrigin(relativeTransform: T)

        delegate?.wallCenteringDidApplyShift(shift)
        cumulativeShiftM += abs(emaOffset)

        print(String(format: "[Wall] applied — raw=%.3f ema=%.3f L=%.2f R=%.2f Σ=%.3f",
                     rawOffset, emaOffset, dL, dR, cumulativeShiftM))
    }
}

// MARK: - Float 표시 헬퍼

private extension Float {
    var formatted: String { String(format: "%.2f", self) }
}
