//
// 이 폴더(__DebugOverlay__)는 디버그 시각화 전용입니다.
// 프로덕션 배포 전 폴더 통째로 삭제 가능합니다.
//

#if DEBUG
import Foundation
import UIKit
import CoreML
import simd

// MARK: - Codable payload

/// 클라이언트가 디스크로 dump 하는 1프레임 SuperPoint 결과.
/// Python 측 mock 디코더(`tools/npz_to_json.py`)가 그대로 읽을 수 있도록
/// `BundleIntrinsics` 의 키 (fx/fy/cx/cy/width/height) 와 동일한 네이밍 유지.
struct ClientFrameDump: Encodable {
    let kind: String                  // "client_dump" 고정
    let capturedAt: String            // ISO8601
    let intrinsics: DumpIntrinsics
    let arPose4x4: [[Float]]?         // ARKit camera transform, nil 가능
    let deviceOrientation: String     // "portrait" | "landscape"
    let keypoints: [[Float]]          // (N, 2) — (u, v)만, score 제외
    let descriptorsB64: String        // base64 FP16 (N, 256) row-major

    enum CodingKeys: String, CodingKey {
        case kind
        case capturedAt = "captured_at"
        case intrinsics
        case arPose4x4 = "ar_pose_4x4"
        case deviceOrientation = "device_orientation"
        case keypoints
        case descriptorsB64 = "descriptors_b64"
    }

    /// 옵셔널 nil 일 때 JSONEncoder 기본 동작은 키 자체를 누락하지만,
    /// Python 측 디코더가 일관된 스키마(키 항상 존재)를 가정하므로
    /// 명시적으로 `encodeNil(forKey:)` 호출해 `"ar_pose_4x4": null` 로 직렬화.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(intrinsics, forKey: .intrinsics)
        if let arPose4x4 = arPose4x4 {
            try container.encode(arPose4x4, forKey: .arPose4x4)
        } else {
            try container.encodeNil(forKey: .arPose4x4)
        }
        try container.encode(deviceOrientation, forKey: .deviceOrientation)
        try container.encode(keypoints, forKey: .keypoints)
        try container.encode(descriptorsB64, forKey: .descriptorsB64)
    }
}

/// `BundleIntrinsics` 와 키 정확히 동일 (fx/fy/cx/cy/width/height) — Python 재사용을 위해.
struct DumpIntrinsics: Encodable {
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let width: Int
    let height: Int
}

// MARK: - Errors

enum DumperError: Error, CustomStringConvertible {
    case descriptorShapeMismatch(actual: [Int])
    case descriptorDataTypeMismatch(actual: MLMultiArrayDataType)
    case emptyKeypoints
    case dataPointerUnavailable
    case documentsDirectoryUnavailable
    case fileWriteFailed(underlying: Error)

    var description: String {
        switch self {
        case .descriptorShapeMismatch(let actual):
            return "descriptor shape mismatch: \(actual) (expected [N, 256])"
        case .descriptorDataTypeMismatch(let actual):
            return "descriptor dtype mismatch: \(actual) (expected .float16)"
        case .emptyKeypoints:
            return "frame.keypoints is empty"
        case .dataPointerUnavailable:
            return "MLMultiArray dataPointer 접근 실패"
        case .documentsDirectoryUnavailable:
            return "Documents 디렉터리 위치 확인 실패"
        case .fileWriteFailed(let err):
            return "파일 쓰기 실패: \(err)"
        }
    }
}

// MARK: - Dumper

/// 다음 ARFrame 한 장을 캡처해 `Documents/superpoint_dumps/dump-yyyyMMdd-HHmmss.json` 으로 쓰는 헬퍼.
///
/// 사용 흐름:
///   1. 디버그 UI 의 DUMP 버튼 → `requestNextDump()` 으로 flag set
///   2. ARSessionDelegate.session(_:didUpdate:) → ARNavigationLogic.processARFrame
///      에서 `consumeIfRequested(...)` 호출 → flag true 시 dump 후 false 로 자동 해제
///
/// **스레딩 가정**: ARSessionDelegate 콜백은 ARKit 이 main 큐에서 호출하므로,
/// `pendingDumpRequest` 의 set/consume 모두 main thread 에서 일어난다.
/// 따라서 별도 lock 은 두지 않는다.
final class SuperPointFrameDumper {

    private(set) var pendingDumpRequest: Bool = false

    init() {}

    /// 다음 1프레임 dump 를 요청. 이미 pending 이면 멱등 (덮어쓰기).
    func requestNextDump() {
        pendingDumpRequest = true
    }

