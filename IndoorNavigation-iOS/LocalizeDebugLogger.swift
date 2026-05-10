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
        let mapId: String?
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
                "qw": snapshot.localizePose.qw as Any,
                "floor_level": snapshot.localizePose.floorLevel as Any,
                "floor_id": snapshot.localizePose.floorId as Any
            ],
            "confidence": snapshot.confidence,
            "map_id": snapshot.mapId as Any,
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

    // MARK: - 헬퍼

    private static func makeSessionDir() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        let dir = docs.appendingPathComponent("localize_debug", isDirectory: true)
                       .appendingPathComponent(stamp, isDirectory: true)
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
