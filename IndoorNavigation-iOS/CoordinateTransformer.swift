import simd
import Foundation

struct CoordinateTransformer {

    /// RTAB body camera frame (X forward, Y left, Z up) → ARKit camera frame (X right, Y up, Z back).
    /// ARKit X = -RTAB Y, ARKit Y = RTAB Z, ARKit Z = -RTAB X. det=+1, rigid.
    static let rtabCameraToARKit: simd_float4x4 = simd_float4x4(rows: [
        SIMD4<Float>( 0, -1,  0, 0),
        SIMD4<Float>( 0,  0,  1, 0),
        SIMD4<Float>(-1,  0,  0, 0),
        SIMD4<Float>( 0,  0,  0, 1)
    ])

    struct Input {
        /// camera position in RTABMap world (X forward, Y left, Z up)
        let serverPosition: simd_float3
        /// C2W = R_world_from_camera (RTAB-Map 표준 출력). simd_float4x4(quat) 의 회전부가 그대로 R_world_from_camera. .inverse 적용 X.
        /// camera frame = RTAB body (X forward, Y left, Z up).
        let serverQuaternion: simd_quatf
        /// ARKit world ← camera (frame.camera.transform 시점값)
        let arCameraPose: simd_float4x4
    }

    /// 서버 좌표(RTAB-Map world) → ARKit world 변환.
    ///
    /// 카메라 frame 을 매개로 변환되므로 RTAB world axes ↔ ARKit world axes 차이는
    /// arCameraPose 회전이 자동 흡수한다 (이번엔 카메라 frame 변환만 axis-aware).
    ///
    ///   p_ARKit_world = arCameraPose · rtabCameraToARKit · T_W_from_C^{-1} · (serverPoint, 1)
    ///
    /// - T_W_from_C : [R(q) | serverPosition; 0 1]  (R(q) = R_world_from_camera, q 직접 사용)
    /// - rtabCameraToARKit : RTAB body camera frame → ARKit camera frame
    /// - arCameraPose : ARKit world ← ARKit camera (frame.camera.transform 시점값)
    /// - 서버 quat 은 RTAB-Map 표준 R_world_from_camera. .inverse 적용 X.
    static func transform(serverPoint: simd_float3, input: Input) -> simd_float3 {
        var T_W_from_C = simd_float4x4(input.serverQuaternion)
        T_W_from_C.columns.3 = simd_float4(input.serverPosition.x,
                                           input.serverPosition.y,
                                           input.serverPosition.z, 1)

        let W = input.arCameraPose * rtabCameraToARKit * T_W_from_C.inverse
        let p = simd_float4(serverPoint.x, serverPoint.y, serverPoint.z, 1)
        let result = W * p

        return simd_float3(result.x, result.y, result.z)
    }
}
