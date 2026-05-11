import UIKit
import SceneKit

// MARK: - 마커 시각 구성 팩토리
// 사양 §1, §5, §7 (AR_MARKER_3D.md). 다이아몬드(흰 외곽 + 파란 inner) + 셰브론 + 텍스트 텍스처 빌더.
// SceneKit 매핑: SCNShape(UIBezierPath, extrusionDepth) + PBR (.physicallyBased) clearcoat.

enum MarkerGeometryFactory {

    // MARK: - 텍스처 캐시 (메인 스레드 블로킹 완화: 거리 텍스처는 정수 단위라 ~50개로 한정)

    private static var distanceTextureCache: [Int: CGImage] = [:]
    private static var cachedNextTexture: CGImage?
    private static let textureCacheLock = NSLock()

    // MARK: - 다이아몬드 본체

    /// 외곽선(흰) + inner(브랜드 블루) 다이아몬드 본체.
    /// size 는 마커 변 길이(m). 비율 100:8:5 (본체:외곽:두께) 그대로 적용.
    /// path 자체는 axis-aligned 라운드 사각형 → 45° z 회전을 geometry 에 베이크.
    static func makeDiamondBody(size: CGFloat) -> SCNNode {
        let depth: CGFloat = size * 0.05
        let borderFrac: CGFloat = 0.08
        let innerSize: CGFloat = size * (1.0 - borderFrac)
        let innerDepth: CGFloat = depth * 1.08  // inner 가 outer 보다 약간 앞으로

        let group = SCNNode()
        group.name = "diamondBody"

        // 외곽 (흰)
        let outerShape = roundedSquarePath(size: size, radiusFrac: 0.12)
        let outerGeo = SCNShape(path: outerShape, extrusionDepth: depth)
        outerGeo.chamferRadius = 0  // bezier 자체에 라운드 적용
        let outerMat = SCNMaterial()
        outerMat.lightingModel = .physicallyBased
        outerMat.diffuse.contents = UIColor.white
        outerMat.roughness.contents = 0.40
        outerMat.metalness.contents = 0.0
        outerMat.clearCoat.contents = 0.55
        outerMat.clearCoatRoughness.contents = 0.22
        outerMat.isDoubleSided = true
        outerGeo.materials = [outerMat]
        let outerNode = SCNNode(geometry: outerGeo)
        // 45° z 회전 (다이아몬드)
        outerNode.eulerAngles = SCNVector3(0, 0, Float.pi / 4)
        // extrusion 은 +z 방향으로 진행 — geometry 중심을 0 으로 맞추려면 -depth/2 평행이동
        outerNode.position = SCNVector3(0, 0, Float(-depth / 2))
        group.addChildNode(outerNode)

        // inner (브랜드 블루 #1DA1F2)
        let innerShape = roundedSquarePath(size: innerSize, radiusFrac: 0.12)
        let innerGeo = SCNShape(path: innerShape, extrusionDepth: innerDepth)
        innerGeo.chamferRadius = 0
        let innerMat = SCNMaterial()
        innerMat.lightingModel = .physicallyBased
        innerMat.diffuse.contents = UIColor(red: 0x1D/255.0, green: 0xA1/255.0, blue: 0xF2/255.0, alpha: 1.0)
        innerMat.roughness.contents = 0.34
        innerMat.metalness.contents = 0.0
        innerMat.clearCoat.contents = 0.85
        innerMat.clearCoatRoughness.contents = 0.16
        innerMat.isDoubleSided = true
        innerGeo.materials = [innerMat]
        let innerNode = SCNNode(geometry: innerGeo)
        innerNode.eulerAngles = SCNVector3(0, 0, Float.pi / 4)
        // 살짝 앞으로(시청자쪽 = +z) 돌출
        innerNode.position = SCNVector3(0, 0, Float(-innerDepth / 2 + depth * 0.04))
        group.addChildNode(innerNode)

        return group
    }

