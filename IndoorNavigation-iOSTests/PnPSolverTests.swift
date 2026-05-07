import Testing
import Foundation
import simd
@testable import IndoorNavigation_iOS

/// DLTPnPSolver synthetic 단위 테스트 — 알려진 R/t 로 3D 점을 카메라에 투영해 만든
/// 2D 점을 입력으로 줬을 때, solver 가 원래 R/t 를 거의 그대로 복원하는지 검증.
struct PnPSolverTests {

    /// 일반적 카메라 intrinsics (640×480 가정).
    private static let K = simd_float3x3(rows: [
        SIMD3<Float>(800, 0, 320),
        SIMD3<Float>(0, 800, 240),
        SIMD3<Float>(0, 0, 1),
    ])

    /// 고른 입체 분포 6 점 (coplanar 아님 — DLT 안정).
    private static let world6: [SIMD3<Float>] = [
        SIMD3<Float>(-1.0, -0.8, 0.2),
        SIMD3<Float>(1.0, -0.8, -0.3),
        SIMD3<Float>(-1.2, 0.6, 0.4),
        SIMD3<Float>(1.0, 0.5, -0.2),
        SIMD3<Float>(0.0, 0.0, 1.0),
        SIMD3<Float>(0.5, -0.3, -0.5),
    ]

    /// X_cam = R·X + t 후 K 로 픽셀 투영.
    private static func project(world: SIMD3<Float>, R: simd_float3x3, t: SIMD3<Float>) -> SIMD2<Float> {
        let Xc = R * world + t
        let h = K * Xc
        return SIMD2<Float>(h.x / h.z, h.y / h.z)
    }

    /// 두 회전 행렬의 angular distance (degrees).
    /// R_diff = R1^T · R2 → trace 로 각도 추정.
    private static func rotationAngleDeg(_ R1: simd_float3x3, _ R2: simd_float3x3) -> Float {
        let M = R1.transpose * R2
        let trace = M[0, 0] + M[1, 1] + M[2, 2]
        // arccos((trace - 1) / 2)
        let cosTheta = max(-1.0, min(1.0, (trace - 1) / 2))
        return acos(cosTheta) * 180.0 / .pi
    }

    // MARK: - 1) Identity rotation + translation

    @Test("R=I, t=(0,0,5) — 정확 복원")
    func recoverIdentity() {
        let R = matrix_identity_float3x3
        let t = SIMD3<Float>(0, 0, 5)
        let imgs = Self.world6.map { Self.project(world: $0, R: R, t: t) }
        guard let pose = DLTPnPSolver().solve(
            objectPoints: Self.world6, imagePoints: imgs, intrinsics: Self.K
        ) else {
            Issue.record("PnP failed")
            return
        }
        #expect(Self.rotationAngleDeg(R, pose.rotation) < 0.5,
                "R angle diff = \(Self.rotationAngleDeg(R, pose.rotation))°")
        #expect(simd_distance(t, pose.translation) < 0.05,
                "t diff = \(simd_distance(t, pose.translation))")
        #expect(pose.reprojectionError < 0.5,
                "reproj err = \(pose.reprojectionError)px")
    }

    // MARK: - 2) Y 축 30° 회전

    @Test("R=rotY(30°), t=(0.2, -0.1, 4) — 정확 복원")
    func recoverYRotation() {
        let theta: Float = 30 * .pi / 180
        let R = simd_float3x3(rows: [
            SIMD3<Float>(cos(theta), 0, sin(theta)),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(-sin(theta), 0, cos(theta)),
        ])
        let t = SIMD3<Float>(0.2, -0.1, 4)
        let imgs = Self.world6.map { Self.project(world: $0, R: R, t: t) }
        guard let pose = DLTPnPSolver().solve(
            objectPoints: Self.world6, imagePoints: imgs, intrinsics: Self.K
        ) else {
            Issue.record("PnP failed")
            return
        }
        #expect(Self.rotationAngleDeg(R, pose.rotation) < 0.5,
                "R angle diff = \(Self.rotationAngleDeg(R, pose.rotation))°")
        #expect(simd_distance(t, pose.translation) < 0.05,
                "t diff = \(simd_distance(t, pose.translation))")
        #expect(pose.reprojectionError < 0.5)
    }

    // MARK: - 3) 복합 회전 (X 20° · Y -15° · Z 10°)

    @Test("복합 회전 — 정확 복원")
    func recoverCompositeRotation() {
        let ax: Float = 20 * .pi / 180
        let ay: Float = -15 * .pi / 180
        let az: Float = 10 * .pi / 180
        let Rx = simd_float3x3(rows: [
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, cos(ax), -sin(ax)),
            SIMD3<Float>(0, sin(ax), cos(ax)),
        ])
        let Ry = simd_float3x3(rows: [
            SIMD3<Float>(cos(ay), 0, sin(ay)),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(-sin(ay), 0, cos(ay)),
        ])
        let Rz = simd_float3x3(rows: [
            SIMD3<Float>(cos(az), -sin(az), 0),
            SIMD3<Float>(sin(az), cos(az), 0),
            SIMD3<Float>(0, 0, 1),
        ])
        let R = Rx * Ry * Rz
        let t = SIMD3<Float>(-0.5, 0.3, 6)
        let imgs = Self.world6.map { Self.project(world: $0, R: R, t: t) }
        guard let pose = DLTPnPSolver().solve(
            objectPoints: Self.world6, imagePoints: imgs, intrinsics: Self.K
        ) else {
            Issue.record("PnP failed")
            return
        }
        #expect(Self.rotationAngleDeg(R, pose.rotation) < 0.5)
        #expect(simd_distance(t, pose.translation) < 0.05)
        #expect(pose.reprojectionError < 0.5)
    }

    // MARK: - 4) 점 < 6 → nil

    @Test("점 < 6개 → nil")
    func tooFewPoints() {
        let solver = DLTPnPSolver()
        let world = Array(Self.world6.prefix(5))
        let imgs = world.map { Self.project(world: $0, R: matrix_identity_float3x3, t: SIMD3<Float>(0, 0, 5)) }
        let pose = solver.solve(objectPoints: world, imagePoints: imgs, intrinsics: Self.K)
        #expect(pose == nil)
    }

    // MARK: - 5) 결과 R 의 직교성 (R · R^T ≈ I, det ≈ +1)

    @Test("결과 R 은 orthonormal (R·R^T ≈ I) + det = +1")
    func resultRIsOrthonormal() {
        let R = matrix_identity_float3x3
        let t = SIMD3<Float>(0.1, -0.2, 5)
        let imgs = Self.world6.map { Self.project(world: $0, R: R, t: t) }
        guard let pose = DLTPnPSolver().solve(
            objectPoints: Self.world6, imagePoints: imgs, intrinsics: Self.K
        ) else {
            Issue.record("PnP failed")
            return
        }
        let RRt = pose.rotation * pose.rotation.transpose
        let I = matrix_identity_float3x3
        for r in 0..<3 {
            for c in 0..<3 {
                #expect(abs(RRt[r, c] - I[r, c]) < 1e-3,
                        "R·R^T[\(r),\(c)] = \(RRt[r, c]), expected \(I[r, c])")
            }
        }
        let det = simd_determinant(pose.rotation)
        #expect(abs(det - 1.0) < 1e-3, "det = \(det)")
    }
}
