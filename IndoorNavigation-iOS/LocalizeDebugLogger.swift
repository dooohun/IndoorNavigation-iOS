import Foundation
import UIKit
import simd

/// V3 측위 + pathfinding 후 디버깅용 데이터 일괄 dump.
///
/// 저장 경로: `Documents/localize_debug/<yyyyMMdd-HHmmss>/`
///   - `meta.json` — matchedImageIndex, ARKit pose, localize pose, steps[], 변환된 AR 좌표
///   - `matched.jpg` — 서버가 매칭에 사용한 캡처 프레임
///
/// 디바이스에서 Files app(또는 Xcode → Devices → Container) 으로 추출.
enum LocalizeDebugLogger {

    struct Snapshot {
        let matchedImageIndex: Int?
        let matchedImage: UIImage?
        let matchedARPose: simd_float4x4
        let localizePose: SLAMPose
        let confidence: Double
        let numMatches: Int?
        let floorId: String?
        let floorLevel: Int?
        let steps: [PathStepResponse]
        let transformedSteps: [(stepNumber: Int, ar: simd_float3)]
    }

    @discardableResult
    static func dump(_ snapshot: Snapshot) -> URL? {
        guard let dir = makeSessionDir() else {
            print("[LocalizeDebug] Documents 디렉터리 접근 실패")
            return nil
        }

        // 1) matched.jpg
        if let img = snapshot.matchedImage,
           let jpeg = img.jpegData(compressionQuality: 0.85) {
            let url = dir.appendingPathComponent("matched.jpg")
            try? jpeg.write(to: url, options: .atomic)
        }

        // 2) meta.json
        let meta: [String: Any] = [
            "captured_at": isoTimestamp(),
            "matched_image_index": snapshot.matchedImageIndex as Any,
            "matched_ar_pose_4x4": matrixToArray(snapshot.matchedARPose),
            "localize_pose": [
                "x": snapshot.localizePose.x as Any,
                "y": snapshot.localizePose.y as Any,
                "z": snapshot.localizePose.z as Any,
                "qx": snapshot.localizePose.qx as Any,
                "qy": snapshot.localizePose.qy as Any,
                "qz": snapshot.localizePose.qz as Any,
                "qw": snapshot.localizePose.qw as Any
            ],
            "confidence": snapshot.confidence,
            "num_matches": snapshot.numMatches as Any,
            "floor_id": snapshot.floorId as Any,
            "floor_level": snapshot.floorLevel as Any,
            "steps": snapshot.steps.map { s -> [String: Any] in
                [
                    "step_number": s.stepNumber,
                    "floor_level": s.floorLevel as Any,
                    "position": [
                        "x": s.position.x,
                        "y": s.position.y,
                        "z": s.position.z
                    ],
                    "instruction": s.instruction,
                    "node_id": s.nodeId as Any
                ]
            },
            "transformed_ar_points": snapshot.transformedSteps.map { t in
                [
                    "step_number": t.stepNumber,
                    "ar": ["x": t.ar.x, "y": t.ar.y, "z": t.ar.z]
                ]
            }
        ]

        let url = dir.appendingPathComponent("meta.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            print("[LocalizeDebug] dump 저장 → \(dir.path)")
            return dir
        } catch {
            print("[LocalizeDebug] meta.json 쓰기 실패: \(error)")
            return nil
        }
    }

    // MARK: - 주기 V3 재측위 dump

    /// 주기 V3 재측위 응답마다 prev/new/blended pose + 변환 결과 + 캡처 N장을 일괄 저장.
    /// 좌회전 후 wrong-match 디버깅용 — 응답 자체가 잘못 잡혔는지 blend 가 prev 쪽으로 끌어당기는지 분리.
    struct PeriodicSnapshot {
        let capturedImages: [UIImage]           // 응답 시점 캡처된 N장
        let capturedARPoses: [simd_float4x4]    // 위와 동일 인덱스
        let matchedImageIndex: Int?
        let prevLocalizedPose: SLAMPose?        // blend 전 (nil 이면 첫 호출 / hard-set 분기)
        let newServerPose: SLAMPose             // 응답 그대로
        let blendedLocalizedPose: SLAMPose?     // blend 결과 (실제 localizedPose 에 저장된 값). reject 시 nil.
        let prevMatchedARPose: simd_float4x4?   // blend 직전 matchedARPose
        let newMatchedARPose: simd_float4x4     // 응답 후 적용된 matchedARPose
        let confidence: Double
        let numMatches: Int?
        let floorLevel: Int?
        let floorId: String?
        let blendAlpha: Float
        let deltaTranslationM: Float            // |new - prev|
        let deltaRotationDeg: Float             // quaternion angle diff (deg)
        let arCameraPosAtCapture: simd_float3?  // 캡처 시점 AR 카메라 XYZ
        let steps: [PathStep]                   // lastPathSteps 그대로
        let transformedStepsByPrev: [(stepNumber: Int, ar: simd_float3)]
        let transformedStepsByNew: [(stepNumber: Int, ar: simd_float3)]
        let transformedStepsByBlended: [(stepNumber: Int, ar: simd_float3)]
        /// nil 이면 정상 accepted, 그 외엔 가드 fail 사유 (e.g. "confidence_below_threshold")
        let rejectReason: String?
    }

