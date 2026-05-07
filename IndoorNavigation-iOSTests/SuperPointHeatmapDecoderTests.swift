import Testing
import CoreML
import simd
import Foundation
@testable import IndoorNavigation_iOS

/// SuperPointHeatmapDecoder 의 NMS·top-K·threshold·좌표 매핑 단위 테스트.
struct SuperPointHeatmapDecoderTests {

    // MARK: - Helpers

    /// shape (1, 65, gridH, gridW) 의 .float16 MLMultiArray 를 0-fill 로 생성.
    /// strides 는 row-major 자동 계산.
    private func makeSemi(gridH: Int, gridW: Int) -> MLMultiArray {
        let arr = try! MLMultiArray(
            shape: [1, 65, NSNumber(value: gridH), NSNumber(value: gridW)],
            dataType: .float16
        )
        // 모든 채널을 1로 채워서 softmax 후 균등 분포 ≈ 1/65 ≈ 0.01538 가 되도록.
        // 이후 특정 셀의 특정 채널만 큰 값으로 덮어 쓴다.
        // 0-fill 로 초기화 후, 필요한 곳만 logit 을 부여하는 전략은 dustbin 만 1.0 으로 해 두면
        // softmax 결과에서 비-dustbin 채널 ≈ 1/(64+e^1) 매우 작아 불필요한 응답을 억제할 수 있다.
        // 본 테스트에서는 단순화: 모든 셀의 모든 채널 0 (uniform softmax = 1/65) → score ≈ 0.01538.
        // threshold 0.005 보다 크므로 모든 픽셀이 잠재 후보가 될 수 있어 NMS 만으로 분리됨.
        // 특정 픽셀을 강하게 만들기 위해 해당 채널 logit 을 large value 로 덮어 쓴다.
        return arr
    }

    /// (1, 65, gridH, gridW) row-major flat 인덱스 = c * (gridH*gridW) + gy * gridW + gx.
    private func flatIndex(c: Int, gy: Int, gx: Int, gridH: Int, gridW: Int) -> Int {
        return c * (gridH * gridW) + gy * gridW + gx
    }

    /// Float → Float16 으로 양자화 후 NSNumber.
    private func f16(_ v: Float) -> NSNumber {
        return NSNumber(value: Float(Float16(v)))
    }

    // MARK: - 1) NMS — 인접한 두 강한 응답 → 1개만 남음

    @Test("NMS 반경 4px 내에 두 강한 응답이 있으면 1개만 후보로 남는다")
    func nmsSuppressesAdjacent() {
        let gridH = 80, gridW = 60
        let semi = makeSemi(gridH: gridH, gridW: gridW)

        // 두 응답을 (gy=10, gx=20) 셀 내에서 만들기.
        // 각각 채널 c0, c1 을 선택해 같은 셀에 강한 logit 을 부여.
        // depth-to-space: c0 = 0 → (dy=0, dx=0) → (y=80, x=160)
        //                c1 = 1 → (dy=0, dx=1) → (y=80, x=161) — 1px 인접
        let gy = 10, gx = 20
        let big: Float = 20.0   // softmax 후 ≈ 1.0
        semi[flatIndex(c: 0, gy: gy, gx: gx, gridH: gridH, gridW: gridW)] = f16(big)
        semi[flatIndex(c: 1, gy: gy, gx: gx, gridH: gridH, gridW: gridW)] = f16(big - 0.1)
        // NB: 같은 셀 내에서는 softmax 가 두 채널을 normalize 하므로 두 위치 모두 큰 score 를 가짐.
        // NMS 반경 4 에서는 (160, 80) 과 (161, 80) 이 1px 차이 → 작은 쪽이 억제되고 1개만 남아야 한다.

        let decoder = SuperPointHeatmapDecoder(config: .init(
            inputWidth: gridW * 8, inputHeight: gridH * 8,
            cellSize: 8, dustbinChannelIndex: 64,
            scoreThreshold: 0.3, nmsRadiusPx: 4, maxKeypoints: 512
        ))

        let kps = decoder.decode(semi: semi)
        // (160, 80) 근처 4px 반경에 후보는 정확히 1개만 남는다.
        let nearby = kps.filter { abs($0.x - 160) <= 4 && abs($0.y - 80) <= 4 }
        #expect(nearby.count == 1)
    }

