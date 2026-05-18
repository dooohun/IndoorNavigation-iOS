import ARKit
import Foundation
import simd

// MARK: - 결과/입력 모델

/// MeshRaycaster.raycast 의 결과. AR world 공간 기준 거리·법선·교차점·anchor identifier.
struct MeshRayHit {
    let distance: Float
    let normal: SIMD3<Float>
    let point: SIMD3<Float>
    let anchorIdentifier: UUID
}

/// raycastRaw 가 받는 mesh 형태. ARMeshAnchor 로부터 vertices/indices 를 복사해 만든다.
/// transform 은 anchor.transform — local↔world 변환에 사용.
struct RaycastMeshInput {
    let vertices: [SIMD3<Float>]
    let indices: [UInt32]
    let transform: simd_float4x4
    let identifier: UUID
}

// MARK: - Raycaster

/// LiDAR scene mesh (`ARMeshAnchor`) 들에 대한 Möller–Trumbore ray-triangle 교차 검사.
/// `MeshRaycaster.raycast` 는 ARKit anchor 배열을 직접 받아 anchor 중심 거리로 1차 필터 후
/// `raycastRaw` 로 위임. 좌우 벽 거리 측정용 (WallCenteringController 가 사용).
enum MeshRaycaster {

    /// ARMeshAnchor 배열에 대해 ray cast.
    /// - Parameters:
    ///   - origin: AR world 공간 ray 시작점
    ///   - direction: AR world 공간 ray 방향 (normalize 가정. 호출자가 보장)
    ///   - anchors: 후보 ARMeshAnchor 들
    ///   - maxDistance: 최대 검색 거리 (m). 초과 hit 는 무시
    ///   - anchorRadius: anchor 한 변 가정 반경(m). `origin` 으로부터 `anchorRadius + 0.5` 초과 anchor 는 제외 (대략 필터)
    /// - Returns: 가장 가까운 hit 또는 nil
    static func raycast(origin: SIMD3<Float>,
                        direction: SIMD3<Float>,
                        anchors: [ARMeshAnchor],
                        maxDistance: Float,
                        anchorRadius: Float = 3.0) -> MeshRayHit? {
        // 1차 필터 — anchor 중심 거리. ARMeshAnchor 는 약 3m 크기 셀이라 anchorRadius + 0.5m 여유.
        let candidates: [ARMeshAnchor] = anchors.filter { anchor in
            let center = SIMD3<Float>(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            let d = simd_distance(center, origin)
            return d <= (anchorRadius + 0.5)
        }
        guard !candidates.isEmpty else { return nil }

        // anchor → RaycastMeshInput 변환 (vertex / index 버퍼 복사)
        var meshes: [RaycastMeshInput] = []
        meshes.reserveCapacity(candidates.count)
        for anchor in candidates {
            guard let mesh = makeMeshInput(from: anchor) else { continue }
            meshes.append(mesh)
        }
        guard !meshes.isEmpty else { return nil }

        return raycastRaw(origin: origin, direction: direction, meshes: meshes, maxDistance: maxDistance)
    }

    /// raw vertex/index 배열에 대한 ray cast. 단위 테스트에서 직접 호출.
    /// 각 mesh 의 transform inverse 를 ray 에 적용해 local-space 에서 Möller–Trumbore 검사.
    static func raycastRaw(origin: SIMD3<Float>,
                           direction: SIMD3<Float>,
                           meshes: [RaycastMeshInput],
                           maxDistance: Float) -> MeshRayHit? {
        guard !meshes.isEmpty else { return nil }

        var best: (t: Float, normalLocal: SIMD3<Float>, pointLocal: SIMD3<Float>, mesh: RaycastMeshInput)?

        for mesh in meshes {
            let invT = mesh.transform.inverse
            // ray origin/direction 을 local space 로 변환. direction 은 vector 라 w=0 으로 변환.
            let originLocal4 = invT * SIMD4<Float>(origin.x, origin.y, origin.z, 1)
            let directionLocal4 = invT * SIMD4<Float>(direction.x, direction.y, direction.z, 0)
            let originLocal = SIMD3<Float>(originLocal4.x, originLocal4.y, originLocal4.z)
            let directionLocal = SIMD3<Float>(directionLocal4.x, directionLocal4.y, directionLocal4.z)
            let dirLen = simd_length(directionLocal)
            guard dirLen > 0.000001 else { continue }
            // local space 에서 maxDistance 환산 — transform 이 scale 포함 시 정확도 영향 있으나
            // ARKit 은 unit scale 가정. dirLen 으로 정규화 후 t (world distance 와 동일) 검사.
            let dirLocalNorm = directionLocal / dirLen
            // localT (정규화 dir 기준) 가 world maxDistance 와 일치하도록 scale 보정 — unit scale 라 1:1.
            let triCount = mesh.indices.count / 3
            for i in 0..<triCount {
                let i0 = Int(mesh.indices[i * 3])
                let i1 = Int(mesh.indices[i * 3 + 1])
                let i2 = Int(mesh.indices[i * 3 + 2])
                guard i0 < mesh.vertices.count, i1 < mesh.vertices.count, i2 < mesh.vertices.count else { continue }
                let v0 = mesh.vertices[i0]
                let v1 = mesh.vertices[i1]
                let v2 = mesh.vertices[i2]

                guard let hit = mollerTrumbore(
                    origin: originLocal,
                    direction: dirLocalNorm,
                    v0: v0, v1: v1, v2: v2
                ) else { continue }
                if hit.t <= 0 || hit.t > maxDistance { continue }

                if best == nil || hit.t < best!.t {
                    let pointLocal = originLocal + dirLocalNorm * hit.t
                    best = (hit.t, hit.normal, pointLocal, mesh)
                }
            }
        }

        guard let b = best else { return nil }

        // local → world 변환. normal 은 vector 라 w=0.
        let pointWorld4 = b.mesh.transform * SIMD4<Float>(b.pointLocal.x, b.pointLocal.y, b.pointLocal.z, 1)
        let normalWorld4 = b.mesh.transform * SIMD4<Float>(b.normalLocal.x, b.normalLocal.y, b.normalLocal.z, 0)
        let pointWorld = SIMD3<Float>(pointWorld4.x, pointWorld4.y, pointWorld4.z)
        var normalWorld = SIMD3<Float>(normalWorld4.x, normalWorld4.y, normalWorld4.z)
        let nLen = simd_length(normalWorld)
        if nLen > 0.000001 { normalWorld = normalWorld / nLen }

        return MeshRayHit(
            distance: b.t,
            normal: normalWorld,
            point: pointWorld,
            anchorIdentifier: b.mesh.identifier
        )
    }

    // MARK: - 내부 헬퍼

    /// Möller–Trumbore ray-triangle 교차. backface culling OFF, eps 1e-6.
    /// - Returns: 교차 t (>0 이면 정면 교차) + face normal. nil 이면 평행/미교차.
    private static func mollerTrumbore(origin: SIMD3<Float>,
                                       direction: SIMD3<Float>,
                                       v0: SIMD3<Float>,
                                       v1: SIMD3<Float>,
                                       v2: SIMD3<Float>) -> (t: Float, normal: SIMD3<Float>)? {
        let eps: Float = 1e-6
        let edge1 = v1 - v0
        let edge2 = v2 - v0
        let h = simd_cross(direction, edge2)
        let a = simd_dot(edge1, h)
        // backface culling OFF — abs 로 평행 검사
        if abs(a) < eps { return nil }
        let f = 1.0 / a
        let s = origin - v0
        let u = f * simd_dot(s, h)
        if u < 0 || u > 1 { return nil }
        let q = simd_cross(s, edge1)
        let v = f * simd_dot(direction, q)
        if v < 0 || (u + v) > 1 { return nil }
        let t = f * simd_dot(edge2, q)
        if t <= eps { return nil }

        var normal = simd_cross(edge1, edge2)
        let nLen = simd_length(normal)
        if nLen > eps { normal = normal / nLen }
        return (t, normal)
    }

    /// ARMeshAnchor.geometry 의 vertex/index 버퍼를 안전 복사해 RaycastMeshInput 으로 변환.
    /// vertex format 은 .float3 가정 (assert), index size 는 4B (UInt32) 가정 (assert).
    private static func makeMeshInput(from anchor: ARMeshAnchor) -> RaycastMeshInput? {
        let geometry = anchor.geometry
        let vSrc = geometry.vertices
        let fSrc = geometry.faces

        // vertex format / index size 보장 (ARKit 문서상 .float3 + 4B UInt32 가 표준)
        assert(vSrc.format == .float3, "ARMeshAnchor vertex format must be .float3, got \(vSrc.format.rawValue)")
        assert(fSrc.bytesPerIndex == 4, "ARMeshAnchor index bytesPerIndex must be 4 (UInt32), got \(fSrc.bytesPerIndex)")
        guard vSrc.format == .float3, fSrc.bytesPerIndex == 4 else { return nil }

        // Vertex 복사 — stride 가 12 이상일 수 있으므로 stride 기준으로 base ptr 진행
        let vCount = vSrc.count
        let vStride = vSrc.stride  // 보통 12
        let vBase = vSrc.buffer.contents().advanced(by: vSrc.offset)
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(vCount)
        for i in 0..<vCount {
            let p = vBase.advanced(by: i * vStride).assumingMemoryBound(to: Float.self)
            vertices.append(SIMD3<Float>(p[0], p[1], p[2]))
        }

        // Index 복사 — face 당 indexCountPerPrimitive (=3) 개. ARGeometryElement.buffer 는 offset 없이
        // base ptr 부터 packed 된 UInt32 배열을 보관 (ARKit 공식 sample 패턴).
        let primitiveCount = fSrc.count
        let perPrim = fSrc.indexCountPerPrimitive
        let indexCount = primitiveCount * perPrim
        let iBase = fSrc.buffer.contents().assumingMemoryBound(to: UInt32.self)
        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        for i in 0..<indexCount {
            indices.append(iBase[i])
        }

        return RaycastMeshInput(
            vertices: vertices,
            indices: indices,
            transform: anchor.transform,
            identifier: anchor.identifier
        )
    }
}
