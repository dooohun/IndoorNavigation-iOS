import Foundation
import CoreVideo
import Accelerate

/// SuperPoint 입력 orientation. ARFrame raw 는 항상 landscape (1920×1440 가로) 로 오지만
/// 사용자가 디바이스를 어떻게 들고 있느냐에 따라 raw 가 사용자 시점 기준 정상(upright)
/// 인지, 90° 누워 있는지가 다르다. 서버 매핑이 upright(가로) 방향으로 indexing 되었으므로
/// 사용자 시점 정상이 되도록 회전 보정을 선택한다.
enum InputOrientation {
    /// raw landscape 그대로 (사용자가 디바이스를 가로로 들고 카메라가 정면을 향할 때
    /// 자연스러운 매칭).
    case landscape
    /// 90° CW 회전 후 가로 띠 center crop. 사용자가 디바이스를 portrait 로 들고 있을 때
    /// SuperPoint 가 upright 영상을 보도록 함. 사용자 시점 위/아래는 잘림.
    case portrait
}

/// ARFrame `capturedImage` (YUV biplanar 420f) 를 SuperPoint 추론 입력 그레이스케일
/// `outputWidth × outputHeight` (현재 960×540) OneComponent8 CVPixelBuffer 로 변환한다.
///
/// orientation 에 따라:
/// - `.landscape`: src 에서 dst 비율(16:9) 일치 영역만 center crop 후 다운스케일.
///   raw 1920×1440(4:3) → 1920×1080 crop → 960×540.
/// - `.portrait`: Y plane 추출 + 90° CW 회전(1440×1920) → 가운데 가로 띠 center crop
///   (1440×810, 16:9) → 960×540 다운스케일. rotated intermediate 풀 별도 사전 alloc.
final class PixelBufferPreprocessor {

    static let outputWidth: Int = 960
    static let outputHeight: Int = 540
    /// portrait 회전 intermediate 사이즈 — ARFrame raw 1920×1440 의 90° CW 회전 결과.
    private static let rotatedWidth: Int = 1440
    private static let rotatedHeight: Int = 1920

    private var outputPool: CVPixelBufferPool?
    private var rotatedPool: CVPixelBufferPool?

    init() {
        self.outputPool = Self.makePool(width: Self.outputWidth, height: Self.outputHeight)
        self.rotatedPool = Self.makePool(width: Self.rotatedWidth, height: Self.rotatedHeight)
    }

    /// orientation 에 따라 회전 + center crop + 다운스케일. 실패 시 nil.
    func toGrayscaleBuffer(_ source: CVPixelBuffer, orientation: InputOrientation = .landscape) -> CVPixelBuffer? {
        let formatType = CVPixelBufferGetPixelFormatType(source)
        guard formatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              formatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
              formatType == kCVPixelFormatType_OneComponent8 else {
            return nil
        }

        switch orientation {
        case .landscape:
            return processLandscape(source, formatType: formatType)
        case .portrait:
            return processPortrait(source, formatType: formatType)
        }
    }

    // MARK: - Landscape: src Y plane → center crop + scale

