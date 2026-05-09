import simd
import Foundation

struct CoordinateTransformer {

    // server camera frame 이 ARKit camera frame (X-right, Y-up, -Z forward) 와 동일하다고 가정
    // — quat.inverse 분석 결과 pCam=(1.31, 3.05, -23.35) 가 -Z forward 정합.
    // 추가 좌표축 회전 불필요 → identity.
    static let rtabMapToARKit: simd_float4x4 = matrix_identity_float4x4

    struct Input {
        let serverPosition: simd_float3     // localize (x, y, z)
        let serverQuaternion: simd_quatf    // localize (qx, qy, qz, qw)
        let arCameraPose: simd_float4x4     // matchedARPose
    }

    /// 서버 좌표(RTAB-Map) → ARKit 월드 좌표 변환
    ///
    /// 서버 quaternion 은 R_camera_from_world (W2C). SE(3) 조립 시 inverse 사용해 R_world_from_camera 로.
    static func transform(serverPoint: simd_float3, input: Input) -> simd_float3 {
        var rtabCameraPose = simd_float4x4(input.serverQuaternion.inverse)
        rtabCameraPose.columns.3 = simd_float4(
            input.serverPosition.x,
            input.serverPosition.y,
            input.serverPosition.z,
            1
        )

        let W = input.arCameraPose * rtabMapToARKit * rtabCameraPose.inverse
        let point = simd_float4(serverPoint.x, serverPoint.y, serverPoint.z, 1)
        let result = W * point

        return simd_float3(result.x, result.y, result.z)
    }
}
