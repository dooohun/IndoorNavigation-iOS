import Foundation
import CoreVideo
import Accelerate

/// ARFrame `capturedImage` (YUV biplanar 420f) 를 SuperPoint 추론 입력 그레이스케일
/// 480×640 OneComponent8 CVPixelBuffer 로 변환한다.
///
/// Phase 7-1 V-1 범위: 단순 stretch 리사이즈만 수행. 비율 보정·디바이스 회전 보정은
/// 본 PR 제외 (V-1 결과 보고 후속 결정 — Phase 7 범위 제외 항목).
///
/// 풀 사전 alloc 으로 매 프레임 buffer 생성 비용을 줄인다.
final class PixelBufferPreprocessor {

    static let outputWidth: Int = 480
    static let outputHeight: Int = 640

    private var pool: CVPixelBufferPool?

    init() {
        self.pool = Self.makePool(width: Self.outputWidth, height: Self.outputHeight)
    }

    /// YUV biplanar Y plane → 480×640 OneComponent8 CVPixelBuffer.
    /// 실패 시 nil 반환. 호출자는 nil 시 추론을 skip 해야 한다.
    func toGrayscale480x640(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let formatType = CVPixelBufferGetPixelFormatType(source)
        // ARKit capturedImage 는 일반적으로 420YpCbCr8BiPlanarFullRange (875704422).
        // FullRange / VideoRange 모두 Y plane 자체는 OneComponent8 로 동일하게 사용 가능.
        guard formatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              formatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
              formatType == kCVPixelFormatType_OneComponent8 else {
            print("[Preprocess] unsupported pixel format: \(formatType)")
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        let srcPlaneIndex = (formatType == kCVPixelFormatType_OneComponent8) ? 0 : 0
        let isPlanar = formatType != kCVPixelFormatType_OneComponent8
        let srcWidth: Int
        let srcHeight: Int
        let srcBytesPerRow: Int
        let srcBaseAddr: UnsafeMutableRawPointer?
        if isPlanar {
            srcWidth = CVPixelBufferGetWidthOfPlane(source, srcPlaneIndex)
            srcHeight = CVPixelBufferGetHeightOfPlane(source, srcPlaneIndex)
            srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, srcPlaneIndex)
            srcBaseAddr = CVPixelBufferGetBaseAddressOfPlane(source, srcPlaneIndex)
        } else {
            srcWidth = CVPixelBufferGetWidth(source)
            srcHeight = CVPixelBufferGetHeight(source)
            srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            srcBaseAddr = CVPixelBufferGetBaseAddress(source)
        }
        guard let srcAddr = srcBaseAddr else { return nil }

        // 출력 buffer 풀에서 획득
        var outBuffer: CVPixelBuffer?
        let status: CVReturn
        if let pool = pool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
        } else {
            status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                Self.outputWidth, Self.outputHeight,
                kCVPixelFormatType_OneComponent8,
                Self.attrs() as CFDictionary,
                &outBuffer
            )
        }
        guard status == kCVReturnSuccess, let dstBuffer = outBuffer else {
            print("[Preprocess] failed to allocate output buffer (status=\(status))")
            return nil
        }

        CVPixelBufferLockBaseAddress(dstBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(dstBuffer, []) }

        guard let dstAddr = CVPixelBufferGetBaseAddress(dstBuffer) else { return nil }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dstBuffer)

        var srcVImage = vImage_Buffer(
            data: srcAddr,
            height: vImagePixelCount(srcHeight),
            width: vImagePixelCount(srcWidth),
            rowBytes: srcBytesPerRow
        )
        var dstVImage = vImage_Buffer(
            data: dstAddr,
            height: vImagePixelCount(Self.outputHeight),
            width: vImagePixelCount(Self.outputWidth),
            rowBytes: dstBytesPerRow
        )

        // 단순 stretch 스케일 (Lanczos 등 high-q 옵션은 Phase 7 범위 외).
        let err = vImageScale_Planar8(&srcVImage, &dstVImage, nil, vImage_Flags(kvImageNoFlags))
        if err != kvImageNoError {
            print("[Preprocess] vImageScale_Planar8 failed (err=\(err))")
            return nil
        }

        return dstBuffer
    }

    // MARK: - Pool 사전 alloc

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let pixelBufferAttrs = attrs(width: width, height: height)
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            pixelBufferAttrs as CFDictionary,
            &pool
        )
        if status != kCVReturnSuccess {
            print("[Preprocess] CVPixelBufferPoolCreate failed (status=\(status))")
            return nil
        }
        return pool
    }

    private static func attrs(width: Int = outputWidth, height: Int = outputHeight) -> [CFString: Any] {
        return [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
    }
}
