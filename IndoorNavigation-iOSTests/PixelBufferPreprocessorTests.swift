import Testing
import CoreVideo
import Foundation
@testable import IndoorNavigation_iOS

/// PixelBufferPreprocessor 의 출력 dimension/format 및 그라데이션 fidelity 단위 테스트.
struct PixelBufferPreprocessorTests {

    // MARK: - Helpers

    /// YUV biplanar (420f) 1920×1440 CVPixelBuffer 생성. Y plane 만 입력 그라데이션으로 채움.
    /// CbCr plane 은 회색(128) 으로 채움 — 본 변환은 Y plane 만 사용하므로 결과에 영향 없음.
    private func makeYUV1920x1440() -> CVPixelBuffer {
        let width = 1920, height = 1440
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        var buf: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attrs as CFDictionary,
            &buf
        )
        precondition(status == kCVReturnSuccess && buf != nil, "alloc YUV failed")
        let pb = buf!

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        // Y plane (plane 0) → 가로 그라데이션 (x=0 → 0, x=W-1 → 255)
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let yRows = CVPixelBufferGetHeightOfPlane(pb, 0)
            let yCols = CVPixelBufferGetWidthOfPlane(pb, 0)
            let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
            for y in 0..<yRows {
                for x in 0..<yCols {
                    let v = UInt8((Double(x) / Double(max(yCols - 1, 1))) * 255.0)
                    yPtr[y * yBpr + x] = v
                }
            }
        }

        // CbCr plane (plane 1) → 회색 (128)
        if let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let cRows = CVPixelBufferGetHeightOfPlane(pb, 1)
            let cBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            memset(cBase, 128, cRows * cBpr)
        }

        return pb
    }

    // MARK: - 1) 출력 dimension·format 검증

    @Test("1920×1440 YUV 입력 → outputWidth×outputHeight OneComponent8 출력")
    func dimensionsAndFormat() {
        let preproc = PixelBufferPreprocessor()
        let src = makeYUV1920x1440()

        guard let dst = preproc.toGrayscaleBuffer(src) else {
            Issue.record("toGrayscaleBuffer returned nil")
            return
        }
        #expect(CVPixelBufferGetWidth(dst) == PixelBufferPreprocessor.outputWidth)
        #expect(CVPixelBufferGetHeight(dst) == PixelBufferPreprocessor.outputHeight)
        #expect(CVPixelBufferGetPixelFormatType(dst) == kCVPixelFormatType_OneComponent8)
    }

    // MARK: - 2) 그라데이션 fidelity (가운데 픽셀 값 ±5)

    @Test("가로 그라데이션 입력의 가운데 픽셀은 출력에서도 ≈128 (±5)")
    func scaleFidelity() {
        let preproc = PixelBufferPreprocessor()
        let src = makeYUV1920x1440()

        guard let dst = preproc.toGrayscaleBuffer(src) else {
            Issue.record("toGrayscaleBuffer returned nil")
            return
        }
        CVPixelBufferLockBaseAddress(dst, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dst, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(dst) else {
            Issue.record("nil base address")
            return
        }
        let bpr = CVPixelBufferGetBytesPerRow(dst)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // 출력 가운데 픽셀
        let cx = PixelBufferPreprocessor.outputWidth / 2
        let cy = PixelBufferPreprocessor.outputHeight / 2
        let v = ptr[cy * bpr + cx]
        // 입력 가로 그라데이션 가운데 ≈ 127~128, 비율 유지 다운스케일로 ±5 내 통과 기대.
        #expect(abs(Int(v) - 128) <= 5,
                "expected ≈128, got \(v)")
    }
}
