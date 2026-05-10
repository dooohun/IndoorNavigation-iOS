import simd
import Foundation

struct CoordinateTransformer {

    /// OpenCV sensor frame (X right, Y down, Z forward) → ARKit camera frame (X right, Y up, Z back).
    /// Y·Z 부호 flip = diag(1, -1, -1, 1). det = +1 (X축 기준 180° 회전).
    static let openCVToARKit: simd_float4x4 =
        simd_float4x4(diagonal: SIMD4<Float>(1, -1, -1, 1))

    /// RTABMap world (X forward, Y left, Z up) → ARKit world axes (X right, Y up, Z back).
    /// 컨벤션 문서의 정적 frame 변환:
    ///   ARKit X = -RTAB Y, ARKit Y = RTAB Z, ARKit Z = -RTAB X
    /// position 좌표 (translation, path point) 에만 적용. quat 은 OpenCV camera frame 처리 별도.
    static let rtabWorldToARKitWorld: simd_float3x3 = simd_float3x3(rows: [
        SIMD3<Float>( 0, -1,  0),
        SIMD3<Float>( 0,  0,  1),
        SIMD3<Float>(-1,  0,  0)
    ])

    struct Input {
        /// camera position in RTABMap world (X forward, Y left, Z up)
        let serverPosition: simd_float3
        /// W2C = R_camera_from_world. simd_float4x4(quat.inverse) 가 R_world_from_camera.
        let serverQuaternion: simd_quatf
        /// ARKit world ← camera (frame.camera.transform 시점값)
        let arCameraPose: simd_float4x4
    }

    /// 서버 좌표(RTAB-Map world) → ARKit world 변환.
    ///
    /// 분리 처리:
    /// - position (serverPosition, serverPoint) : rtabWorldToARKitWorld 정적 행렬로 RTAB → ARKit world axes
    /// - quat (serverQuaternion) : OpenCV camera frame → openCVToARKit 적용
    ///
    /// p_ARKit_world = arCameraPose · openCVToARKit · T_W_from_C^{-1} · p_arkitAxes
    /// - p_arkitAxes = rtabWorldToARKitWorld · p_RTAB
    /// - T_W_from_C : [R_W_from_C | t_arkitAxes; 0 0 0 1]  (translation 도 ARKit axes 로 변환됨)
    static func transform(serverPoint: simd_float3, input: Input) -> simd_float3 {
        let t_arkitAxes = rtabWorldToARKitWorld * input.serverPosition
        let p_arkitAxes = rtabWorldToARKitWorld * serverPoint

        var T_W_from_C = simd_float4x4(input.serverQuaternion.inverse)
        T_W_from_C.columns.3 = simd_float4(t_arkitAxes.x, t_arkitAxes.y, t_arkitAxes.z, 1)

        let W = input.arCameraPose * openCVToARKit * T_W_from_C.inverse
        let point = simd_float4(p_arkitAxes.x, p_arkitAxes.y, p_arkitAxes.z, 1)
        let result = W * point

        return simd_float3(result.x, result.y, result.z)
    }
}
