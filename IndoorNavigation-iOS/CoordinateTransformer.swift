import simd

struct CoordinateTransformer {

    // RTAB-Map(X-forward, Y-left, Z-up) → ARKit(X-right, Y-up, Z-backward)
    static let rtabMapToARKit: simd_float4x4 = {
        var m = simd_float4x4(1)
        m.columns.0 = simd_float4( 0,  0, -1, 0)
        m.columns.1 = simd_float4(-1,  0,  0, 0)
        m.columns.2 = simd_float4( 0,  1,  0, 0)
        m.columns.3 = simd_float4( 0,  0,  0, 1)
        return m
    }()

    struct Input {
        let serverPosition: simd_float3     // localize (x, y, z)
        let serverQuaternion: simd_quatf    // localize (qx, qy, qz, qw)
        let arCameraPose: simd_float4x4     // matchedARPose
    }

    /// 서버 좌표(RTAB-Map) → ARKit 월드 좌표 변환
    ///
    /// W = arCameraPose × rtabMapToARKit × inv(rtabCameraPose)
    /// result = W × point_rtab
    static func transform(serverPoint: simd_float3, input: Input) -> simd_float3 {
        // 1. RTAB-Map 카메라 포즈 행렬 (body → world)
        var rtabCameraPose = simd_float4x4(input.serverQuaternion)
        rtabCameraPose.columns.3 = simd_float4(
            input.serverPosition.x,
            input.serverPosition.y,
            input.serverPosition.z,
            1
        )

        // 2. 월드 변환 행렬
        //    로컬라이즈 시점에 두 포즈가 같은 물리적 순간을 나타냄
        //    body frame 차이(rtabMapToARKit)를 포함한 완전한 rigid transform
        let W = input.arCameraPose * rtabMapToARKit * rtabCameraPose.inverse

        // 3. RTAB-Map 월드 좌표 → ARKit 월드 좌표
        let point = simd_float4(serverPoint.x, serverPoint.y, serverPoint.z, 1)
        let result = W * point

        return simd_float3(result.x, result.y, result.z)
    }
}
