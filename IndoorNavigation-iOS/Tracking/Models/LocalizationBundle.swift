import Foundation

/// Phase 8 서버 로컬라이즈 응답 (또는 Phase 9 청크) 의 클라이언트 표현.
///
/// 서버 lightglue SuperPoint 매핑 결과(route_bundle.npz) 를 JSON 으로 변환한 형태.
/// `tools/npz_to_json.py` 가 npz → 본 구조와 일치하는 JSON 으로 변환한다.
///
/// mock 단계: `MockBundleProvider` 가 앱 번들에 포함된 mock_bundle.json 을 로드.
/// 운영 단계: `NetworkManager` 가 서버 endpoint 응답을 본 구조로 디코딩 (Phase 8).
struct LocalizationBundle: Decodable {
    let manifest: BundleManifest
    let keyframes: [BundleKeyframe]
}

/// 빌딩·층·경로 단위 메타데이터.
struct BundleManifest: Decodable {
    let version: String
    let scanId: String
    let floorId: String
    let floorLevel: Int
    let destination: String
    let intrinsics: BundleIntrinsics
    /// ARKit camera 좌표계 ↔ 서버 매핑 좌표계 변환 (3×4 행렬, row-major).
    /// 정확한 변환 방향은 서버 합의 항목.
    let localTransform3x4: [[Double]]
    let keyframeCount: Int

    enum CodingKeys: String, CodingKey {
        case version
        case scanId = "scan_id"
        case floorId = "floor_id"
        case floorLevel = "floor_level"
        case destination
        case intrinsics
        case localTransform3x4 = "local_transform_3x4"
        case keyframeCount = "keyframe_count"
    }
}

/// 매핑 카메라 내부 파라미터. keypoint 좌표는 본 (width, height) 픽셀 단위.
struct BundleIntrinsics: Decodable {
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let width: Int
    let height: Int
}

/// 단일 keyframe — 위치 + SuperPoint 추출 결과 + 매핑된 3D 좌표.
struct BundleKeyframe: Decodable {
    let index: Int
    /// 4×4 6DoF pose. `pose_4x4[3] == [0, 0, 0, 1]` (homogeneous).
    let pose4x4: [[Double]]
    /// (N, 2) 픽셀 좌표 (manifest.intrinsics 의 width × height 단위).
    let keypoints: [[Float]]
    /// base64 FP16 row-major (N, 256). L2 정규화됨.
    let descriptorsB64: String
    /// (N, 3) 매핑 좌표계의 3D 점. multi-view triangulation 실패한 점은 nil.
    /// PnP 에 사용 가능한 점은 nil 아닌 항목만.
    let world3d: [[Float]?]
    /// base64 FP16 (384,) — 장소 인식용 global descriptor (NetVLAD/AnyLoc 추정).
    let globalDescriptorB64: String

    enum CodingKeys: String, CodingKey {
        case index
        case pose4x4 = "pose_4x4"
        case keypoints
        case descriptorsB64 = "descriptors_b64"
        case world3d = "world_3d"
        case globalDescriptorB64 = "global_descriptor_b64"
    }
}
