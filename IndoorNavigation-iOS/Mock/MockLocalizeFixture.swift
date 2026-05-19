//
//  MockLocalizeFixture.swift
//
//  2026-05-13 사용자 제공 JSON 기반 mock fixture.
//  - 출처: /api/slam/v3/localize 응답 + 부속 pathfinding steps + transformed_ar_points dump
//  - 사용처: ARNavigationLogic.injectMockLocalizeFixture() (DEBUG 전용)
//  - 활성화: ARNavigationLogic.useMockLocalizeFixture = true
//

#if DEBUG
import Foundation
import simd

enum MockLocalizeFixture {

    /// SLAMLocalizeResponse 리터럴. JSON 디코딩 경로 회피.
    /// 필드 순서는 DTOs.swift 의 SLAMLocalizeResponse 선언 순서(pose, confidence,
    /// numMatches, matchedImageIndex, floorId, floorLevel, areaId) 와 일치.
    static let response: SLAMLocalizeResponse = SLAMLocalizeResponse(
        pose: SLAMPose(
            x: 0.36640310845746105,
            y: 0.3705186704040671,
            z: 0.08176946624761877,
            qx: 0.6062299427760970,
            qy: 0.3886970319194225,
            qz: 0.2201992447814049,
            qw: 0.6579606116299217
        ),
        confidence: 0.49016100178890876,
        numMatches: 274,
        matchedImageIndex: 0,
        floorId: "f3171970-af3b-48a0-a7c0-de05144a3749",
        floorLevel: -3,
        areaId: "00000000-0000-0000-0000-000000000000"
    )

    /// 사용자 JSON steps[] → PathStep 7개.
    static let steps: [PathStep] = [
        PathStep(stepNumber: 1, floorLevel: -3,
                 position: Position(x: 0.3664031028747559, y: 0.3705186843872070, z: 0.0817694664001465),
                 instruction: "Start.",
                 nodeId: "bec2e2ee-6a37-4389-8c77-6a5175cdf2c2"),
        PathStep(stepNumber: 2, floorLevel: -3,
                 position: Position(x: 1.7070956230163574, y: 1.2226395606994629, z: -0.0321019217371941),
                 instruction: "Proceed to 238호.",
                 nodeId: "9982262b-9fad-5f6c-9c9a-54f1c545653e"),
        PathStep(stepNumber: 3, floorLevel: -3,
                 position: Position(x: 2.0981778341854973, y: 0.7786846337749940, z: -1.5114732881800133),
                 instruction: "Proceed to poi_attach.",
                 nodeId: "78beeebd-29df-4e50-995b-699c89b88312"),
        PathStep(stepNumber: 4, floorLevel: -3,
                 position: Position(x: 18.09533651415849, y: 14.87066516956445, z: -1.5486706173692326),
                 instruction: "Proceed to corridor.",
                 nodeId: "00775348-0867-5491-a483-8bb650c466b3"),
        PathStep(stepNumber: 5, floorLevel: -3,
                 position: Position(x: 12.900480518536284, y: 20.86662749788351, z: -1.5655062100049673),
                 instruction: "Proceed to poi_attach.",
                 nodeId: "2e98cd32-b5ed-4b19-ace4-a052ac4d7dd9"),
        PathStep(stepNumber: 6, floorLevel: -3,
                 position: Position(x: 12.646512890231261, y: 21.159759845192603, z: -1.5823418026407019),
                 instruction: "Proceed to poi_attach.",
                 nodeId: "7580dadc-d871-4dcf-b8d9-3d66e8fb228d"),
        PathStep(stepNumber: 7, floorLevel: -3,
                 position: Position(x: 12.647529602050781, y: 21.160640716552734, z: 0.09618106484413147),
                 instruction: "Proceed to 250호.",
                 nodeId: "150b31f8-68b6-5232-806e-0439eb521a39")
    ]

    /// JSON row-major matched_ar_pose_4x4 → simd column-major (init(rows:)가 자동 변환).
    static let matchedARPose: simd_float4x4 = {
        let rows: [SIMD4<Float>] = [
            SIMD4<Float>( 0.0693107321858406,  0.9071482419967651,  0.4150641858577728, -0.0169704575091600),
            SIMD4<Float>(-0.9742690920829773, -0.0278940852731466,  0.2236554771661758,  0.1553852707147598),
            SIMD4<Float>( 0.2144664824008942, -0.4198858737945557,  0.8818731307983398,  0.0739149600267410),
            SIMD4<Float>( 0,                   0,                   0,                   1.0000001192092896)
        ]
        return simd_float4x4(rows: rows)
    }()
}
#endif
