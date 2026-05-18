import Testing
import Foundation
import simd
@testable import IndoorNavigation_iOS

/// MeshRaycaster.raycastRaw 단위 테스트.
/// ARMeshAnchor 의존 회피 — RaycastMeshInput 직접 구성해서 ray-triangle 교차/필터 로직 검증.
struct MeshRaycasterTests {

    /// Z=0 평면에 펼친 단위 정사각형 메쉬 (2 triangles). v0 v1 v2 / v2 v1 v3 형태.
    /// 정사각형 [-1,-1,0] [1,-1,0] [-1,1,0] [1,1,0] 형태로 양면 hit 가능.
    private static func unitQuadAtZ0(transform: simd_float4x4 = matrix_identity_float4x4,
                                     identifier: UUID = UUID()) -> RaycastMeshInput {
        let vertices: [SIMD3<Float>] = [
            SIMD3<Float>(-1, -1, 0),  // 0
            SIMD3<Float>(1, -1, 0),   // 1
            SIMD3<Float>(-1, 1, 0),   // 2
            SIMD3<Float>(1, 1, 0),    // 3
        ]
        // 두 triangle: (0,1,2), (2,1,3). CCW 기준.
        let indices: [UInt32] = [0, 1, 2, 2, 1, 3]
        return RaycastMeshInput(
            vertices: vertices, indices: indices, transform: transform, identifier: identifier
        )
    }

    /// Y=0 평면 (수평 바닥) 위 단위 정사각형. 천장/바닥 hit 시 normal Y 방향 검증용.
    private static func unitQuadAtY0(transform: simd_float4x4 = matrix_identity_float4x4,
                                     identifier: UUID = UUID()) -> RaycastMeshInput {
        let vertices: [SIMD3<Float>] = [
            SIMD3<Float>(-1, 0, -1),
            SIMD3<Float>(1, 0, -1),
            SIMD3<Float>(-1, 0, 1),
            SIMD3<Float>(1, 0, 1),
        ]
        let indices: [UInt32] = [0, 1, 2, 2, 1, 3]
        return RaycastMeshInput(
            vertices: vertices, indices: indices, transform: transform, identifier: identifier
        )
    }

    // MARK: - 1) 단일 평면 hit

    @Test("Z=0 평면 단일 삼각형 hit — origin(0,0,-2), dir(+Z), 거리 ≈ 2m")
    func singleTriangleHit() {
        let mesh = Self.unitQuadAtZ0()
        let hit = MeshRaycaster.raycastRaw(
            origin: SIMD3<Float>(0, 0, -2),
            direction: SIMD3<Float>(0, 0, 1),
            meshes: [mesh],
            maxDistance: 10
        )
        #expect(hit != nil, "ray 가 평면 안쪽을 통과해야 hit")
        if let h = hit {
            #expect(abs(h.distance - 2.0) < 0.001, "distance ≈ 2, got \(h.distance)")
            #expect(abs(h.point.z - 0) < 0.001, "hit point Z ≈ 0, got \(h.point.z)")
        }
    }

    // MARK: - 2) miss — ray 가 평면 밖

    @Test("평면 밖 ray — origin(5,5,-2), dir(+Z) → 정사각형 외부 → nil")
    func rayMissesOutsideTriangle() {
        let mesh = Self.unitQuadAtZ0()
        let hit = MeshRaycaster.raycastRaw(
            origin: SIMD3<Float>(5, 5, -2),
            direction: SIMD3<Float>(0, 0, 1),
            meshes: [mesh],
            maxDistance: 10
        )
        #expect(hit == nil, "사각형 [-1,1]×[-1,1] 밖 ray 는 miss")
    }

    // MARK: - 3) maxDistance 초과

    @Test("maxDistance < 실제 거리 → nil")
    func maxDistanceExceeded() {
        let mesh = Self.unitQuadAtZ0()
        let hit = MeshRaycaster.raycastRaw(
            origin: SIMD3<Float>(0, 0, -5),
            direction: SIMD3<Float>(0, 0, 1),
            meshes: [mesh],
            maxDistance: 2.0
        )
        #expect(hit == nil, "실제 거리 5 > maxDistance 2 → nil")
    }

    // MARK: - 4) 빈 meshes

    @Test("빈 meshes 배열 → nil")
    func emptyMeshes() {
        let hit = MeshRaycaster.raycastRaw(
            origin: SIMD3<Float>(0, 0, 0),
            direction: SIMD3<Float>(0, 0, 1),
            meshes: [],
            maxDistance: 10
        )
        #expect(hit == nil)
    }

    // MARK: - 5) anchor transform 적용

    @Test("Translation (10,0,0) 적용 — origin (10,0,-2) 에서 같은 hit")
    func transformedAnchorHit() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(10, 0, 0, 1)
        let mesh = Self.unitQuadAtZ0(transform: transform)
        let hit = MeshRaycaster.raycastRaw(
            origin: SIMD3<Float>(10, 0, -2),
            direction: SIMD3<Float>(0, 0, 1),
            meshes: [mesh],
            maxDistance: 10
        )
        #expect(hit != nil)
        if let h = hit {
            #expect(abs(h.distance - 2.0) < 0.001, "distance ≈ 2, got \(h.distance)")
            #expect(abs(h.point.x - 10) < 0.001, "hit point x ≈ 10, got \(h.point.x)")
        }
    }

    // MARK: - 6) 두 평행 평면 중 가까운 쪽

    @Test("두 평행 평면 — 가까운 쪽 (Z=0) 반환")
    func nearestOfParallelPlanes() {
        let nearMesh = Self.unitQuadAtZ0()
        var farTransform = matrix_identity_float4x4
        farTransform.columns.3 = SIMD4<Float>(0, 0, 5, 1)  // Z=5 평면
        let farMesh = Self.unitQuadAtZ0(transform: farTransform)

        let hit = MeshRaycaster.raycastRaw(
            origin: SIMD3<Float>(0, 0, -2),
            direction: SIMD3<Float>(0, 0, 1),
            meshes: [farMesh, nearMesh],
            maxDistance: 20
        )
        #expect(hit != nil)
        if let h = hit {
            #expect(abs(h.distance - 2.0) < 0.001, "가까운 평면(Z=0) 거리=2, got \(h.distance)")
        }
    }

    // MARK: - 7) 수평 평면 — normal Y ≈ ±1

    @Test("수평 평면 (Y=0) hit — normal Y 가 ±1 근처")
    func horizontalPlaneNormalIsY() {
        let mesh = Self.unitQuadAtY0()
        // 위에서 아래로 (천장 → 바닥). origin Y=2, dir -Y.
        let hit = MeshRaycaster.raycastRaw(
            origin: SIMD3<Float>(0, 2, 0),
            direction: SIMD3<Float>(0, -1, 0),
            meshes: [mesh],
            maxDistance: 10
        )
        #expect(hit != nil)
        if let h = hit {
            let upDot = abs(h.normal.y)
            #expect(upDot > 0.9, "수평 평면 normal 의 Y 성분 |y| > 0.9, got \(upDot)")
            #expect(abs(h.distance - 2.0) < 0.001, "distance ≈ 2")
        }
    }
}
