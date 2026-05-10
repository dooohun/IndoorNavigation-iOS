import Testing
import simd
@testable import IndoorNavigation_iOS

struct CoordinateTransformerTests {

    // 고정 RTAB-Map 카메라 pose (서버가 돌려준 위치/회전)
    private let serverPosition = simd_float3(10, 5, 2)
    private let serverQuaternion = simd_quatf(
        angle: .pi / 3,
        axis: simd_normalize(simd_float3(0.2, 1.0, 0.3))
    )

    private let iterations = 100
    private let anchorTolerance: Float = 1e-4
    private let distanceTolerance: Float = 1e-3

    // MARK: - Helpers

    private func makeARPose(translation: simd_float3, rotation: simd_quatf) -> simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.3 = simd_float4(translation.x, translation.y, translation.z, 1)
        return m
    }

    /// Shoemake: 균일 분포 단위 사원수
    private func randomUnitQuaternion() -> simd_quatf {
        let u1 = Float.random(in: 0...1)
        let u2 = Float.random(in: 0...1)
        let u3 = Float.random(in: 0...1)
        let s1 = sqrt(1 - u1)
        let s2 = sqrt(u1)
        return simd_quatf(
            ix: s1 * sin(2 * .pi * u2),
            iy: s1 * cos(2 * .pi * u2),
            iz: s2 * sin(2 * .pi * u3),
            r:  s2 * cos(2 * .pi * u3)
        )
    }

    private func randomTranslation() -> simd_float3 {
        simd_float3(
            .random(in: -50...50),
            .random(in: -10...10),
            .random(in: -50...50)
        )
    }

    // MARK: - 1) 앵커: 서버 카메라 위치 → ARKit 카메라 위치
    // W = arPose · rtabCameraToARKit · inv(T_W_from_C) 의 정의에서
    // serverPoint = serverPosition 을 넣으면 항상 arPose.translation 이 나와야 한다.
    // 이게 "두 좌표계를 정렬했다"의 본질.

    @Test("앵커: 서버 카메라 위치는 항상 ARKit 카메라 위치로 변환된다")
    func anchorPoint_mapsToArCameraPosition() {
        for i in 0..<iterations {
            let arTrans = randomTranslation()
            let arRot = randomUnitQuaternion()
            let arPose = makeARPose(translation: arTrans, rotation: arRot)

            let input = CoordinateTransformer.Input(
                serverPosition: serverPosition,
                serverQuaternion: serverQuaternion,
                arCameraPose: arPose
            )

            let mapped = CoordinateTransformer.transform(
                serverPoint: serverPosition,
                input: input
            )

            let err = simd_distance(mapped, arTrans)
            #expect(
                err < anchorTolerance,
                "iter \(i): 앵커 오차 \(err)m, mapped=\(mapped), expected=\(arTrans)"
            )
        }
    }

    // MARK: - 2) 거리 보존 (rigid transform)
    // W는 회전+평행이동만 있는 rigid transform이므로 임의 두 서버 점 사이 거리는
    // 변환 후에도 동일해야 한다. ARKit pose가 무엇이든 영향 없음.

    @Test("거리 보존: 임의 두 점 사이 거리는 변환 후에도 동일하다")
    func transform_preservesDistance() {
        for i in 0..<iterations {
            let arPose = makeARPose(
                translation: randomTranslation(),
                rotation: randomUnitQuaternion()
            )

            let input = CoordinateTransformer.Input(
                serverPosition: serverPosition,
                serverQuaternion: serverQuaternion,
                arCameraPose: arPose
            )

            let p1 = simd_float3(15, 5, 2)
            let p2 = simd_float3(15, 8, 7)
            let serverDist = simd_distance(p1, p2)

            let m1 = CoordinateTransformer.transform(serverPoint: p1, input: input)
            let m2 = CoordinateTransformer.transform(serverPoint: p2, input: input)
            let arDist = simd_distance(m1, m2)

            let err = abs(arDist - serverDist)
            #expect(
                err < distanceTolerance,
                "iter \(i): 거리 오차 \(err)m, server=\(serverDist), ar=\(arDist)"
            )
        }
    }

    // MARK: - 3) 모양 보존 (점 집합의 상대 구조 유지)
    // 같은 ARKit pose 하에서 여러 서버 점들의 상대적 거리행렬이 그대로 유지되는지 확인.

    @Test("모양 보존: 점 집합의 모든 쌍 거리가 변환 후에도 일치한다")
    func transform_preservesPairwiseDistances() {
        let arPose = makeARPose(
            translation: randomTranslation(),
            rotation: randomUnitQuaternion()
        )
        let input = CoordinateTransformer.Input(
            serverPosition: serverPosition,
            serverQuaternion: serverQuaternion,
            arCameraPose: arPose
        )

        // 임의의 5개 서버 점 (예: 경로 control points 흉내)
        let serverPoints: [simd_float3] = [
            simd_float3(10, 5, 2),
            simd_float3(15, 5, 2),
            simd_float3(20, 5, 2),
            simd_float3(20, 8, 2),
            simd_float3(20, 8, 7)
        ]
        let arPoints = serverPoints.map {
            CoordinateTransformer.transform(serverPoint: $0, input: input)
        }

        for i in 0..<serverPoints.count {
            for j in (i + 1)..<serverPoints.count {
                let serverDist = simd_distance(serverPoints[i], serverPoints[j])
                let arDist = simd_distance(arPoints[i], arPoints[j])
                let err = abs(arDist - serverDist)
                #expect(
                    err < distanceTolerance,
                    "(\(i),\(j)) 거리 오차 \(err)m: server=\(serverDist), ar=\(arDist)"
                )
            }
        }
    }

    // MARK: - 4) 결정론
    // 동일 입력은 항상 동일 결과 (sanity check)

    @Test("결정론: 동일 입력은 동일 결과를 낸다")
    func transform_isDeterministic() {
        let arPose = makeARPose(
            translation: simd_float3(5, 1, -3),
            rotation: simd_quatf(angle: .pi / 4, axis: simd_float3(0, 1, 0))
        )
        let input = CoordinateTransformer.Input(
            serverPosition: serverPosition,
            serverQuaternion: serverQuaternion,
            arCameraPose: arPose
        )
        let p = simd_float3(20, 7, 3)
        let r1 = CoordinateTransformer.transform(serverPoint: p, input: input)
        let r2 = CoordinateTransformer.transform(serverPoint: p, input: input)
        #expect(simd_distance(r1, r2) == 0)
    }
}