    /// 라운드 사각형 UIBezierPath (-half..half 영역). radiusFrac 은 size 대비 corner radius 비율.
    private static func roundedSquarePath(size: CGFloat, radiusFrac: CGFloat) -> UIBezierPath {
        let half = size / 2.0
        let r = size * radiusFrac
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -half + r, y: -half))
        path.addLine(to: CGPoint(x: half - r, y: -half))
        path.addQuadCurve(to: CGPoint(x: half, y: -half + r), controlPoint: CGPoint(x: half, y: -half))
        path.addLine(to: CGPoint(x: half, y: half - r))
        path.addQuadCurve(to: CGPoint(x: half - r, y: half), controlPoint: CGPoint(x: half, y: half))
        path.addLine(to: CGPoint(x: -half + r, y: half))
        path.addQuadCurve(to: CGPoint(x: -half, y: half - r), controlPoint: CGPoint(x: -half, y: half))
        path.addLine(to: CGPoint(x: -half, y: -half + r))
        path.addQuadCurve(to: CGPoint(x: -half + r, y: -half), controlPoint: CGPoint(x: -half, y: -half))
        path.close()
        return path
    }

    // MARK: - 셰브론 (> 형태)

    /// 굵은 ">" 외곽선. local 좌표는 ~[-0.50, 0.40] × [-0.55, 0.55].
    /// caller 가 scale 로 실제 크기 결정. 좌회전은 eulerAngles.y = π (Y축 180° 회전) 로 거울 대칭
    /// — scale.x 음수는 face winding 뒤집기 + extrusion 방향 반전으로 카메라 후면이 되어 안 보임 → Y 회전으로 안전 처리.
    ///
    /// path 디자인: 6점 시계반대 폐곡선. self-intersection 없음 → SCNShape triangulator 안정 처리.
    /// 외곽 V 와 안쪽 V 사이 두께 ~0.3 으로 chevScale = 0.78 × baseSize 1.2m 적용 시 실측 ≈ 0.84m × 1.03m
    /// — 사용자 시인성 충분.
    /// (기존 path 는 ~0.04 의 거의 0 거리 quadCurve + self-intersection 으로 mesh 생성 실패 → 빈 mesh 이슈)
    static func makeChevron() -> SCNNode {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -0.50, y: 0.55))
        path.addLine(to: CGPoint(x: 0.10, y: 0.0))
        path.addLine(to: CGPoint(x: -0.50, y: -0.55))
        path.addLine(to: CGPoint(x: -0.20, y: -0.55))
        path.addLine(to: CGPoint(x: 0.40, y: 0.0))
        path.addLine(to: CGPoint(x: -0.20, y: 0.55))
        path.close()

        let geo = SCNShape(path: path, extrusionDepth: 0.14)
        let mat = SCNMaterial()
        // 라이팅 제거 (constant) — physicallyBased + 작은 두께라 측면 음영으로 사라지는 현상 방지
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.white
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        mat.transparency = 1.0  // blink keyframe 으로 제어
        geo.materials = [mat]

        let node = SCNNode(geometry: geo)
        node.name = "chevron"
        // UI 레이어 분리: 본체보다 위에 그려져 z-fighting 없이 표시되도록 renderingOrder 높이기
        node.renderingOrder = 20
        return node
    }

    // MARK: - 거리 텍스트 텍스처 (DistanceMarker 중앙 "{N}m")

    /// 512² 캔버스에 "{meters}m" (사양 §2-1) 를 그려 CGImage 로 반환.
    /// 50m 초과면 "50m+" 표시. SF Pro Display 800, 흰색, 짙은 푸른 그림자.
    /// 정수 단위 캐싱: 메인 스레드 블로킹 완화 (호출당 ~수 ms → 캐시 hit 시 즉시 반환).
    static func makeDistanceTextTexture(meters: Int) -> CGImage? {
        // 캐시 hit fast path
        textureCacheLock.lock()
        if let cached = distanceTextureCache[meters] {
            textureCacheLock.unlock()
            return cached
        }
        textureCacheLock.unlock()

        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext

            // 그림자
            cg.setShadow(
                offset: CGSize(width: 0, height: 6),
                blur: 16,
                color: UIColor(red: 0, green: 30/255, blue: 90/255, alpha: 0.35).cgColor
            )

            let numStr: String
            let unitStr: String
            if meters >= 50 {
                numStr = "50"
                unitStr = "m+"
            } else {
                numStr = "\(meters)"
                unitStr = "m"
            }

            let numSize: CGFloat = size.width * 0.42
            let unitSize: CGFloat = numSize * 0.60

            // SF Pro Display 800 ≈ heavy
            let numFont = UIFont.systemFont(ofSize: numSize, weight: .heavy)
            let unitFont = UIFont.systemFont(ofSize: unitSize, weight: .heavy)

            let numAttrs: [NSAttributedString.Key: Any] = [
                .font: numFont,
                .foregroundColor: UIColor.white
            ]
            let unitAttrs: [NSAttributedString.Key: Any] = [
                .font: unitFont,
                .foregroundColor: UIColor.white
            ]

            let numW = (numStr as NSString).size(withAttributes: numAttrs).width
            let unitW = (unitStr as NSString).size(withAttributes: unitAttrs).width
            let gap: CGFloat = size.width * 0.02
            let total = numW + gap + unitW

            // baseline 정렬: 알파벳 baseline 을 y=0.56h 부근.
            // UIKit text drawing 은 top-left 기준이라 baseline 보정 필요 (대략 font.ascender 차이만큼 위로).
            let baselineY: CGFloat = size.height * 0.56
            let startX: CGFloat = size.width / 2.0 - total / 2.0

            let numY = baselineY - numFont.ascender
            let unitY = baselineY - unitFont.ascender

            (numStr as NSString).draw(at: CGPoint(x: startX, y: numY), withAttributes: numAttrs)
            (unitStr as NSString).draw(at: CGPoint(x: startX + numW + gap, y: unitY), withAttributes: unitAttrs)
        }
        let cg = img.cgImage

        // 캐시 저장
        if let cg = cg {
            textureCacheLock.lock()
            distanceTextureCache[meters] = cg
            textureCacheLock.unlock()
        }
        return cg
    }

    // MARK: - "Next" 텍스트 텍스처 (NextArrow 중앙)

    static func makeNextTextTexture() -> CGImage? {
        // 단일 인스턴스 캐싱
        textureCacheLock.lock()
        if let cached = cachedNextTexture {
            textureCacheLock.unlock()
            return cached
        }
        textureCacheLock.unlock()

        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setShadow(
                offset: CGSize(width: 0, height: 5),
                blur: 14,
                color: UIColor(red: 0, green: 30/255, blue: 90/255, alpha: 0.35).cgColor
            )
            let sz: CGFloat = size.width * 0.34
            let font = UIFont.systemFont(ofSize: sz, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let text = "Next" as NSString
            let textSize = text.size(withAttributes: attrs)
            let drawAt = CGPoint(
                x: (size.width - textSize.width) / 2.0,
                y: (size.height - textSize.height) / 2.0
            )
            text.draw(at: drawAt, withAttributes: attrs)
        }
        let cg = img.cgImage
        if let cg = cg {
            textureCacheLock.lock()
            cachedNextTexture = cg
            textureCacheLock.unlock()
        }
        return cg
    }
}