    @discardableResult
    static func dumpPeriodic(_ snapshot: PeriodicSnapshot) -> URL? {
        let dirPrefix = snapshot.rejectReason == nil ? "periodic-" : "periodic-rejected-"
        guard let dir = makeSessionDir(prefix: dirPrefix) else {
            print("[PeriodicDebug] Documents 디렉터리 접근 실패")
            return nil
        }

        // 1) captured-{i}.jpg
        for (idx, image) in snapshot.capturedImages.enumerated() {
            guard let jpeg = image.jpegData(compressionQuality: 0.85) else { continue }
            let url = dir.appendingPathComponent("captured-\(idx).jpg")
            try? jpeg.write(to: url, options: .atomic)
        }

        // 2) meta.json
        let meta: [String: Any] = [
            "captured_at": isoTimestamp(),
            "kind": snapshot.rejectReason == nil ? "periodic_relocalize" : "periodic_relocalize_rejected",
            "reject_reason": snapshot.rejectReason as Any,
            "matched_image_index": snapshot.matchedImageIndex as Any,
            "captured_image_count": snapshot.capturedImages.count,
            "confidence": snapshot.confidence,
            "num_matches": snapshot.numMatches as Any,
            "floor_id": snapshot.floorId as Any,
            "floor_level": snapshot.floorLevel as Any,
            "blend_alpha": snapshot.blendAlpha,
            "delta_translation_m": snapshot.deltaTranslationM,
            "delta_rotation_deg": snapshot.deltaRotationDeg,
            "ar_camera_pos_at_capture": snapshot.arCameraPosAtCapture.map {
                ["x": $0.x, "y": $0.y, "z": $0.z]
            } as Any,
            "captured_ar_poses_4x4": snapshot.capturedARPoses.map { matrixToArray($0) },
            "prev_localized_pose": slamPoseToDict(snapshot.prevLocalizedPose) as Any,
            "new_server_pose": slamPoseToDict(snapshot.newServerPose) as Any,
            "blended_localized_pose": slamPoseToDict(snapshot.blendedLocalizedPose) as Any,
            "prev_matched_ar_pose_4x4": snapshot.prevMatchedARPose.map { matrixToArray($0) } as Any,
            "new_matched_ar_pose_4x4": matrixToArray(snapshot.newMatchedARPose),
            "steps": snapshot.steps.map { s -> [String: Any] in
                [
                    "step_number": s.stepNumber,
                    "floor_level": s.floorLevel as Any,
                    "position": [
                        "x": s.position?.x as Any,
                        "y": s.position?.y as Any,
                        "z": s.position?.z as Any
                    ],
                    "instruction": s.instruction as Any,
                    "node_id": s.nodeId as Any
                ]
            },
            "transformed_ar_points_by_prev": snapshot.transformedStepsByPrev.map { t in
                ["step_number": t.stepNumber, "ar": ["x": t.ar.x, "y": t.ar.y, "z": t.ar.z]]
            },
            "transformed_ar_points_by_new": snapshot.transformedStepsByNew.map { t in
                ["step_number": t.stepNumber, "ar": ["x": t.ar.x, "y": t.ar.y, "z": t.ar.z]]
            },
            "transformed_ar_points_by_blended": snapshot.transformedStepsByBlended.map { t in
                ["step_number": t.stepNumber, "ar": ["x": t.ar.x, "y": t.ar.y, "z": t.ar.z]]
            }
        ]

        let url = dir.appendingPathComponent("meta.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            print("[PeriodicDebug] dump 저장 → \(dir.path)")
            return dir
        } catch {
            print("[PeriodicDebug] meta.json 쓰기 실패: \(error)")
            return nil
        }
    }

    private static func slamPoseToDict(_ pose: SLAMPose?) -> [String: Any]? {
        guard let pose else { return nil }
        return [
            "x": pose.x as Any,
            "y": pose.y as Any,
            "z": pose.z as Any,
            "qx": pose.qx as Any,
            "qy": pose.qy as Any,
            "qz": pose.qz as Any,
            "qw": pose.qw as Any
        ]
    }

    // MARK: - 헬퍼

    /// 앱 세션당 1회만 기존 localize_debug 폴더를 통째 삭제 (요청: 매 실행마다 클린 상태로 시작).
    private static var didClearLocalizeDebug = false

    private static func makeSessionDir(prefix: String = "") -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let baseDir = docs.appendingPathComponent("localize_debug", isDirectory: true)

        // 첫 호출 시 기존 데이터 일괄 제거 (없으면 try? 가 silently no-op).
        if !didClearLocalizeDebug {
            didClearLocalizeDebug = true
            try? FileManager.default.removeItem(at: baseDir)
        }

        // 폴더명: KST(Asia/Seoul) 기준 "yyyy-MM-dd HH:mm:ss" 까지.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = prefix + formatter.string(from: Date())
        let dir = baseDir.appendingPathComponent(stamp, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    private static func isoTimestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private static func matrixToArray(_ m: simd_float4x4) -> [[Float]] {
        // simd_float4x4 는 column-major. JSON 으로는 row-major 4×4 로 직렬화.
        return (0..<4).map { row in
            (0..<4).map { col in
                m[col][row]
            }
        }
    }
}
