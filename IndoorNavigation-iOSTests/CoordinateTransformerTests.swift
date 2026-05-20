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

    private func distanceXZ(_ a: simd_float3, _ b: simd_float3) -> Float {
        let dx = a.x - b.x
        let dz = a.z - b.z
        return sqrt(dx * dx + dz * dz)
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

    // MARK: - 1-1) 실제 측위 회귀: 서버 floor 평면이 ARKit XZ 평면으로 유지되어야 함
    //
    // 2026-05-20 실측 샘플. 이전 축 매핑(FRD: X forward, Y right, Z down)은 같은 floor의
    // route distance 대부분을 ARKit Y로 흘려보내서, 클라이언트가 XZ 평면에서 거리/방향을
    // 계산할 때 긴 직진 구간이 1/3 이하로 찌그러졌다.

    @Test("실측 회귀: 서버 바닥 경로는 ARKit XZ 경로로 변환된다")
    func measuredFloorRoute_mapsOntoARKitXZPlane() {
        let measuredServerPosition = simd_float3(
            -31.076979761953897,
             66.471807597959923,
              0.15973079236460053
        )
        let measuredServerQuaternion = simd_quatf(
            ix:  0.97477218059683413,
            iy:  0.1884797976355313,
            iz: -0.11788526898719218,
            r:   0.019940540955035557
        )
        let measuredARPose = simd_float4x4(rows: [
            SIMD4<Float>( 0.078361093997955322,  0.78993082046508789,  0.60816812515258789,   5.038482666015625),
            SIMD4<Float>(-0.9930260181427002,    0.0079481201246380806, 0.11762559413909912,  0.77319657802581787),
            SIMD4<Float>( 0.088082313537597656, -0.61314409971237183,   0.78504484891891479, -3.3510541915893555),
            SIMD4<Float>( 0,                     0,                     0,                    1)
        ])
        let route: [simd_float3] = [
            simd_float3(-31.076980590820312, 66.471809387207031,  0.15973079204559326),
            simd_float3(-31.071058048339502, 66.438476324978879, -1.5383087635040309),
            simd_float3( -8.9838252007204336, 70.362885487514532, -1.5383087635040318),
            simd_float3( -3.2030557481992332, 71.265078824775784, -1.5383087635040353),
            simd_float3(  1.9953055606672798, 69.485990415363062, -1.5383087635040316),
            simd_float3( 24.562022127902093,  74.146013251366242, -1.538308763504034),
            simd_float3( 29.994483708794682,  48.77032717572795,  -1.5383087635040269),
            simd_float3( 31.962362799525867,  39.102165773696996, -1.5383087635040249),
            simd_float3( 35.108554896705847,  18.314724708395254, -1.5383087635040202),
            simd_float3( 38.224329740572564,  18.898536189573782, -1.5383087635040202)
        ]

        let input = CoordinateTransformer.Input(
            serverPosition: measuredServerPosition,
            serverQuaternion: measuredServerQuaternion,
            arCameraPose: measuredARPose
        )
        let arRoute = route.map { CoordinateTransformer.transform(serverPoint: $0, input: input) }
        let arCameraPosition = simd_float3(
            measuredARPose.columns.3.x,
            measuredARPose.columns.3.y,
            measuredARPose.columns.3.z
        )

        #expect(simd_distance(arRoute[0], arCameraPosition) < 0.001)
        #expect(abs((arRoute[1].y - arCameraPosition.y) - (route[1].z - route[0].z)) < 0.05)

        let serverLongStraightDistance =
            simd_distance(route[5], route[6]) +
            simd_distance(route[6], route[7]) +
            simd_distance(route[7], route[8])
        let arLongStraightXZDistance =
            distanceXZ(arRoute[5], arRoute[6]) +
            distanceXZ(arRoute[6], arRoute[7]) +
            distanceXZ(arRoute[7], arRoute[8])

        #expect(abs(arLongStraightXZDistance - serverLongStraightDistance) < 0.1)
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
