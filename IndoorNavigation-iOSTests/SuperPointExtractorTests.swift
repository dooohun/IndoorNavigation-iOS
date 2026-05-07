import Testing
import CoreML
import simd
import Foundation
@testable import IndoorNavigation_iOS

/// SuperPoint extractor 의 descriptor 규약(차원/dtype/L2 norm) 단위 테스트.
///
/// ML 모델 로드 (SuperPointExtractorML) 는 시뮬레이터에서 가용하지 않을 수 있으므로
/// stub 추출기를 통해 descriptor 출력 규약만 검증한다. 규약은 Phase 8/9/10 공통이며
/// stub·ML 양쪽 동일하게 만족해야 한다.
struct SuperPointExtractorTests {

    private func makeBlankPixelBuffer(width: Int = 480, height: Int = 640) -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        var buf: CVPixelBuffer?
        _ = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_OneComponent8,
                                attrs as CFDictionary, &buf)
        return buf!
    }

    // MARK: - 1) descriptor shape

    @Test("descriptor MLMultiArray shape == [N, 256]")
    func descriptorShape() {
        let stub = SuperPointExtractorStub()
        let frame = stub.extract(
            image: makeBlankPixelBuffer(),
            intrinsics: matrix_identity_float3x3,
            timestamp: 1.234
        )
        let n = frame.keypoints.count
        let shape = frame.descriptors.shape.map { $0.intValue }
        #expect(shape.count == 2)
        #expect(shape[0] == n)
        #expect(shape[1] == 256)
    }

    // MARK: - 2) descriptor dtype == float16

    @Test("descriptor dataType == .float16")
    func descriptorDataType() {
        let stub = SuperPointExtractorStub()
        let frame = stub.extract(
            image: makeBlankPixelBuffer(),
            intrinsics: matrix_identity_float3x3,
            timestamp: 1.0
        )
        #expect(frame.descriptors.dataType == .float16)
    }

    // MARK: - 3) descriptor L2 norm 각 row ∈ [0.997, 1.003]

    @Test("각 descriptor row 의 L2 norm 은 1.0 근처(±0.003)")
    func descriptorL2Norm() {
        let stub = SuperPointExtractorStub()
        let frame = stub.extract(
            image: makeBlankPixelBuffer(),
            intrinsics: matrix_identity_float3x3,
            timestamp: 2.0
        )
        let n = frame.keypoints.count
        #expect(n > 0)

        let dim = 256
        for i in 0..<n {
            var sumSq: Float = 0
            for j in 0..<dim {
                let v = frame.descriptors[i * dim + j].floatValue
                sumSq += v * v
            }
            let norm = sqrtf(sumSq)
            #expect(norm >= 0.997 && norm <= 1.003,
                    "row \(i) norm \(norm) outside [0.997, 1.003]")
        }
    }

    // MARK: - 4) 모든 0 입력에서 크래시 없음

    @Test("zero-fill 입력에서도 extract 가 크래시 없이 SuperPointFrame 반환")
    func emptyInputSafe() {
        let stub = SuperPointExtractorStub()
        let buf = makeBlankPixelBuffer()
        let frame = stub.extract(
            image: buf,
            intrinsics: matrix_identity_float3x3,
            timestamp: 0.0
        )
        // 단순 호출 성공 + 기본 invariants
        #expect(frame.keypoints.count <= 512)
        #expect(frame.descriptors.shape.count == 2)
    }
}