    /// flag true 면 dump 수행 후 false 로 해제. flag false 면 아무 동작 안함.
    /// completion 은 dump 가 실제 수행된 경우에만 호출.
    func consumeIfRequested(
        frame: SuperPointFrame,
        arPose: simd_float4x4?,
        completion: (Result<URL, Error>) -> Void
    ) {
        guard pendingDumpRequest else { return }
        pendingDumpRequest = false
        do {
            let url = try writeDump(frame: frame, arPose: arPose)
            completion(.success(url))
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: - File write

    private func writeDump(frame: SuperPointFrame, arPose: simd_float4x4?) throws -> URL {
        let date = Date()
        let orientation = UIDevice.current.orientation.isLandscape ? "landscape" : "portrait"
        let data = try Self.encode(frame: frame, arPose: arPose, orientation: orientation, date: date)

        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw DumperError.documentsDirectoryUnavailable
        }
        let dir = docs.appendingPathComponent("superpoint_dumps", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw DumperError.fileWriteFailed(underlying: error)
        }

        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        nameFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "dump-\(nameFormatter.string(from: date)).json"
        let url = dir.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DumperError.fileWriteFailed(underlying: error)
        }

        let kpCount = frame.keypoints.count
        print("[Dumper] saved: \(url.lastPathComponent) (kp=\(kpCount), desc=\(data.count)B)")
        return url
    }

    // MARK: - Encode (단위 테스트 가능 경로)

    /// 파일 IO 없이 JSON Data 만 반환. 단위 테스트용.
    /// shape/dtype/empty 검증 후 base64 직렬화 + JSON 인코딩까지 수행.
    static func encode(
        frame: SuperPointFrame,
        arPose: simd_float4x4?,
        orientation: String,
        date: Date
    ) throws -> Data {
        // 1. descriptor shape/dtype 검증
        let shape = frame.descriptors.shape.map { $0.intValue }
        guard shape.count == 2, shape[1] == 256 else {
            throw DumperError.descriptorShapeMismatch(actual: shape)
        }
        guard frame.descriptors.dataType == .float16 else {
            throw DumperError.descriptorDataTypeMismatch(actual: frame.descriptors.dataType)
        }

        // 2. keypoints 비어있으면 거부 (디버그 의미 없음)
        guard !frame.keypoints.isEmpty else {
            throw DumperError.emptyKeypoints
        }

        let n = shape[0]
        // 빈 keypoints 와 빈 descriptor row 의 정합성
        // (실측에서 N == frame.keypoints.count 가 보장되지만 방어적으로 작은 쪽 사용)
        let validN = min(n, frame.keypoints.count)
        guard validN > 0 else {
            throw DumperError.emptyKeypoints
        }

        // 3. descriptor → FP16 raw bytes (NSNumber subscript 우회 — Float64 양자화 방지)
        let descriptorsB64: String
        do {
            // 빈 array 의 dataPointer 는 nil 일 수 있어 명시 분기
            if validN == 0 {
                descriptorsB64 = ""
            } else {
                let fp16Ptr = frame.descriptors.dataPointer.bindMemory(
                    to: Float16.self,
                    capacity: validN * 256
                )
                let byteCount = validN * 256 * MemoryLayout<Float16>.size
                let data = Data(bytes: fp16Ptr, count: byteCount)
                descriptorsB64 = data.base64EncodedString()
            }
        }

        // 4. keypoints (u, v, score) → [[u, v]]
        let keypoints2D: [[Float]] = frame.keypoints.prefix(validN).map { kp in
            [kp.x, kp.y]
        }

        // 5. intrinsics (simd_float3x3, column-major) → DumpIntrinsics
        let m = frame.intrinsics
        let intrinsics = DumpIntrinsics(
            fx: m[0][0],
            fy: m[1][1],
            cx: m[2][0],
            cy: m[2][1],
            width: Int(frame.inputSize.width),
            height: Int(frame.inputSize.height)
        )

        // 6. ar_pose (simd_float4x4) → row-major [[Float]] 4×4
        let arPose4x4: [[Float]]? = arPose.map { p in
            // simd_float4x4 는 column-major 저장. row r, col c = p.columns.c[r]
            (0..<4).map { r in
                [p.columns.0[r], p.columns.1[r], p.columns.2[r], p.columns.3[r]]
            }
        }

        // 7. ISO8601 timestamp
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let capturedAt = isoFormatter.string(from: date)

        let dump = ClientFrameDump(
            kind: "client_dump",
            capturedAt: capturedAt,
            intrinsics: intrinsics,
            arPose4x4: arPose4x4,
            deviceOrientation: orientation,
            keypoints: keypoints2D,
            descriptorsB64: descriptorsB64
        )

        // 8. JSON 인코딩 (prettyPrinted X — base64 한 줄로 길어지므로)
        let encoder = JSONEncoder()
        return try encoder.encode(dump)
    }
}
#endif
