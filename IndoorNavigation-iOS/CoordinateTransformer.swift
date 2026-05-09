import simd
import Foundation

struct CoordinateTransformer {

    // R_z(π) = Z 축 기준 180° 회전. server camera frame 의 X, Y 결과 부호 반전.
    // 실측 단서:
    //  - server +Y (좌회전 5.4m) → ARKit +X (우측) 으로 매핑 → 좌우 반전 → X 부호 반전 필요
    //  - server +Z (위 1.6m)    → ARKit -Y (아래) 로 매핑 → 위아래 반전 → Y 부호 반전 필요
    //  - Z(forward) 는 정합 → Z 그대로
    // 결과: rtabMapToARKit = R_z(π) (proper rotation, det +1)
    static let rtabMapToARKit: simd_float4x4 = simd_float4x4(
        simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))
    )

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
