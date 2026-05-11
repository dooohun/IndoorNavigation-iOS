import UIKit
import SceneKit

// MARK: - 마커 시각 구성 팩토리
// 사양 §1, §5, §7 (AR_MARKER_3D.md). 다이아몬드(흰 외곽 + 파란 inner) + 셰브론 + 텍스트 텍스처 빌더.
// SceneKit 매핑: SCNShape(UIBezierPath, extrusionDepth) + PBR (.physicallyBased) clearcoat.

enum MarkerGeometryFactory {

    // MARK: - 텍스처 캐시 (메인 스레드 블로킹 완화: 거리 텍스처는 정수 단위라 ~50개로 한정)

    private static var distanceTextureCache: [Int: CGImage] = [:]
    private static var cachedNextTexture: CGImage?
    private static var cachedElevatorTexture: CGImage?
    private static var cachedStairsTexture: CGImage?
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

    // MARK: - 한글 라벨 텍스처 (Elevator/Stairs 중앙)

    /// "엘리베이터" — 한글 5자, initial fontSize 100pt. 폭 78% 초과 시 4pt 단위 축소 fitter (사양 §2-4).
    static func makeElevatorTextTexture() -> CGImage? {
        textureCacheLock.lock()
        if let cached = cachedElevatorTexture {
            textureCacheLock.unlock()
            return cached
        }
        textureCacheLock.unlock()

        let cg = makeKoreanLabelTexture(text: "엘리베이터", initialFontSize: 100)
        if let cg = cg {
            textureCacheLock.lock()
            cachedElevatorTexture = cg
            textureCacheLock.unlock()
        }
        return cg
    }

    /// "계단" — 한글 2자, initial fontSize 175pt (DistanceMarker "21m" 스케일 ≈ 34%, 사양 §2-4).
    static func makeStairsTextTexture() -> CGImage? {
        textureCacheLock.lock()
        if let cached = cachedStairsTexture {
            textureCacheLock.unlock()
            return cached
        }
        textureCacheLock.unlock()

        let cg = makeKoreanLabelTexture(text: "계단", initialFontSize: 175)
        if let cg = cg {
            textureCacheLock.lock()
            cachedStairsTexture = cg
            textureCacheLock.unlock()
        }
        return cg
    }

    /// 한글 라벨 공통 렌더러. 512² 캔버스, AppleSDGothicNeo-Bold → systemFont(.heavy) 폴백.
    /// 너비 > 캔버스 폭 78% (= 399.4pt) 면 fontSize 를 4pt 단위로 축소 (사양 §2-4 fitter, 하한 24pt).
    /// 그림자: y-offset 5, blur 14, rgba(0,30,90,0.35) — Next 텍스처 패턴.
    private static func makeKoreanLabelTexture(text: String, initialFontSize: CGFloat) -> CGImage? {
        let size = CGSize(width: 512, height: 512)
        let maxWidth: CGFloat = size.width * 0.78  // 399.4

        // 폰트 선택 헬퍼: AppleSDGothicNeo-Bold 우선, nil 시 systemFont(.heavy) 폴백.
        func font(for pt: CGFloat) -> UIFont {
            if let f = UIFont(name: "AppleSDGothicNeo-Bold", size: pt) {
                return f
            }
            return UIFont.systemFont(ofSize: pt, weight: .heavy)
        }

        // fitter: 측정 → 폭 초과 시 4pt 단위 축소 (하한 24pt)
        var fontSize: CGFloat = initialFontSize
        var fittedFont = font(for: fontSize)
        let nsText = text as NSString
        while fontSize > 24 {
            let attrs: [NSAttributedString.Key: Any] = [.font: fittedFont]
            let w = nsText.size(withAttributes: attrs).width
            if w <= maxWidth { break }
            fontSize -= 4
            fittedFont = font(for: fontSize)
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setShadow(
                offset: CGSize(width: 0, height: 5),
                blur: 14,
                color: UIColor(red: 0, green: 30/255, blue: 90/255, alpha: 0.35).cgColor
            )
            let attrs: [NSAttributedString.Key: Any] = [
                .font: fittedFont,
                .foregroundColor: UIColor.white
            ]
            let textSize = nsText.size(withAttributes: attrs)
            let drawAt = CGPoint(
                x: (size.width - textSize.width) / 2.0,
                y: (size.height - textSize.height) / 2.0
            )
            nsText.draw(at: drawAt, withAttributes: attrs)
        }
        return img.cgImage
    }

    // MARK: - DestinationPin 본체