    // MARK: - 2) top-K — 1000개 응답 → 정확히 512개

    @Test("threshold 통과 후보가 maxKeypoints(512)보다 많으면 정확히 512개로 자른다")
    func topKLimit() {
        // gridH * gridW = 80 * 60 = 4800 셀. 각 셀에서 1개 강한 channel logit → 4800개 후보.
        // 셀 간 거리는 8px 이상이므로 NMS 4px 에 의해 서로 억제되지 않음.
        let gridH = 80, gridW = 60
        let semi = makeSemi(gridH: gridH, gridW: gridW)

        // 각 셀의 channel 0 에 강한 logit → cell 당 (y=gy*8, x=gx*8) 에 응답.
        // softmax 후 매우 크므로 threshold 0.3 통과.
        for gy in 0..<gridH {
            for gx in 0..<gridW {
                semi[flatIndex(c: 0, gy: gy, gx: gx, gridH: gridH, gridW: gridW)] = f16(20.0)
            }
        }

        let decoder = SuperPointHeatmapDecoder(config: .init(
            inputWidth: gridW * 8, inputHeight: gridH * 8,
            cellSize: 8, dustbinChannelIndex: 64,
            scoreThreshold: 0.3, nmsRadiusPx: 4, maxKeypoints: 512
        ))

        let kps = decoder.decode(semi: semi)
        #expect(kps.count == 512)
    }

    // MARK: - 3) score threshold — 모든 score < threshold → 0개

    @Test("모든 채널의 score 가 threshold 미만이면 후보 0개")
    func scoreThresholdFilter() {
        let gridH = 80, gridW = 60
        // 0-fill semi → softmax 모든 채널 1/65 ≈ 0.01538.
        let semi = makeSemi(gridH: gridH, gridW: gridW)

        // dustbin (channel 64) 만 강하게 두면 비-dustbin 채널 score ≪ 0.005.
        // 모든 셀에 동일하게 dustbin logit 을 크게 부여.
        for gy in 0..<gridH {
            for gx in 0..<gridW {
                semi[flatIndex(c: 64, gy: gy, gx: gx, gridH: gridH, gridW: gridW)] = f16(20.0)
            }
        }

        let decoder = SuperPointHeatmapDecoder(config: .init(
            inputWidth: gridW * 8, inputHeight: gridH * 8,
            cellSize: 8, dustbinChannelIndex: 64,
            scoreThreshold: 0.005, nmsRadiusPx: 4, maxKeypoints: 512
        ))

        let kps = decoder.decode(semi: semi)
        #expect(kps.isEmpty)
    }

    // MARK: - 4) 좌표 매핑 — (channel=c, gy, gx) 응답 → (gx*8 + c%8, gy*8 + c/8)

    @Test("depth-to-space 좌표 매핑: 채널 c 의 응답은 (gx*8 + c%8, gy*8 + c/8) 픽셀에 위치")
    func coordinatesAreInInputSpace() {
        let gridH = 80, gridW = 60
        let semi = makeSemi(gridH: gridH, gridW: gridW)

        // 한 셀(gy=5, gx=7) 에 c=11 (dy = 11/8 = 1, dx = 11%8 = 3) 강한 logit
        // 기대 좌표: u = 7*8 + 3 = 59, v = 5*8 + 1 = 41
        let gy = 5, gx = 7, c = 11
        semi[flatIndex(c: c, gy: gy, gx: gx, gridH: gridH, gridW: gridW)] = f16(20.0)

        let decoder = SuperPointHeatmapDecoder(config: .init(
            inputWidth: gridW * 8, inputHeight: gridH * 8,
            cellSize: 8, dustbinChannelIndex: 64,
            scoreThreshold: 0.3, nmsRadiusPx: 4, maxKeypoints: 512
        ))

        let kps = decoder.decode(semi: semi)
        #expect(kps.count == 1)
        if let kp = kps.first {
            #expect(abs(kp.x - 59) <= 1)
            #expect(abs(kp.y - 41) <= 1)
        }
    }
}
