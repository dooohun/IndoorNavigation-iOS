import simd
import Foundation

struct CoordinateTransformer {

    /// Server camera frame (portrait, X forward, Y up, Z right) → ARKit camera frame (X right, Y up, Z back).
    ///
    /// 핵심: server pose 는 **portrait** 기준이다 — DB 키프레임이 portrait(720×960)이고
    /// localize 시 landscape 쿼리를 portrait 로 회전(ROTATE_270)해 매칭하므로, PnP 가
    /// 복원하는 pose 의 camera-up(Y)은 화면 세로 위쪽 = 천장(world up, 측정상 up·Z≈0.94)이다.
    /// 반면 ARKit `frame.camera.transform` 은 **landscape 센서 고정** 프레임이라, 폰을 세로로
    /// 들면 ARKit camera-up(Y)은 수평(landscape-right 가 중력 방향)을 가리킨다.
    /// → server-cam 과 ARKit-cam 사이에 **광축(optical) 90° roll** 차이가 존재한다.
    ///
    /// 이 90° roll 을 빼먹으면: 전방축 경로(화장실)는 roll 축이 시선축이라 멀쩡해 보이지만,
    /// 측면 경로(베란다)는 가로 변위가 ARKit 수직(Y)으로 새서 경로가 위로 솟고 위치가 틀어진다.
    /// 실측: 평탄 경로(높이 1.65m)가 보정 전 Y spread 9.7m → 보정 후 1.55m.
    ///
    /// 행렬 = Rz(90°)·(naive X=Z, Y=Y, Z=-X). det=+1, rigid.
    ///   ARKit X(right) = -Server Y(up→portrait 기준 세로위 = landscape 기준 아래)
    ///   ARKit Y(up)    = +Server Z(right)
    ///   ARKit Z(back)  = -Server X(forward)
    static let rtabCameraToARKit: simd_float4x4 = simd_float4x4(rows: [
        SIMD4<Float>( 0, -1,  0, 0),
        SIMD4<Float>( 0,  0,  1, 0),
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
