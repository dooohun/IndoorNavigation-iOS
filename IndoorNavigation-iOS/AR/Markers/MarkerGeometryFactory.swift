import UIKit
import SceneKit

// MARK: - 마커 시각 구성 팩토리
// 사양 §1, §5, §7 (AR_MARKER_3D.md). 다이아몬드(흰 외곽 + 파란 inner) + 셰브론 + 텍스트 텍스처 빌더.
// SceneKit 매핑: SCNShape(UIBezierPath, extrusionDepth) + PBR (.physicallyBased) clearcoat.

enum MarkerGeometryFactory {

    // MARK: - 텍스처 캐시 (메인 스레드 블로킹 완화)
    // distance 텍스처 캐시는 PathChevron 시스템 도입으로 폐기 (2026-05-11).

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

    /// 빨강 지도 핀 형상 (사양 §2-3 재정밀화). bulb 폭 ≈ 본체 폭, 좌우 cubic Bezier 로 부드럽게 tip 수렴.
    /// 구성: 흰 outer shell + 빨강 inner (bulb 중심에 hole through-cut, EO fill rule).
    /// 외곽선은 등거리 inset (borderInset) — bulbR / tip y 만 inset 적용해 bulb 동심원·tip 일정 거리 유지.
    /// 비율: pinHeight = size * 1.35, outerR = size * 0.48 (bulb 가 본체 폭 거의 차지), bulbCenter.y = pinHeight * 0.32.
    /// tip 이 노드 원점 y=0 에 오도록 평행이동.
    static func makeDestinationPinBody(size: CGFloat) -> SCNNode {
        let depth: CGFloat = size * 0.28
        let borderThickness: CGFloat = size * 0.035
        let innerDepth: CGFloat = depth * 1.04

        let group = SCNNode()
        group.name = "destinationPinBody"

        // outer shell (흰) — borderInset=0
        let outerShape = destinationPinPath(size: size, holeRadius: 0, borderInset: 0)
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

        // inner (빨강 #FF2D2D) — borderInset = borderThickness, bulb 중심에 hole 관통
        let innerBulbR: CGFloat = size * 0.48 - borderThickness
        let innerHoleR: CGFloat = innerBulbR * 0.50
        let innerShape = destinationPinPath(size: size, holeRadius: innerHoleR, borderInset: borderThickness)
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
        innerNode.position = SCNVector3(0, 0, Float(-innerDepth / 2 + depth * 0.04))
        group.addChildNode(innerNode)

        // tip 이 노드 원점 y=0 에 오도록 보정.
        // path local 에서 tip.y = -pinHeight * 0.4 = -size * 0.54.
        let pinHeight: CGFloat = size * 1.35
        let tipLocalY: CGFloat = -pinHeight * 0.4
        group.position = SCNVector3(0, Float(-tipLocalY), 0)
        return group
    }

    /// DestinationPin path. bulb 동심 반원 + 좌우 cubic Bezier 가 tip 으로 부드럽게 수렴.
    /// borderInset > 0 이면 bulbR 축소 + tip 위로 이동해 등거리 외곽선 형성 (bulb 동심원 정확).
    /// polyline 분할로 SCNShape 의 path flattening 영향 회피.
    private static func destinationPinPath(size: CGFloat, holeRadius: CGFloat, borderInset: CGFloat = 0) -> UIBezierPath {
        let pinHeight: CGFloat = size * 1.35
        let outerR: CGFloat = size * 0.48
        let bulbR: CGFloat = outerR - borderInset
        let bulbCenter = CGPoint(x: 0, y: pinHeight * 0.32)
        let tip = CGPoint(x: 0, y: -pinHeight * 0.4 + borderInset)
        let leftTangent = CGPoint(x: -bulbR, y: bulbCenter.y)
        let rightTangent = CGPoint(x: bulbR, y: bulbCenter.y)

        let path = UIBezierPath()
        path.move(to: leftTangent)

        // 위 반원 polyline (40 seg). bulb 동심원 — bulbR 만 차이.
        let bulbSegments = 40
        for i in 1...bulbSegments {
            let t = CGFloat(i) / CGFloat(bulbSegments)
            let angle = CGFloat.pi - CGFloat.pi * t
            let x = bulbCenter.x + cos(angle) * bulbR
            let y = bulbCenter.y + sin(angle) * bulbR
            path.addLine(to: CGPoint(x: x, y: y))
        }

        // 우측 cubic Bezier: rightTangent → tip. control point 가 bulbR 비례 → 외곽선 균등성 유지.
        // cp1: bulb 접선 연장 (수직 하향), cp2: tip 근처에서 부드럽게 좁아짐.
        let cubicSegments = 40
        let cp1Right = CGPoint(x: bulbR, y: bulbCenter.y - bulbR * 0.55)
        let cp2Right = CGPoint(x: bulbR * 0.20, y: tip.y + bulbR * 0.30)
        for i in 1...cubicSegments {
            let t = CGFloat(i) / CGFloat(cubicSegments)
            let oneT = 1.0 - t
            let x = oneT*oneT*oneT * rightTangent.x
                  + 3*oneT*oneT*t * cp1Right.x
                  + 3*oneT*t*t * cp2Right.x
                  + t*t*t * tip.x
            let y = oneT*oneT*oneT * rightTangent.y
                  + 3*oneT*oneT*t * cp1Right.y
                  + 3*oneT*t*t * cp2Right.y
                  + t*t*t * tip.y
            path.addLine(to: CGPoint(x: x, y: y))
        }

        // 좌측 cubic Bezier: tip → leftTangent (대칭)
        let cp1Left = CGPoint(x: -bulbR * 0.20, y: tip.y + bulbR * 0.30)
        let cp2Left = CGPoint(x: -bulbR, y: bulbCenter.y - bulbR * 0.55)
        for i in 1...cubicSegments {
            let t = CGFloat(i) / CGFloat(cubicSegments)
            let oneT = 1.0 - t
            let x = oneT*oneT*oneT * tip.x
                  + 3*oneT*oneT*t * cp1Left.x
                  + 3*oneT*t*t * cp2Left.x
                  + t*t*t * leftTangent.x
            let y = oneT*oneT*oneT * tip.y
                  + 3*oneT*oneT*t * cp1Left.y
                  + 3*oneT*t*t * cp2Left.y
                  + t*t*t * leftTangent.y
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.close()

        // hole: bulb 중심 정원, polyline 분할 (40 segment) — SCNShape 가 arc 를 4점 직선화하던 문제 회피
        if holeRadius > 0 {
            let holeSegments = 40
            let holePath = UIBezierPath()
            // 시작점: 0 라디안 위치 (오른쪽)
            holePath.move(to: CGPoint(x: bulbCenter.x + holeRadius, y: bulbCenter.y))
            for i in 1...holeSegments {
                let t = CGFloat(i) / CGFloat(holeSegments)
                let angle = CGFloat.pi * 2 * t
                let x = bulbCenter.x + cos(angle) * holeRadius
                let y = bulbCenter.y + sin(angle) * holeRadius
                holePath.addLine(to: CGPoint(x: x, y: y))
            }
            holePath.close()
            path.append(holePath)
        }
        return path
    }
}
