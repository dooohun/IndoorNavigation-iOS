import Foundation
import simd
import CoreML

/// SuperPoint 추출 1프레임 결과.
/// Phase 8 (서버 로컬라이즈), Phase 10 (PnP) 의 입력원.
struct SuperPointFrame {
    let intrinsics: simd_float3x3
    let timestamp: TimeInterval
    /// 입력 이미지 좌표계 (픽셀, 추론 해상도 480×640 기준) 의 (u, v, score)
    let keypoints: [SIMD3<Float>]
    /// N × 256, float16. L2 정규화. 본 PR 스텁에서는 dummy 값.
    let descriptors: MLMultiArray
    /// 추론에 사용한 입력 해상도 — 디버그 오버레이가 sceneView 좌표로 매핑할 때 사용.
    let inputSize: CGSize
}