    /// 빨강 지도 핀 형상 (사양 §2-3). 본체폭:외곽:두께 = 100:6:28.
    /// 구성: 흰 outer shell + 빨강 inner (bulb 중심에 hole through-cut, EO fill rule).
    /// size 는 본체 폭 (m). 높이 ≈ size * 1.56, bulb 반지름 ≈ size * 0.38, hole 반지름 ≈ bulb * 0.44.
    /// tip 이 노드 원점 y=0 에 오도록 평행이동 (배치 직관: worldPosition 이 핀 끝점이 됨).
    static func makeDestinationPinBody(size: CGFloat) -> SCNNode {
        let depth: CGFloat = size * 0.28
        let borderFrac: CGFloat = 0.06
        let innerSize: CGFloat = size * (1.0 - borderFrac)
        let innerDepth: CGFloat = depth * 1.04  // inner 가 outer 보다 약간 앞으로

        let group = SCNNode()
        group.name = "destinationPinBody"

        // outer shell (흰)
        let outerShape = destinationPinPath(size: size, holeRadius: 0)  // outer: hole 없음
        let outerGeo = SCNShape(path: outerShape, extrusionDepth: depth)
        outerGeo.chamferRadius = 0
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
        outerNode.position = SCNVector3(0, 0, Float(-depth / 2))
        group.addChildNode(outerNode)

        // inner (빨강 #FF2D2D) — bulb 중심에 hole (반지름 = bulbR * 0.44) 관통
        let innerBulbR: CGFloat = innerSize * 0.38
        let innerHoleR: CGFloat = innerBulbR * 0.44
        let innerShape = destinationPinPath(size: innerSize, holeRadius: innerHoleR)
        innerShape.usesEvenOddFillRule = true
        let innerGeo = SCNShape(path: innerShape, extrusionDepth: innerDepth)
        innerGeo.chamferRadius = 0
        let innerMat = SCNMaterial()
        innerMat.lightingModel = .physicallyBased
        innerMat.diffuse.contents = UIColor(red: 0xFF/255.0, green: 0x2D/255.0, blue: 0x2D/255.0, alpha: 1.0)
        innerMat.roughness.contents = 0.40
        innerMat.metalness.contents = 0.0
        innerMat.clearCoat.contents = 0.55
        innerMat.clearCoatRoughness.contents = 0.22
        innerMat.isDoubleSided = true
        innerGeo.materials = [innerMat]
        let innerNode = SCNNode(geometry: innerGeo)
        // 다이아몬드 inner 패턴: 살짝 앞쪽(+z)으로 돌출
        innerNode.position = SCNVector3(0, 0, Float(-innerDepth / 2 + depth * 0.04))
        group.addChildNode(innerNode)

        // tip 이 노드 원점 y=0 에 오도록 평행이동.
        // pinHeight = size * 1.56, bulbCenter.y = pinHeight * 0.20, tip.y = bulbCenter.y - pinHeight * 0.65.
        // path local 에서 tip.y = size * 1.56 * (0.20 - 0.65) = size * 1.56 * -0.45 = -size * 0.702
        // → group.position.y 로 보정해 노드 원점 y=0 이 tip 위치가 되도록.
        let pinHeight: CGFloat = size * 1.56
        let tipLocalY: CGFloat = pinHeight * 0.20 - pinHeight * 0.65  // = -pinHeight * 0.45
        group.position = SCNVector3(0, Float(-tipLocalY), 0)
        return group
    }

    /// DestinationPin path (지도 핀 실루엣). bulb 위 반원 + 좌우 quadCurve 가 tip 으로 수렴.
    /// holeRadius > 0 이면 bulb 중심에 추가 원을 그려 EO fill rule 로 관통 처리.
    /// 비율: pinHeight = size * 1.56, bulbR = size * 0.38, bulbCenter.y = pinHeight * 0.20,
    ///        tip.y = bulbCenter.y - pinHeight * 0.65.
    private static func destinationPinPath(size: CGFloat, holeRadius: CGFloat) -> UIBezierPath {
        let pinHeight: CGFloat = size * 1.56
        let bulbR: CGFloat = size * 0.38
        let bulbCenter = CGPoint(x: 0, y: pinHeight * 0.20)
        let tip = CGPoint(x: 0, y: bulbCenter.y - pinHeight * 0.65)
        let leftTangent = CGPoint(x: -bulbR, y: bulbCenter.y)
        let rightTangent = CGPoint(x: bulbR, y: bulbCenter.y)

        let path = UIBezierPath()
        // bulb 위 반원: leftTangent → rightTangent (UIBezierPath 의 flipped y 좌표계 주의 — clockwise 토글로 처리)
        path.move(to: leftTangent)
        path.addArc(
            withCenter: bulbCenter,
            radius: bulbR,
            startAngle: .pi,
            endAngle: 0,
            clockwise: false
        )
        // 오른쪽 곡선: rightTangent → tip (control 포인트: x = bulbR * 0.55, y = bulbCenter.y - bulbR * 0.85)
        path.addQuadCurve(
            to: tip,
            controlPoint: CGPoint(x: bulbR * 0.55, y: bulbCenter.y - bulbR * 0.85)
        )
        // 왼쪽 곡선: tip → leftTangent
        path.addQuadCurve(
            to: leftTangent,
            controlPoint: CGPoint(x: -bulbR * 0.55, y: bulbCenter.y - bulbR * 0.85)
        )
        path.close()

        // hole: bulb 중심에 정원 추가 (EO fill rule 로 관통)
        if holeRadius > 0 {
            let holePath = UIBezierPath(
                arcCenter: bulbCenter,
                radius: holeRadius,
                startAngle: 0,
                endAngle: .pi * 2,
                clockwise: true
            )
            path.append(holePath)
        }
        return path
    }
}
