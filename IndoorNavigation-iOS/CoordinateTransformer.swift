import simd
import Foundation

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

        // 진단 1: 현재 변환 결과
        let cam = input.arCameraPose.columns.3
        let pCamFrame = invRtab * point
        let dCam = simd_length(simd_float3(pCamFrame.x, pCamFrame.y, pCamFrame.z))
        print(String(format: "[CT] pCam=(%.2f,%.2f,%.2f|d=%.2f) → ar=(%.2f,%.2f,%.2f)",
            pCamFrame.x, pCamFrame.y, pCamFrame.z, dCam,
            result.x, result.y, result.z))

        // 진단 2: server quat 이 R_camera_from_world (W2C) 일 가설
        // 현재 코드는 R_world_from_camera (C2W) 가정. 만약 W2C 면 quat inverse 후 SE(3) 조립
        var rtabAlt = simd_float4x4(input.serverQuaternion.inverse)
        rtabAlt.columns.3 = simd_float4(input.serverPosition.x, input.serverPosition.y, input.serverPosition.z, 1)
        let invAlt = rtabAlt.inverse
        let pCamAlt = invAlt * point
        let dCamAlt = simd_length(simd_float3(pCamAlt.x, pCamAlt.y, pCamAlt.z))
        let resultAlt = input.arCameraPose * rtabMapToARKit * invAlt * point
        print(String(format: "[CT-ALT] (quat.inverse) pCam=(%.2f,%.2f,%.2f|d=%.2f) → ar=(%.2f,%.2f,%.2f)",
            pCamAlt.x, pCamAlt.y, pCamAlt.z, dCamAlt,
            resultAlt.x, resultAlt.y, resultAlt.z))
        _ = cam

        return simd_float3(result.x, result.y, result.z)
    }
}
