import simd
import Foundation

struct CoordinateTransformer {

    // 디버그 테스트: portrait 에서 path 가 90° 회전된 채 렌더되는 문제 진단용.
    // R_z(-π/2) (= R_z(3π/2)) — 카메라 sensor frame Z 축 기준 90° CW 회전. (X→-Y, Y→X)
    // hand-calc 상 직진 + 좌회전 끝 패턴 예상 부호.
    //
    // 기존 (이전 운영값):
    //   ROS(x=forward, y=left, z=up) → ARKit(x=right, y=up, z=back)
    //   row-major:
    //     [ 0  -1   0   0 ]
    //     [ 0   0   1   0 ]
    //     [-1   0   0   0 ]
    //     [ 0   0   0   1 ]
    static let rtabMapToARKit: simd_float4x4 = simd_float4x4(
        simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 0, 1))
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
