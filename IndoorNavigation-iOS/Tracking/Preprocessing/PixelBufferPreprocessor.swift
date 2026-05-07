import Foundation
import CoreVideo
import Accelerate

/// ARFrame `capturedImage` (YUV biplanar 420f) 를 SuperPoint 추론 입력 그레이스케일
/// 640×480 OneComponent8 CVPixelBuffer 로 변환한다.
///
/// 입력 사이즈는 ARFrame raw 비율(4:3 가로)과 일치하도록 640×480(4:3) 으로 정의 — 비례
/// 보존 + 정보 손실 0 + SuperPoint 학습 분포(가로) 와 일치. src·dst 비율이 다르면
/// src 에서 dst 비율과 일치하는 가운데 영역만 center crop 후 다운스케일 (현재는 둘 다
/// 4:3 이라 crop 0).
///
/// 회전 보정은 본 PR 범위 외. 서버 매핑 orientation 합의 후 후속 PR 에서 결정.
/// 풀 사전 alloc 으로 매 프레임 buffer 생성 비용을 줄인다.
final class PixelBufferPreprocessor {

    static let outputWidth: Int = 960
    static let outputHeight: Int = 540

    private var pool: CVPixelBufferPool?

    init() {
        self.pool = Self.makePool(width: Self.outputWidth, height: Self.outputHeight)
    }

    /// YUV biplanar Y plane → `outputWidth × outputHeight` OneComponent8 CVPixelBuffer.
    /// 실패 시 nil 반환. 호출자는 nil 시 추론을 skip 해야 한다.
    func toGrayscaleBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
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

        // src 에서 dst 비율과 일치하는 영역만 center crop. 비례 보존 → SuperPoint
        // detector/descriptor 가 학습 분포(정상 비율) 와 일관되게 응답하도록 함.
        let dstAspect = Double(Self.outputWidth) / Double(Self.outputHeight)   // 0.75 (3:4)
        let srcAspect = Double(srcWidth) / Double(srcHeight)                   // 예: 1.333 (4:3)
        let roiX: Int
        let roiY: Int
        let roiW: Int
        let roiH: Int
        if srcAspect > dstAspect {
            // src 가 가로로 더 김 → 좌우 자르기
            roiH = srcHeight
            roiW = Int((Double(srcHeight) * dstAspect).rounded())
            roiX = (srcWidth - roiW) / 2
            roiY = 0
        } else {
            // src 가 세로로 더 김 → 위/아래 자르기
            roiW = srcWidth
            roiH = Int((Double(srcWidth) / dstAspect).rounded())
            roiX = 0
            roiY = (srcHeight - roiH) / 2
        }
        // ROI 시작 주소 (Planar8: 1 byte/pixel)
        let roiAddr = srcAddr.advanced(by: roiY * srcBytesPerRow + roiX)

        var srcVImage = vImage_Buffer(
            data: roiAddr,
            height: vImagePixelCount(roiH),
            width: vImagePixelCount(roiW),
            rowBytes: srcBytesPerRow            // ROI 는 src 의 부분뷰이므로 rowBytes 그대로
        )
        var dstVImage = vImage_Buffer(
            data: dstAddr,
            height: vImagePixelCount(Self.outputHeight),
            width: vImagePixelCount(Self.outputWidth),
            rowBytes: dstBytesPerRow
        )

        // ROI → dst 비율 유지 다운스케일.
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
