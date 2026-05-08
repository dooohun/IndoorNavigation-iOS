import Testing
import Foundation
import simd
@testable import IndoorNavigation_iOS

/// RansacPnPSolver — outlier 면역성 단위 테스트. DLT 단독은 outlier 1-2 개에도 결과 폭주하지만
/// RANSAC 은 inlier-set 으로 robust 하게 복원해야 한다.
struct RansacPnPSolverTests {

    private static let K = simd_float3x3(rows: [
        SIMD3<Float>(800, 0, 320),
        SIMD3<Float>(0, 800, 240),
        SIMD3<Float>(0, 0, 1),
    ])

    /// 비-coplanar / 비-grid 25점 분포. 임의 6점 sample 도 numerical stable.
    /// PnPSolverTests 의 6점 분포(world6) 를 base 로 19개 추가.
    private static func generateInlierWorldPoints() -> [SIMD3<Float>] {
        return [
            SIMD3<Float>(-1.0, -0.8, 0.2),
            SIMD3<Float>(1.0, -0.8, -0.3),
            SIMD3<Float>(-1.2, 0.6, 0.4),
            SIMD3<Float>(1.0, 0.5, -0.2),
            SIMD3<Float>(0.0, 0.0, 1.0),
            SIMD3<Float>(0.5, -0.3, -0.5),
            SIMD3<Float>(-0.7, -0.4, 0.5),
            SIMD3<Float>(0.8, 0.7, -0.4),
            SIMD3<Float>(-0.3, 0.9, 0.7),
            SIMD3<Float>(0.4, -0.6, 0.3),
            SIMD3<Float>(-0.9, 0.3, -0.6),
            SIMD3<Float>(0.6, 0.2, 0.8),
            SIMD3<Float>(-0.5, -0.7, -0.4),
            SIMD3<Float>(0.2, 0.4, -0.7),
            SIMD3<Float>(-0.8, 0.6, 0.1),
            SIMD3<Float>(0.7, -0.5, 0.6),
            SIMD3<Float>(-0.1, 0.8, -0.3),
            SIMD3<Float>(0.3, -0.9, 0.4),
            SIMD3<Float>(-0.6, 0.1, 0.5),
            SIMD3<Float>(0.9, 0.4, -0.5),
            SIMD3<Float>(-0.4, -0.5, 0.2),
            SIMD3<Float>(0.1, 0.3, -0.8),
            SIMD3<Float>(-0.2, -0.2, 0.6),
            SIMD3<Float>(0.8, -0.8, -0.1),
            SIMD3<Float>(-0.5, 0.5, -0.5),
        ]
    }

    private static func project(world: SIMD3<Float>, R: simd_float3x3, t: SIMD3<Float>) -> SIMD2<Float> {
        let Xc = R * world + t
        let h = K * Xc
        return SIMD2<Float>(h.x / h.z, h.y / h.z)
    }

    private static func rotationAngleDeg(_ R1: simd_float3x3, _ R2: simd_float3x3) -> Float {
        let M = R1.transpose * R2
        let trace = M[0, 0] + M[1, 1] + M[2, 2]
        let cosTheta = max(-1.0, min(1.0, (trace - 1) / 2))
        return acos(cosTheta) * 180.0 / .pi
    }

    // MARK: - 1) outlier 0% — 깨끗한 데이터 → DLT 와 동등

    @Test("outlier 0% — 정확 복원 (R angle <0.5°, t diff <0.05m, reproj <0.5px)")
    func cleanDataMatchesDLT() {
        let R = matrix_identity_float3x3
        let t = SIMD3<Float>(0.1, -0.1, 5)
        let world = Self.generateInlierWorldPoints()
        let imgs = world.map { Self.project(world: $0, R: R, t: t) }

        let solver = RansacPnPSolver(iterations: 50, inlierThresholdPx: 5, minInliers: 12)
        guard let pose = solver.solve(objectPoints: world, imagePoints: imgs, intrinsics: Self.K) else {
            Issue.record("RANSAC PnP failed")
            return
        }
        #expect(Self.rotationAngleDeg(R, pose.rotation) < 0.5)
        #expect(simd_distance(t, pose.translation) < 0.05)
        #expect(pose.reprojectionError < 0.5)
    }

    // MARK: - 2) outlier 30% — RANSAC 이 처리

    @Test("outlier 30% — RANSAC 으로 정확 복원 (R angle <2°, t diff <0.1m)")
    func handles30PercentOutliers() {
        let R = matrix_identity_float3x3
        let t = SIMD3<Float>(0.2, -0.3, 6)
        let world = Self.generateInlierWorldPoints()
        var imgs = world.map { Self.project(world: $0, R: R, t: t) }
        // 30% (8/25) 점을 큰 noise 로 변조 — outlier 시뮬
        for i in stride(from: 0, to: 8, by: 1) {
            imgs[i] = SIMD2<Float>(Float.random(in: 0..<640), Float.random(in: 0..<480))
        }

        let solver = RansacPnPSolver(iterations: 200, inlierThresholdPx: 5, minInliers: 12)
        guard let pose = solver.solve(objectPoints: world, imagePoints: imgs, intrinsics: Self.K) else {
            Issue.record("RANSAC PnP failed (30% outlier)")
            return
        }
        #expect(Self.rotationAngleDeg(R, pose.rotation) < 2.0,
                "R angle = \(Self.rotationAngleDeg(R, pose.rotation))°")
        #expect(simd_distance(t, pose.translation) < 0.1,
                "t diff = \(simd_distance(t, pose.translation))")
        // refit 은 inlier 만 사용하므로 reproj 작아야
        #expect(pose.reprojectionError < 5.0)
    }

    // MARK: - 3) inlier 가 거의 없음 → nil

    @Test("inlier minInliers 미달 → nil (90% outlier 케이스)")
    func returnsNilWhenInsufficientInliers() {
        let R = matrix_identity_float3x3
        let t = SIMD3<Float>(0, 0, 5)
        let world = Self.generateInlierWorldPoints()
        var imgs = world.map { Self.project(world: $0, R: R, t: t) }
        // 90% (22/25) 점을 큰 noise 로
        for i in 0..<22 {
            imgs[i] = SIMD2<Float>(Float.random(in: 0..<640), Float.random(in: 0..<480))
        }

        let solver = RansacPnPSolver(iterations: 100, inlierThresholdPx: 5, minInliers: 12)
        let pose = solver.solve(objectPoints: world, imagePoints: imgs, intrinsics: Self.K)
        // inlier 3 개 < minInliers 12 → nil
        #expect(pose == nil)
    }

    // MARK: - 4) 점 < 6 → nil

    @Test("점 < 6 → nil")
    func tooFewPointsReturnsNil() {
        let solver = RansacPnPSolver()
        let world = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 5)
        let imgs = [SIMD2<Float>](repeating: SIMD2<Float>(320, 240), count: 5)
        let pose = solver.solve(objectPoints: world, imagePoints: imgs, intrinsics: Self.K)
        #expect(pose == nil)
    }
}
