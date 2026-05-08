//
//  SuperPointDTO.swift
//  IndoorNavigation-iOS
//
//  Phase 8 B1 — SuperPoint 서버 3 endpoint DTO.
//  ⚠️ 미해결 가정 항목은 TODO(서버답) 마커로 grep 가능.
//

import Foundation

// MARK: - 공용 타입

/// 매핑 좌표계의 위치 (m).
struct WorldPosition: Codable {
    let x: Double
    let y: Double
    let z: Double
    let floorLevel: Int
}

// MARK: - 1. Localize V3

/// `POST /api/v1/buildings/{buildingId}/localize/v3` 의 multipart 메타용 컨테이너.
/// **Codable 미사용** — 실제 multipart body 빌드는 NetworkManager(B2) 책임. 본 struct 는 호출자가 인자 묶음으로 전달할 때 쓰는 값 객체.
struct LocalizeV3Request {
    let images: [Data]      // JPEG 권장. ⚠️ 권장 개수/해상도 미정 — TODO(서버답)
    let buildingId: String  // UUID 문자열
}

/// Localize V3 응답의 pose. swagger 의 `additionalProp1: {}` 형식 미정 — 두 후보 모두 디코딩 가능하도록 모든 필드 Optional 처리.
struct LocalizeV3Pose: Codable {
    // 추정 A: tx/ty/tz + 쿼터니언 (qx/qy/qz/qw)
    let tx: Double?
    let ty: Double?
    let tz: Double?
    let qx: Double?
    let qy: Double?
    let qz: Double?
    let qw: Double?
    // TODO(서버답): 4×4 행렬로 오면 아래 fallback
    let matrix: [[Double]]?
}

struct LocalizeV3Response: Codable {
    let pose: LocalizeV3Pose
    let confidence: Double
    let mapId: String              // pathfinding startScanId 로 사용
    let numMatches: Int
    let matchedImageIndex: Int
    let floorId: String
    let floorLevel: Int
}
