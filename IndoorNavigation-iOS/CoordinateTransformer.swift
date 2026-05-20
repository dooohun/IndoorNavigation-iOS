import simd
import Foundation

struct CoordinateTransformer {

    /// Server camera frame (X forward, Y up, Z right) → ARKit camera frame (X right, Y up, Z back).
    /// ARKit X = +Server Z, ARKit Y = +Server Y, ARKit Z = -Server X. det=+1, rigid.
    ///
    /// The server world uses Z as vertical, while route steps move on the server XY plane.
    /// With this camera-frame bridge, points on the same server floor stay on ARKit's XZ
    /// plane instead of leaking long route distance into ARKit Y.
    static let rtabCameraToARKit: simd_float4x4 = simd_float4x4(rows: [
        SIMD4<Float>( 0,  0,  1, 0),
        SIMD4<Float>( 0,  1,  0, 0),
        SIMD4<Float>(-1,  0,  0, 0),
        SIMD4<Float>( 0,  0,  0, 1)
    ])

    struct Input {
        /// camera position in server world (Z-up RH; 경로 step 좌표와 동일 frame)
        let serverPosition: simd_float3
        /// R_world_from_camera. simd_float4x4(quat) 의 회전부가 그대로 R_world_from_camera. .inverse 적용 X.
        /// camera frame = X forward, Y up, Z right.
        let serverQuaternion: simd_quatf
        /// ARKit world ← camera (frame.camera.transform 시점값)
        let arCameraPose: simd_float4x4
    }

    /// 서버 좌표(server world, Z-up RH) → ARKit world 변환.
    ///
    /// 카메라 frame 을 매개로 변환되므로 server world axes ↔ ARKit world axes 차이는
    /// arCameraPose 회전이 자동 흡수한다 (카메라 frame 변환만 axis-aware).
    ///
    ///   p_ARKit_world = arCameraPose · rtabCameraToARKit · T_W_from_C^{-1} · (serverPoint, 1)
    ///
    /// - T_W_from_C : [R(q) | serverPosition; 0 1]  (R(q) = R_world_from_camera, q 직접 사용)
    /// - rtabCameraToARKit : server camera frame → ARKit camera frame
    /// - arCameraPose : ARKit world ← ARKit camera (frame.camera.transform 시점값)
    /// - 서버 quat = R_world_from_camera. .inverse 적용 X.
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
