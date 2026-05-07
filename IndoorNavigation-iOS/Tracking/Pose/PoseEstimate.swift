import Foundation
import simd

/// PnP 6DoF 측위 결과. 카메라(클라) 좌표계 ↔ 매핑 world 좌표계 사이의 변환.
///
/// 의미: world 좌표 X 의 점을 카메라 좌표계로:
///     X_cam = rotation * X_world + translation
/// 즉 rotation, translation 은 "world → camera" 변환. ARKit pose 와 정렬 시 역행렬 필요.
struct PoseEstimate {
    /// world → camera 회전 행렬 (orthonormal, det = +1).
    let rotation: simd_float3x3
    /// world → camera 평행 이동 (단위: 매핑 좌표계 m).
    let translation: SIMD3<Float>
    /// PnP solve 에 사용된 매칭 쌍 수.
    let pointCount: Int
    /// 평균 재투영 오차 (픽셀 단위). 작을수록 정확.
    let reprojectionError: Float

    /// 4×4 homogeneous transform [R | t; 0 0 0 1] (world → camera).
    var transform4x4: simd_float4x4 {
        let r = rotation
        return simd_float4x4(
            SIMD4<Float>(r.columns.0, 0),
            SIMD4<Float>(r.columns.1, 0),
            SIMD4<Float>(r.columns.2, 0),
            SIMD4<Float>(translation, 1)
        )
    }
}
