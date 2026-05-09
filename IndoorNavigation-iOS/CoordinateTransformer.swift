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
        var rtabCameraPose = simd_float4x4(input.serverQuaternion)
        rtabCameraPose.columns.3 = simd_float4(
            input.serverPosition.x,
            input.serverPosition.y,
            input.serverPosition.z,
            1
        )

        let invRtab = rtabCameraPose.inverse
        let W = input.arCameraPose * rtabMapToARKit * invRtab
        let point = simd_float4(serverPoint.x, serverPoint.y, serverPoint.z, 1)
        let result = W * point

        // 진단: 단계별 변환 추적 — 거리·방향 손실 위치 식별용
        let cam = input.arCameraPose.columns.3
        let pCamFrame = invRtab * point
        let qNorm = input.serverQuaternion.length
        let dCam = simd_length(simd_float3(pCamFrame.x, pCamFrame.y, pCamFrame.z))
        let dResult = simd_length(simd_float3(result.x - cam.x, result.y - cam.y, result.z - cam.z))
        print(String(format: "[CT] sp=(%.2f,%.2f,%.2f) sq=(%.3f,%.3f,%.3f,%.3f|n=%.3f) arCam=(%.2f,%.2f,%.2f) pCam=(%.2f,%.2f,%.2f|d=%.2f) → ar=(%.2f,%.2f,%.2f|d=%.2f)",
            input.serverPosition.x, input.serverPosition.y, input.serverPosition.z,
            input.serverQuaternion.imag.x, input.serverQuaternion.imag.y, input.serverQuaternion.imag.z, input.serverQuaternion.real, qNorm,
            cam.x, cam.y, cam.z,
            pCamFrame.x, pCamFrame.y, pCamFrame.z, dCam,
            result.x, result.y, result.z, dResult))

        return simd_float3(result.x, result.y, result.z)
    }
}