    private func processLandscape(_ source: CVPixelBuffer, formatType: OSType) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let plane = lockPlaneInfo(source, formatType: formatType) else { return nil }
        return cropAndScaleToOutput(
            srcAddr: plane.addr,
            srcWidth: plane.width,
            srcHeight: plane.height,
            srcBytesPerRow: plane.bytesPerRow
        )
    }

    // MARK: - Portrait: src Y plane → 90° CW 회전 → center crop + scale

    private func processPortrait(_ source: CVPixelBuffer, formatType: OSType) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let plane = lockPlaneInfo(source, formatType: formatType) else { return nil }

        // rotated intermediate buffer 획득 (풀 또는 fallback alloc)
        var rotatedBuf: CVPixelBuffer?
        if let pool = rotatedPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &rotatedBuf)
        }
        if rotatedBuf == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Self.rotatedWidth, Self.rotatedHeight,
                kCVPixelFormatType_OneComponent8,
                Self.attrs(width: Self.rotatedWidth, height: Self.rotatedHeight) as CFDictionary,
                &rotatedBuf
            )
        }
        guard let rb = rotatedBuf else {
            return nil
        }

        CVPixelBufferLockBaseAddress(rb, [])
        guard let rbAddr = CVPixelBufferGetBaseAddress(rb) else {
            CVPixelBufferUnlockBaseAddress(rb, [])
            return nil
        }
        let rbBytesPerRow = CVPixelBufferGetBytesPerRow(rb)

        var srcVImg = vImage_Buffer(
            data: plane.addr,
            height: vImagePixelCount(plane.height),
            width: vImagePixelCount(plane.width),
            rowBytes: plane.bytesPerRow
        )
        var rotVImg = vImage_Buffer(
            data: rbAddr,
            height: vImagePixelCount(Self.rotatedHeight),
            width: vImagePixelCount(Self.rotatedWidth),
            rowBytes: rbBytesPerRow
        )
        // rotationConstant: 0=0°, 1=90° CCW, 2=180°, 3=90° CW (= 270° CCW)
        let rotErr = vImageRotate90_Planar8(&srcVImg, &rotVImg, 3, 0, vImage_Flags(kvImageNoFlags))
        if rotErr != kvImageNoError {
            CVPixelBufferUnlockBaseAddress(rb, [])
            return nil
        }

        let result = cropAndScaleToOutput(
            srcAddr: rbAddr,
            srcWidth: Self.rotatedWidth,
            srcHeight: Self.rotatedHeight,
            srcBytesPerRow: rbBytesPerRow
        )
        CVPixelBufferUnlockBaseAddress(rb, [])
        return result
    }

    // MARK: - 공통 — 16:9 center crop + 다운스케일

    private func cropAndScaleToOutput(
        srcAddr: UnsafeMutableRawPointer,
        srcWidth: Int,
        srcHeight: Int,
        srcBytesPerRow: Int
    ) -> CVPixelBuffer? {
        // 출력 buffer 풀에서 획득 (또는 fallback alloc)
        var outBuffer: CVPixelBuffer?
        if let pool = outputPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
        }
        if outBuffer == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Self.outputWidth, Self.outputHeight,
                kCVPixelFormatType_OneComponent8,
                Self.attrs() as CFDictionary,
                &outBuffer
            )
        }
        guard let dstBuffer = outBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(dstBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(dstBuffer, []) }

        guard let dstAddr = CVPixelBufferGetBaseAddress(dstBuffer) else { return nil }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dstBuffer)

        // dst 비율과 일치하는 ROI 계산 (비례 보존).
        let dstAspect = Double(Self.outputWidth) / Double(Self.outputHeight)   // 16:9 = 1.778
        let srcAspect = Double(srcWidth) / Double(srcHeight)
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

        let err = vImageScale_Planar8(&srcVImage, &dstVImage, nil, vImage_Flags(kvImageNoFlags))
        if err != kvImageNoError {
            return nil
        }
        return dstBuffer
    }

    // MARK: - Y plane 정보 추출 (포맷별 분기)

    private struct PlaneInfo {
        let addr: UnsafeMutableRawPointer
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    private func lockPlaneInfo(_ source: CVPixelBuffer, formatType: OSType) -> PlaneInfo? {
        let isPlanar = formatType != kCVPixelFormatType_OneComponent8
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let addr: UnsafeMutableRawPointer
        if isPlanar {
            width = CVPixelBufferGetWidthOfPlane(source, 0)
            height = CVPixelBufferGetHeightOfPlane(source, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
            guard let a = CVPixelBufferGetBaseAddressOfPlane(source, 0) else { return nil }
            addr = a
        } else {
            width = CVPixelBufferGetWidth(source)
            height = CVPixelBufferGetHeight(source)
            bytesPerRow = CVPixelBufferGetBytesPerRow(source)
            guard let a = CVPixelBufferGetBaseAddress(source) else { return nil }
            addr = a
        }
        return PlaneInfo(addr: addr, width: width, height: height, bytesPerRow: bytesPerRow)
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
