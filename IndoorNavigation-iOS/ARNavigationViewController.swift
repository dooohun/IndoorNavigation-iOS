import UIKit
import SceneKit
import ARKit

/// Phase 6: HUD 컨테이너용 pass-through view. 자식이 잡지 않은 터치는 sceneView 로 통과.
/// transparent HUD 영역에서 sceneView 의 더블탭 제스처(측위 재시작) 가 정상 동작하도록.
private final class HUDPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // 자기 자신은 통과시키고, 자식이 잡으면 그 자식 반환
        return hit === self ? nil : hit
    }
}

/// Phase 6 후속: nav 카드 스타일 상수. ARNavigationViewController 와 FloorNavigationMapView 가 공유.
/// MapDesignTokens 에 추가하지 않음 — 파일 주석에 "다른 화면 적용 X" 명시되어 있어 AR HUD 로컬 상수로 둔다.
fileprivate enum NavCardStyle {
    static let background = UIColor(red: 0x2C/255, green: 0x4A/255, blue: 0x3A/255, alpha: 1)  // #2C4A3A
    static let cornerRadius: CGFloat = 14
    static let iconSize: CGFloat = 36
    static let iconGap: CGFloat = 8
    static let paddingTop: CGFloat = 10
    static let paddingRight: CGFloat = 16
    static let paddingBottom: CGFloat = 10
    static let paddingLeft: CGFloat = 12
    static let distanceFontSize: CGFloat = 28
    static let directionFontSize: CGFloat = 14
}

private final class FloorNavigationMapView: UIView {

    // MARK: - Data state

    private var floorMap: FloorMapResponse?
    private var routeSteps: [PathStep] = []
    private var currentPosition: Position?
    private var destinationName: String?
    private var destinationWorldPoint: CGPoint?
    private var polygonRings: [[CGPoint]] = []
    private var navigationPolygons: [MapPolygon] = []
    private var activeNavigationPolygonIndex: Int?
    private var activeNavigationPolygonBearingDegrees: Float?
    private var targetWorldPoint: CGPoint?
    private var displayedWorldPoint: CGPoint?
    private var userZoomScale = CGFloat(MapDesignTokens.Metric.mapZoomDefault)
    private var currentAutoScaleLockSignature: String?
    private var lockedAutoScaleCorridorWidthMeters: CGFloat?

    /// 위치 핀 거리 배지의 회전 아이콘/거리. updateNextAction 으로 외부에서 주입.
    private var currentNavAction: NavigationActionKind = .straight
    private var currentNavActionDistanceMeters: CGFloat?

    // MARK: - Heading smoothing (ADR §D)

    /// 외부에서 받은 최신 heading 입력 (EMA 필터 적용 전)
    private var targetHeadingDegrees: Float?
    /// CADisplayLink가 보간해 나가는 현재 heading
    private var currentHeadingDegrees: Float?
    /// corridor polygon 진입으로 결정된 목표 지도 방향.
    private var targetMapBearingDegrees: Float?
    /// CADisplayLink가 보간해 나가는 현재 지도 방향.
    private var currentMapBearingDegrees: Float?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0

    // MARK: - Layer cache (ADR §E)

    /// 정적 컨텐츠 (폴리곤·엣지·경로·마커) — corridor polygon axis-up 기준으로 그린 CGImage를 보관
    private let staticContentLayer = CALayer()
    /// 동적 컨텐츠 (현재 위치 마커만)
    private let dynamicOverlayLayer = CALayer()
    /// dynamicOverlayLayer 전용 delegate — UIView를 sublayer delegate로 두면 backing layer
    /// delegate 흐름과 충돌해 stack overflow(EXC_BAD_ACCESS code=2)를 일으킨다.
    private let overlayDrawer = OverlayLayerDrawer()
    /// true이면 다음 displayLink tick에서 staticContentLayer를 재생성
    private var staticCacheDirty = true

    // MARK: - Marker kind

    private enum MapMarkerKind {
        case poi
        case elevator
        case stairs
        case escalator

        var priority: Int {
            switch self {
            case .elevator: return 0
            case .stairs: return 1
            case .escalator: return 2
            case .poi: return 3
            }
        }

        /// 마커 그리기에 사용할 Asset 이름. escalator는 stairs 폴백.
        var imageName: String {
            switch self {
            case .poi: return "roomIcon"
            case .elevator: return "elevator"
            case .stairs, .escalator: return "stairs"
            }
        }
    }

    private struct MapMarker {
        let kind: MapMarkerKind
        let worldPoint: CGPoint
        let label: String?
    }

    private struct MarkerPinLayout {
        /// 아이콘이 그려질 사각형 (가로/세로 = markerIconSize).
        let iconRect: CGRect
        /// (있을 경우) 라벨이 그려질 사각형. nil 이면 라벨 미표시.
        let labelRect: CGRect?
        /// 충돌 판정에 쓸 합쳐진 영역 (iconRect ∪ labelRect).
        var collisionRect: CGRect {
            guard let labelRect else { return iconRect }
            return iconRect.union(labelRect)
        }
    }

    private struct RouteMapPoint {
        let point: CGPoint
        let floorLevel: Int?
        let nodeId: String?
    }

    private struct MapPolygon {
        let kind: String?
        let rings: [[CGPoint]]
        let bearingDegrees: Float?

        var isFloorUnion: Bool {
            kind == "floor_union"
        }

        func contains(_ point: CGPoint) -> Bool {
            rings.contains { FloorNavigationMapMath.contains(point, in: $0) }
        }

        func orientedBearing(referenceDegrees: Float?) -> Float? {
            guard let bearingDegrees else { return nil }
            return FloorNavigationMapMath.orientedAxisDegrees(
                axisDegrees: bearingDegrees,
                referenceDegrees: referenceDegrees
            )
        }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = MapDesignTokens.Surface.backdropDim
        isOpaque = true

        staticContentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.72)
        staticContentLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(staticContentLayer)

        overlayDrawer.owner = self
        dynamicOverlayLayer.delegate = overlayDrawer
        dynamicOverlayLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(dynamicOverlayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - External interface

    private static func autoScaleLockSignature(map: FloorMapResponse, routeSteps: [PathStep]) -> String {
        let routeSignature = routeSteps.map { step -> String in
            let x = step.position?.x.map { String(format: "%.3f", $0) } ?? "nil"
            let y = step.position?.y.map { String(format: "%.3f", $0) } ?? "nil"
            return [
                String(step.stepNumber),
                step.floorLevel.map(String.init) ?? "nil",
                step.nodeId ?? "nil",
                x,
                y
            ].joined(separator: ",")
        }.joined(separator: ";")
        return [
            map.buildingId,
            map.floorId,
            map.scanId,
            map.etag,
            String(map.floorLevel),
            routeSignature
        ].joined(separator: "|")
    }

    func configure(map: FloorMapResponse,
                   routeSteps: [PathStep],
                   currentPosition: Position?,
                   currentHeadingDegrees: Float?,
                   destinationName: String?,
                   destinationWorldPoint: CGPoint?) {
        self.floorMap = map
        self.routeSteps = routeSteps
        self.currentPosition = currentPosition
        self.destinationName = destinationName
        self.destinationWorldPoint = destinationWorldPoint
        let nextAutoScaleLockSignature = Self.autoScaleLockSignature(map: map, routeSteps: routeSteps)
        if currentAutoScaleLockSignature != nextAutoScaleLockSignature {
            currentAutoScaleLockSignature = nextAutoScaleLockSignature
            lockedAutoScaleCorridorWidthMeters = nil
        }
        let parsedPolygons = Self.extractMapPolygons(from: map.polygon.raw)
        self.polygonRings = Self.displayPolygonRings(from: parsedPolygons)
        let localNavigationPolygons = parsedPolygons.filter { !$0.isFloorUnion && !$0.rings.isEmpty }
        self.navigationPolygons = localNavigationPolygons.isEmpty
            ? parsedPolygons.filter { !$0.rings.isEmpty }
            : localNavigationPolygons
        self.activeNavigationPolygonIndex = nil
        self.activeNavigationPolygonBearingDegrees = nil
        updateWorldPointTarget(resetCurrent: true)

        if let heading = currentHeadingDegrees {
            if let existing = targetHeadingDegrees {
                // EMA(α=0.2) 로 target 업데이트
                targetHeadingDegrees = existing + 0.2 * shortestArcDelta(from: existing, to: heading)
            } else {
                targetHeadingDegrees = heading
                self.currentHeadingDegrees = heading
            }
        } else {
            targetHeadingDegrees = nil
            self.currentHeadingDegrees = nil
        }
        updateMapBearingTarget(resetCurrent: true)

        staticCacheDirty = true
        resumeDisplayLink()
    }

    func updateCurrentPosition(_ position: Position?, headingDegrees: Float?) {
        currentPosition = position
        updateWorldPointTarget(resetCurrent: false)

        if let heading = headingDegrees {
            if let existing = targetHeadingDegrees {
                targetHeadingDegrees = existing + 0.2 * shortestArcDelta(from: existing, to: heading)
            } else {
                targetHeadingDegrees = heading
                currentHeadingDegrees = heading
            }
        } else {
            targetHeadingDegrees = nil
            currentHeadingDegrees = nil
        }
        updateMapBearingTarget(resetCurrent: false)

        staticCacheDirty = true
        resumeDisplayLink()
    }

    var currentZoomScale: CGFloat { userZoomScale }

    func setZoomScale(_ zoomScale: CGFloat) {
        let clamped = min(max(zoomScale, CGFloat(MapDesignTokens.Metric.mapZoomMinimum)),
                          CGFloat(MapDesignTokens.Metric.mapZoomMaximum))
        guard abs(clamped - userZoomScale) > 0.001 else { return }
        userZoomScale = clamped
        staticCacheDirty = true
        resumeDisplayLink()
    }

    /// 위치 핀 아래 거리 배지의 회전 아이콘/거리 표기 갱신. updateNavigationStep 에서 forward 됨.
    func updateNextAction(_ action: NavigationActionKind, distanceMeters: CGFloat?) {
        self.currentNavAction = action
        self.currentNavActionDistanceMeters = distanceMeters
        staticCacheDirty = false
        dynamicOverlayLayer.setNeedsDisplay()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // staticContentLayer: anchorPoint (0.5, 0.72) 기준이므로 position을 anchor 좌표로 설정
        staticContentLayer.bounds = bounds
        staticContentLayer.position = CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.72)
        dynamicOverlayLayer.frame = bounds
        CATransaction.commit()
        staticCacheDirty = true
        if window != nil {
            resumeDisplayLink()
        }
    }

    // UIView.draw(_:)는 더 이상 cache 갱신에 쓰지 않는다 — 빈 구현으로 유지 (ADR §E)
    override func draw(_ rect: CGRect) {}

    // MARK: - DisplayLink lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            resumeDisplayLink()
        } else {
            pauseDisplayLink()
        }
    }

    override func removeFromSuperview() {
        pauseDisplayLink()
        super.removeFromSuperview()
    }

    private func resumeDisplayLink() {
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    private func pauseDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - DisplayLink tick (ADR §D + §E)

    @objc private func displayLinkTick(_ sender: CADisplayLink) {
        let now = sender.timestamp
        let dt = lastFrameTime == 0 ? 0 : now - lastFrameTime
        lastFrameTime = now

        // heading 보간: shortest-arc, tau=0.18s
        if let target = targetHeadingDegrees, let current = currentHeadingDegrees {
            let delta = shortestArcDelta(from: current, to: target)
            let alpha = dt == 0 ? 0 : Float(min(1.0, dt / MapDesignTokens.Metric.headingSmoothingTau))
            currentHeadingDegrees = current + delta * alpha
        } else if let target = targetHeadingDegrees {
            currentHeadingDegrees = target
        }

        var mapBearingDelta: Float = 0
        if let target = targetMapBearingDegrees, let current = currentMapBearingDegrees {
            let delta = shortestArcDelta(from: current, to: target)
            let alpha = dt == 0 ? 0 : Float(min(1.0, dt / MapDesignTokens.Metric.mapBearingSmoothingTau))
            mapBearingDelta = delta * alpha
            currentMapBearingDegrees = current + mapBearingDelta
            if abs(mapBearingDelta) >= 0.01 {
                staticCacheDirty = true
            }
        } else if let target = targetMapBearingDegrees {
            currentMapBearingDegrees = target
            mapBearingDelta = 1
            staticCacheDirty = true
        }

        var positionDelta = CGFloat.zero
        if let target = targetWorldPoint, let current = displayedWorldPoint {
            let alpha = dt == 0 ? CGFloat.zero : CGFloat(min(1.0, dt / MapDesignTokens.Metric.mapPositionSmoothingTau))
            let interpolated = CGPoint(
                x: current.x + (target.x - current.x) * alpha,
                y: current.y + (target.y - current.y) * alpha
            )
            let next = snappedRoutePoint(interpolated) ?? interpolated
            positionDelta = hypot(next.x - current.x, next.y - current.y)
            displayedWorldPoint = next
            if positionDelta >= 0.001 {
                staticCacheDirty = true
            }
        } else if let target = targetWorldPoint {
            displayedWorldPoint = target
            positionDelta = 1
            staticCacheDirty = true
        }

        // static cache 재생성
        if staticCacheDirty {
            rebuildStaticContent()
            staticCacheDirty = false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        staticContentLayer.setAffineTransform(.identity)
        CATransaction.commit()

        // 현재 위치 마커 갱신
        dynamicOverlayLayer.setNeedsDisplay()

        let headingRemainingDelta = remainingDelta(current: currentHeadingDegrees, target: targetHeadingDegrees)
        let mapBearingRemainingDelta = remainingDelta(current: currentMapBearingDegrees, target: targetMapBearingDegrees)
        let positionRemainingDistance = remainingDistance(current: displayedWorldPoint, target: targetWorldPoint)

        // idle 조건: heading/map bearing 거의 수렴 + cache 깨끗하면 displayLink 일시정지
        if headingRemainingDelta < 0.05
            && mapBearingRemainingDelta < 0.05
            && positionRemainingDistance < 0.002
            && !staticCacheDirty {
            displayLink?.isPaused = true
            lastFrameTime = 0
        }
    }

    // MARK: - Static content rebuild (ADR §E)

    private func rebuildStaticContent() {
        guard let floorMap, !bounds.isEmpty else { return }
        let drawRect = bounds.insetBy(dx: 12, dy: 10)
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            let transform = makeStaticTransform(bounds: floorMap.bounds, rect: drawRect)
            cgContext.saveGState()
            cgContext.clip(to: drawRect)
            if !polygonRings.isEmpty {
                drawPolygon(context: cgContext, rings: polygonRings, transform: transform)
            }
            drawRoute(context: cgContext, floorLevel: floorMap.floorLevel, transform: transform)
            drawMarkers(context: cgContext, map: floorMap, transform: transform, clipRect: drawRect)
            drawDestinationPin(context: cgContext, transform: transform, clipRect: drawRect)
            cgContext.restoreGState()
        }
        staticContentLayer.contents = image.cgImage
    }

    /// 현재 위치 기준 viewport transform 계산 (정적 캐시용).
    /// 지도 방향은 현재 진입한 corridor polygon axis가 화면 수직이 되도록 맞춘다.
    private func makeStaticTransform(bounds: FloorMapBounds, rect: CGRect) -> (CGPoint) -> CGPoint {
        guard let worldPoint = currentWorldPoint else {
            return makeFloorFitTransform(bounds: bounds, rect: rect)
        }
        return makeRouteAlignedTransform(bounds: bounds,
                                         rect: rect,
                                         currentWorldPoint: worldPoint,
                                         bearingDegrees: displayedMapBearingDegrees() ?? 0)
    }

    // MARK: - Draw helpers

    private func drawPolygon(context: CGContext,
                             rings: [[CGPoint]],
                             transform: (CGPoint) -> CGPoint) {
        let path = UIBezierPath()
        for ring in rings where ring.count >= 3 {
            let first = transform(ring[0])
            path.move(to: first)
            for point in ring.dropFirst() {
                path.addLine(to: transform(point))
            }
            path.close()
        }

        MapDesignTokens.Surface.floorFill.setFill()
        path.usesEvenOddFillRule = true
        path.fill(with: .normal, alpha: 1.0)
        MapDesignTokens.Stroke.floorOutline.setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }

    private func drawGraph(context: CGContext,
                           map: FloorMapResponse,
                           transform: (CGPoint) -> CGPoint) {
        let nodesById = map.nodes.reduce(into: [String: FloorMapNode]()) { result, node in
            result[node.id] = node
        }
        context.setLineCap(.round)
        for edge in map.edges {
            guard let from = nodesById[edge.fromId], let to = nodesById[edge.toId] else { continue }
            let start = transform(CGPoint(x: from.x, y: from.y))
            let end = transform(CGPoint(x: to.x, y: to.y))
            let edgeColor = edge.type == "corridor"
                ? MapDesignTokens.Stroke.edgeCorridor
                : MapDesignTokens.Stroke.edgeOther
            context.setStrokeColor(edgeColor.cgColor)
            context.setLineWidth(edge.type == "corridor" ? 2.0 : 1.0)
            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }
    }

    private func drawRoute(context: CGContext,
                           floorLevel: Int,
                           transform: (CGPoint) -> CGPoint) {
        var points = routeWorldPoints(filterFloorLevel: floorLevel)
        if points.count < 2 {
            points = routeWorldPoints(filterFloorLevel: nil)
        }
        guard points.count >= 2 else { return }

        let path = UIBezierPath()
        path.move(to: transform(points[0]))
        for point in points.dropFirst() {
            path.addLine(to: transform(point))
        }

        // heading-up 회전에서는 사용자 정면이 화면 위쪽이지만, 다른 방향을 바라봐도 전체 경로는 그대로 보여야 함.
        // 과거 route-aligned 시절의 "사용자 뒤쪽(화면 아래) 잘라내기" clip 은 heading-up 과 호환 X — 제거.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: MapDesignTokens.Shadow.route.cgColor)
        MapDesignTokens.Accent.route.setStroke()
        path.lineWidth = 5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        context.restoreGState()

        MapDesignTokens.Stroke.routeHalo.setStroke()
        path.lineWidth = 1.4
        path.stroke()
    }

    private func drawMarkers(context: CGContext,
                             map: FloorMapResponse,
                             transform: (CGPoint) -> CGPoint,
                             clipRect: CGRect) {
        let markers = mapMarkers(from: map)
        guard !markers.isEmpty else { return }

        let visibleRect = clipRect.insetBy(dx: -24, dy: -24)
        let currentScreenPoint = currentWorldPoint.map(transform)
        var occupiedRects: [CGRect] = []
        if let currentScreenPoint {
            let positionDiameter = MapDesignTokens.Metric.positionPuckDiameter + 8
            occupiedRects.append(CGRect(x: currentScreenPoint.x - positionDiameter / 2,
                                        y: currentScreenPoint.y - positionDiameter / 2,
                                        width: positionDiameter,
                                        height: positionDiameter))
        }

        let visibleMarkers = markers.compactMap { marker -> (MapMarker, CGPoint)? in
            let screenPoint = transform(marker.worldPoint)
            guard visibleRect.contains(screenPoint) else { return nil }
            return (marker, screenPoint)
        }.sorted { left, right in
            if left.0.kind.priority != right.0.kind.priority {
                return left.0.kind.priority < right.0.kind.priority
            }
            if let currentScreenPoint {
                return screenDistance(left.1, currentScreenPoint) < screenDistance(right.1, currentScreenPoint)
            }
            return (left.0.label ?? "") < (right.0.label ?? "")
        }

        for (marker, screenPoint) in visibleMarkers {
            if let currentScreenPoint, screenDistance(screenPoint, currentScreenPoint) < 42 { continue }
            let label = markerText(for: marker)
            guard let layout = markerPinLayout(label: label,
                                               point: screenPoint,
                                               clipRect: clipRect,
                                               occupiedRects: occupiedRects) else { continue }
            drawMarkerPin(context: context, kind: marker.kind, label: label, layout: layout)
            occupiedRects.append(layout.collisionRect.insetBy(dx: -4, dy: -4))
        }
    }

    private func mapMarkers(from map: FloorMapResponse) -> [MapMarker] {
        map.nodes.compactMap { node in
            guard let kind = markerKind(for: node) else { return nil }
            // 목적지 핀과 겹치는 0.2m 이내 POI 노드는 별도 destinationPin 으로 그려지므로 제외.
            if let dest = destinationWorldPoint {
                let dx = CGFloat(node.x) - dest.x
                let dy = CGFloat(node.y) - dest.y
                if hypot(dx, dy) < 0.2 { return nil }
            }
            return MapMarker(kind: kind,
                             worldPoint: CGPoint(x: node.x, y: node.y),
                             label: node.label)
        }
    }

    private func markerKind(for node: FloorMapNode) -> MapMarkerKind? {
        let type = node.type.lowercased()

        if type == "poi_attach" || type == "corridor" || type == "junction" || type == "endpoint" {
            return nil
        }
        // category 우선 — 서버가 poi 노드에 elevator/stairs/escalator 카테고리 부여 (예: type="poi", category="stairs").
        if let cat = node.category?.lowercased() {
            switch cat {
            case "elevator": return .elevator
            case "stairs": return .stairs
            case "escalator": return .escalator
            default: break
            }
        }
        if type == "poi" {
            return .poi
        }
        // 폴백 — category 누락 시 type/connector 매칭.
        let connectorType = node.connector?.type.lowercased()
        if type.contains("elevator") || connectorType == "elevator" {
            return .elevator
        }
        if type.contains("escalator") || connectorType == "escalator" {
            return .escalator
        }
        if type.contains("stair") || connectorType == "stair" || connectorType == "stairs" {
            return .stairs
        }
        return nil
    }

    private func drawMarkerPin(context: CGContext,
                               kind: MapMarkerKind,
                               label: String?,
                               layout: MarkerPinLayout) {
        if let image = UIImage(named: kind.imageName) {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 2),
                              blur: 5,
                              color: MapDesignTokens.Shadow.markerIcon.cgColor)
            image.draw(in: layout.iconRect)
            context.restoreGState()
        }
        if let labelRect = layout.labelRect, let label, !label.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: MapDesignTokens.Metric.markerLabelFontSize, weight: .medium),
                .foregroundColor: MapDesignTokens.Text.primary
            ]
            (label as NSString).draw(in: labelRect, withAttributes: attrs)
        }
    }

    /// 목적지 핀(빨간 위치 아이콘) + 상단 destinationName 텍스트를 그린다.
    /// pin tip 이 목적지 world point 위에 오도록 배치.
    private func drawDestinationPin(context: CGContext,
                                    transform: (CGPoint) -> CGPoint,
                                    clipRect: CGRect) {
        guard let destinationWorldPoint else { return }
        let screenPoint = transform(destinationWorldPoint)
        let visibleRect = clipRect.insetBy(dx: -24, dy: -24)
        guard visibleRect.contains(screenPoint) else { return }

        let pinWidth: CGFloat = 30
        let pinHeight: CGFloat = 37
        let pinRect = CGRect(
            x: screenPoint.x - pinWidth / 2,
            y: screenPoint.y - pinHeight,
            width: pinWidth,
            height: pinHeight
        )

        if let pinImage = UIImage(named: "destinationPin") {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            pinImage.draw(in: pinRect)
            context.restoreGState()
        } else {
            // Fallback — 핀 이미지 누락 시에도 빨간 원형 핀으로 표기
            context.saveGState()
            UIColor(red: 0.894, green: 0.227, blue: 0.188, alpha: 1.0).setFill()
            context.fillEllipse(in: pinRect)
            context.restoreGState()
        }

        if let name = destinationName, !name.isEmpty {
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor.black
            ]
            let textSize = (name as NSString).size(withAttributes: textAttributes)
            let textOrigin = CGPoint(
                x: screenPoint.x - textSize.width / 2,
                y: pinRect.minY - textSize.height - 2
            )

            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.white.withAlphaComponent(0.85).cgColor)
            (name as NSString).draw(at: textOrigin, withAttributes: textAttributes)
            context.restoreGState()
        }
    }

    private func markerPinLayout(label: String?,
                                 point: CGPoint,
                                 clipRect: CGRect,
                                 occupiedRects: [CGRect]) -> MarkerPinLayout? {
        let iconSize = MapDesignTokens.Metric.markerIconSize
        let iconRect = CGRect(x: point.x - iconSize / 2,
                              y: point.y - iconSize / 2,
                              width: iconSize,
                              height: iconSize)

        var labelRect: CGRect?
        if let label, !label.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: MapDesignTokens.Metric.markerLabelFontSize, weight: .medium)
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            let gap = MapDesignTokens.Metric.markerLabelGap
            labelRect = CGRect(x: point.x - size.width / 2,
                               y: iconRect.maxY + gap,
                               width: size.width,
                               height: size.height)
        }

        let candidate = MarkerPinLayout(iconRect: iconRect, labelRect: labelRect)
        let expanded = candidate.collisionRect.insetBy(dx: -3, dy: -3)
        guard clipRect.contains(candidate.collisionRect) else { return nil }
        guard !occupiedRects.contains(where: { $0.intersects(expanded) }) else { return nil }
        return candidate
    }

    private func displayLabel(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed.count <= 12 {
            return trimmed
        }
        return String(trimmed.prefix(12)) + "..."
    }

    private func markerText(for marker: MapMarker) -> String? {
        switch marker.kind {
        case .poi:
            return displayLabel(marker.label)
        case .elevator, .stairs, .escalator:
            return nil
        }
    }

    private func screenDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    // MARK: - Dynamic overlay: current position marker

    fileprivate func drawCurrentPositionMarker(in context: CGContext) {
        guard let currentWorldPoint,
              let floorMap else { return }
        let drawRect = bounds.insetBy(dx: 12, dy: 10)
        let transform = makeStaticTransform(bounds: floorMap.bounds, rect: drawRect)
        let point = transform(currentWorldPoint)

        if let heading = currentHeadingDegrees {
            drawHeadingMarker(context: context,
                              point: point,
                              headingDegrees: heading,
                              mapBearingDegrees: displayedMapBearingDegrees() ?? heading)
        } else {
            drawPositionDot(context: context, point: point)
        }
        let distForBadge: CGFloat? = currentNavActionDistanceMeters ?? remainingDistanceMetersForCurrentPoint(currentWorldPoint)
        if let dist = distForBadge {
            drawRemainingDistanceBadge(context: context, point: point, action: currentNavAction, distance: dist)
        }
    }

    private func drawPositionDot(context: CGContext, point: CGPoint) {
        let diameter = MapDesignTokens.Metric.positionPuckDiameter
        let outer = CGRect(x: point.x - diameter / 2,
                           y: point.y - diameter / 2,
                           width: diameter,
                           height: diameter)
        let inner = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 9, color: MapDesignTokens.Shadow.positionHalo.cgColor)
        MapDesignTokens.Stroke.markerHalo.setFill()
        context.fillEllipse(in: outer)
        context.restoreGState()

        MapDesignTokens.Accent.currentPosition.setFill()
        context.fillEllipse(in: inner)
    }

    private func drawHeadingMarker(context: CGContext,
                                   point: CGPoint,
                                   headingDegrees: Float,
                                   mapBearingDegrees: Float) {
        let angle = screenAngleRadians(headingDegrees: headingDegrees, mapBearingDegrees: mapBearingDegrees)

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)

        let diameter = MapDesignTokens.Metric.positionPuckDiameter
        let puckRect = CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: MapDesignTokens.Shadow.positionArrow.cgColor)
        MapDesignTokens.Stroke.markerHalo.setFill()
        context.fillEllipse(in: puckRect)
        context.restoreGState()

        context.rotate(by: angle)

        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: -13))
        path.addLine(to: CGPoint(x: -9, y: 11))
        path.addLine(to: CGPoint(x: 0, y: 6))
        path.addLine(to: CGPoint(x: 9, y: 11))
        path.close()

        MapDesignTokens.Accent.currentPosition.setFill()
        path.fill()

        context.restoreGState()
    }

    /// 위치 핀 바로 아래 nav-card 스타일 배지. 좌측 회전 아이콘 + 우측 큰 흰색 거리.
    private func drawRemainingDistanceBadge(context: CGContext,
                                            point: CGPoint,
                                            action: NavigationActionKind,
                                            distance: CGFloat) {
        let meters = max(0, Int(distance.rounded()))
        let label = "\(meters)m"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11.5, weight: .bold),
            .foregroundColor: MapDesignTokens.Text.primary
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let iconSize: CGFloat = 14
        let iconGap: CGFloat = 4
        let horizontalPadding: CGFloat = 10
        let contentWidth = iconSize + iconGap + textSize.width
        let badgeSize = CGSize(width: max(52, contentWidth + horizontalPadding * 2), height: 24)
        let markerDiameter = MapDesignTokens.Metric.positionPuckDiameter
        var originY = point.y + markerDiameter / 2 + 5
        if originY + badgeSize.height > bounds.maxY - 8 {
            originY = point.y - markerDiameter / 2 - badgeSize.height - 5
        }
        let rect = CGRect(x: point.x - badgeSize.width / 2,
                          y: originY,
                          width: badgeSize.width,
                          height: badgeSize.height)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: MapDesignTokens.Shadow.marker.cgColor)
        MapDesignTokens.Surface.controlFill.setFill()
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
        path.fill()
        MapDesignTokens.Stroke.labelBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        context.restoreGState()

        let contentOriginX = rect.midX - contentWidth / 2
        let iconRect = CGRect(x: contentOriginX,
                              y: rect.midY - iconSize / 2,
                              width: iconSize,
                              height: iconSize)
        if let iconImage = UIImage(named: navActionImageName(action)) {
            iconImage.withTintColor(MapDesignTokens.Text.primary, renderingMode: .alwaysOriginal).draw(in: iconRect)
        }

        let textRect = CGRect(x: iconRect.maxX + iconGap,
                              y: rect.midY - textSize.height / 2,
                              width: textSize.width,
                              height: textSize.height)
        (label as NSString).draw(in: textRect, withAttributes: attributes)
    }

    /// NavigationActionKind → 회전 아이콘 asset 이름. nav 카드 actionImage 와 동일 매핑.
    private func navActionImageName(_ action: NavigationActionKind) -> String {
        switch action {
        case .turnLeft: return "arrowTurnDownLeft"
        case .turnRight: return "arrowTurnDownRight"
        default: return "arrowUpThick"
        }
    }

    // MARK: - Transform helpers

    private func routeMapPoints(filterFloorLevel: Int?) -> [RouteMapPoint] {
        routeSteps.compactMap { step in
            if let filterFloorLevel,
               let stepFloor = step.floorLevel,
               stepFloor != filterFloorLevel {
                return nil
            }
            guard let pos = step.position,
                  let x = pos.x,
                  let y = pos.y else { return nil }
            return RouteMapPoint(
                point: CGPoint(x: x, y: y),
                floorLevel: step.floorLevel,
                nodeId: step.nodeId
            )
        }
    }

    private func routeWorldPoints(filterFloorLevel: Int?) -> [CGPoint] {
        adjustedRouteWorldPoints(from: routeMapPoints(filterFloorLevel: filterFloorLevel))
    }

    private func adjustedRouteWorldPoints(from routePoints: [RouteMapPoint]) -> [CGPoint] {
        var points = routePoints.map(\.point)
        guard points.count >= 2 else { return points }

        let firstKnownNodeAfterStart = routePoints.dropFirst().first { $0.nodeId != nil }?.nodeId
        let firstPointIsKnownVirtual = routePoints[0].nodeId == nil && firstKnownNodeAfterStart != nil
        let firstPointLooksVirtual = routePoints[0].nodeId == nil
            && firstKnownNodeAfterStart == nil
            && nearestNodeId(to: routePoints[0].point, maxDistance: 0.35) == nil
            && nearestNodeId(to: routePoints[1].point, maxDistance: 0.35) != nil

        guard firstPointIsKnownVirtual || firstPointLooksVirtual else { return points }

        let preferredNodeId = firstKnownNodeAfterStart
            ?? nearestNodeId(to: routePoints[1].point, maxDistance: 0.5)
        if let projectedStart = FloorNavigationMapMath.projectedPointOnGraphEdge(
            point: routePoints[0].point,
            segments: floorGraphSegments(),
            preferredConnectedNodeId: preferredNodeId
        ) {
            points[0] = projectedStart
        }
        return points
    }

    private func floorGraphSegments() -> [FloorNavigationMapMath.GraphSegment] {
        guard let floorMap else { return [] }
        let nodesById = floorMap.nodes.reduce(into: [String: FloorMapNode]()) { result, node in
            result[node.id] = node
        }
        return floorMap.edges.compactMap { edge in
            guard let from = nodesById[edge.fromId], let to = nodesById[edge.toId] else { return nil }
            return FloorNavigationMapMath.GraphSegment(
                fromId: edge.fromId,
                toId: edge.toId,
                type: edge.type,
                start: CGPoint(x: from.x, y: from.y),
                end: CGPoint(x: to.x, y: to.y)
            )
        }
    }

    private func nearestNodeId(to point: CGPoint, maxDistance: CGFloat) -> String? {
        guard let floorMap else { return nil }
        var best: (id: String, distance: CGFloat)?
        for node in floorMap.nodes {
            let distance = hypot(CGFloat(node.x) - point.x, CGFloat(node.y) - point.y)
            if distance <= maxDistance,
               best == nil || distance < best!.distance {
                best = (node.id, distance)
            }
        }
        return best?.id
    }

    private var usesHeadingUpTransform: Bool {
        currentWorldPoint != nil
    }

    private var currentWorldPoint: CGPoint? {
        displayedWorldPoint ?? targetWorldPoint ?? snappedTargetWorldPoint()
    }

    private func updateWorldPointTarget(resetCurrent: Bool) {
        guard let point = snappedTargetWorldPoint() else {
            targetWorldPoint = nil
            displayedWorldPoint = nil
            return
        }

        targetWorldPoint = point
        if resetCurrent || displayedWorldPoint == nil {
            displayedWorldPoint = point
        }
    }

    private func snappedTargetWorldPoint() -> CGPoint? {
        guard let constrained = rawConstrainedWorldPoint else { return nil }
        return snappedRoutePoint(constrained) ?? constrained
    }

    private func snappedRoutePoint(_ point: CGPoint) -> CGPoint? {
        let routePoints = currentRouteWorldPoints()
        return FloorNavigationMapMath.projectedPointOnRoute(
            routePoints: routePoints,
            currentPoint: point
        )
    }

    private var rawConstrainedWorldPoint: CGPoint? {
        guard let currentPosition,
              let x = currentPosition.x,
              let y = currentPosition.y else { return nil }
        let rawPoint = CGPoint(x: x, y: y)
        return FloorNavigationMapMath.constrainedPoint(
            rawPoint,
            polygonRings: polygonRings,
            bounds: floorMap?.bounds
        )
    }

    private func displayedMapBearingDegrees() -> Float? {
        currentMapBearingDegrees ?? targetMapBearingDegrees ?? resolvedMapBearingDegrees()
    }

    private func updateMapBearingTarget(resetCurrent: Bool) {
        guard let bearing = resolvedMapBearingDegrees() else {
            targetMapBearingDegrees = nil
            currentMapBearingDegrees = nil
            return
        }

        targetMapBearingDegrees = bearing
        if resetCurrent || currentMapBearingDegrees == nil {
            currentMapBearingDegrees = bearing
        }
    }

    private func resolvedMapBearingDegrees() -> Float? {
        // Heading-up: 사용자 정면(이동 방향)이 항상 화면 위쪽이 되도록 카메라 heading 우선.
        // heading 미가용 시에만 route → polygon 축으로 폴백.
        if let heading = currentHeadingDegrees {
            return heading
        }
        guard let targetWorldPoint else { return nil }
        let routeBearing = currentRouteBearingDegrees(at: targetWorldPoint)
        if let polygonBearing = currentNavigationPolygonBearing(at: targetWorldPoint,
                                                                referenceDegrees: routeBearing) {
            return polygonBearing
        }
        return routeBearing
    }

    private func currentRouteBearingDegrees(at currentWorldPoint: CGPoint) -> Float? {
        FloorNavigationMapMath.routeBearingDegrees(routePoints: currentRouteWorldPoints(), currentPoint: currentWorldPoint)
    }

    private func remainingDistanceMetersForCurrentPoint(_ currentWorldPoint: CGPoint) -> CGFloat? {
        FloorNavigationMapMath.remainingDistanceOnRoute(
            routePoints: currentRouteWorldPoints(),
            currentPoint: currentWorldPoint
        )
    }

    private func currentRouteWorldPoints() -> [CGPoint] {
        let floorRoutePoints: [CGPoint]
        if let floorLevel = floorMap?.floorLevel {
            floorRoutePoints = routeWorldPoints(filterFloorLevel: floorLevel)
        } else {
            floorRoutePoints = []
        }
        return floorRoutePoints.count >= 2 ? floorRoutePoints : routeWorldPoints(filterFloorLevel: nil)
    }

    private func currentNavigationPolygonBearing(at currentWorldPoint: CGPoint,
                                                 referenceDegrees: Float?) -> Float? {
        if let index = activeNavigationPolygonIndex,
           navigationPolygons.indices.contains(index),
           navigationPolygons[index].contains(currentWorldPoint) {
            if let activeNavigationPolygonBearingDegrees {
                return activeNavigationPolygonBearingDegrees
            }
            activeNavigationPolygonBearingDegrees = navigationPolygons[index].orientedBearing(referenceDegrees: referenceDegrees)
            return activeNavigationPolygonBearingDegrees
        }

        guard let index = navigationPolygons.firstIndex(where: { $0.contains(currentWorldPoint) }) else {
            activeNavigationPolygonIndex = nil
            activeNavigationPolygonBearingDegrees = nil
            return nil
        }
        activeNavigationPolygonIndex = index
        activeNavigationPolygonBearingDegrees = navigationPolygons[index].orientedBearing(referenceDegrees: referenceDegrees)
        return activeNavigationPolygonBearingDegrees
    }

    private func makeFloorFitTransform(bounds: FloorMapBounds,
                                       rect: CGRect) -> (CGPoint) -> CGPoint {
        let width = max(bounds.widthM, 0.001)
        let height = max(bounds.heightM, 0.001)
        let scale = min(rect.width / CGFloat(width), rect.height / CGFloat(height))
        let drawnWidth = CGFloat(width) * scale
        let drawnHeight = CGFloat(height) * scale
        let origin = CGPoint(
            x: rect.minX + (rect.width - drawnWidth) / 2,
            y: rect.minY + (rect.height - drawnHeight) / 2
        )

        return { world in
            CGPoint(
                x: origin.x + CGFloat(world.x - bounds.minX) * scale,
                y: origin.y + CGFloat(bounds.maxY - world.y) * scale
            )
        }
    }

    private func makeRouteAlignedTransform(bounds: FloorMapBounds,
                                           rect: CGRect,
                                           currentWorldPoint: CGPoint,
                                           bearingDegrees: Float) -> (CGPoint) -> CGPoint {
        let scale = routeAlignedScale(rect: rect, bearingDegrees: bearingDegrees)
        let anchor = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.72)
        let bearingRadians = CGFloat(bearingDegrees) * .pi / 180
        let forward = CGPoint(x: cos(bearingRadians), y: sin(bearingRadians))
        let right = CGPoint(x: sin(bearingRadians), y: -cos(bearingRadians))

        return { world in
            let dx = world.x - currentWorldPoint.x
            let dy = world.y - currentWorldPoint.y
            let screenX = dx * right.x + dy * right.y
            let screenY = -(dx * forward.x + dy * forward.y)
            return CGPoint(
                x: anchor.x + screenX * scale,
                y: anchor.y + screenY * scale
            )
        }
    }

    private func routeAlignedScale(rect: CGRect, bearingDegrees: Float) -> CGFloat {
        let baseScale: CGFloat
        if let corridorWidth = lockedCorridorReferenceWidthMeters(initialBearingDegrees: bearingDegrees) {
            baseScale = rect.width * MapDesignTokens.Metric.corridorWidthScreenRatio / corridorWidth
        } else {
            baseScale = min(rect.width, rect.height) / (2.0 * MapDesignTokens.Metric.fallbackVisibleRadiusMeters)
        }
        return baseScale * userZoomScale
    }

    private func lockedCorridorReferenceWidthMeters(initialBearingDegrees: Float) -> CGFloat? {
        if let lockedAutoScaleCorridorWidthMeters {
            return lockedAutoScaleCorridorWidthMeters
        }
        guard let width = corridorReferenceWidthMeters(bearingDegrees: initialBearingDegrees) else {
            return nil
        }
        lockedAutoScaleCorridorWidthMeters = width
        return width
    }

    private func corridorReferenceWidthMeters(bearingDegrees: Float) -> CGFloat? {
        let candidateRings = navigationPolygons.isEmpty
            ? [polygonRings]
            : navigationPolygons.map(\.rings)
        return candidateRings
            .compactMap { FloorNavigationMapMath.lateralWidthMeters(rings: $0, bearingDegrees: bearingDegrees) }
            .max()
    }

    private func screenAngleRadians(headingDegrees: Float, mapBearingDegrees: Float) -> CGFloat {
        let headingRadians = CGFloat(headingDegrees) * .pi / 180
        let bearingRadians = CGFloat(mapBearingDegrees) * .pi / 180
        let userForward = CGPoint(x: cos(headingRadians), y: sin(headingRadians))
        let mapForward = CGPoint(x: cos(bearingRadians), y: sin(bearingRadians))
        let mapRight = CGPoint(x: sin(bearingRadians), y: -cos(bearingRadians))
        let screenForward = CGPoint(
            x: userForward.x * mapRight.x + userForward.y * mapRight.y,
            y: -(userForward.x * mapForward.x + userForward.y * mapForward.y)
        )
        return atan2(screenForward.x, -screenForward.y)
    }

    // MARK: - Heading math

    /// 최단 호 delta: (target - current)를 [-180, 180] 범위로 정규화
    private func shortestArcDelta(from current: Float, to target: Float) -> Float {
        var delta = target - current
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    private func remainingDelta(current: Float?, target: Float?) -> Float {
        guard let current, let target else { return 0 }
        return abs(shortestArcDelta(from: current, to: target))
    }

    private func remainingDistance(current: CGPoint?, target: CGPoint?) -> CGFloat {
        guard let current, let target else { return 0 }
        return hypot(target.x - current.x, target.y - current.y)
    }

    // MARK: - Polygon parsing

    private static func extractMapPolygons(from raw: Data) -> [MapPolygon] {
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }

        return features.compactMap { feature -> MapPolygon? in
            let properties = feature["properties"] as? [String: Any]
            let kind = properties?["kind"] as? String
            guard let geometry = feature["geometry"] as? [String: Any] else { return nil }
            let polygonRings = rings(from: geometry)
            guard !polygonRings.isEmpty else { return nil }
            return MapPolygon(
                kind: kind,
                rings: polygonRings,
                bearingDegrees: FloorNavigationMapMath.dominantAxisDegrees(rings: polygonRings)
            )
        }
    }

    private static func displayPolygonRings(from polygons: [MapPolygon]) -> [[CGPoint]] {
        let floorUnion = polygons.filter(\.isFloorUnion).flatMap(\.rings)
        if !floorUnion.isEmpty {
            return floorUnion
        }
        return polygons.flatMap(\.rings)
    }

    private static func rings(from geometry: [String: Any]) -> [[CGPoint]] {
        guard let type = geometry["type"] as? String,
              let coordinates = geometry["coordinates"] as? [Any] else { return [] }
        switch type {
        case "Polygon":
            return coordinates.compactMap { ring in
                guard let ringArray = ring as? [Any] else { return nil }
                return points(fromGeoJSONRing: ringArray)
            }
        case "MultiPolygon":
            return coordinates.flatMap { polygon -> [[CGPoint]] in
                guard let polygonArray = polygon as? [Any] else { return [] }
                return polygonArray.compactMap { ring in
                    guard let ringArray = ring as? [Any] else { return nil }
                    return points(fromGeoJSONRing: ringArray)
                }
            }
        default:
            return []
        }
    }

    private static func points(fromGeoJSONRing ring: [Any]) -> [CGPoint] {
        ring.compactMap { item in
            guard let pair = item as? [Any],
                  pair.count >= 2,
                  let x = doubleValue(pair[0]),
                  let y = doubleValue(pair[1]) else { return nil }
            return CGPoint(x: x, y: y)
        }
    }

    private static func doubleValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

// MARK: - CALayerDelegate (dynamicOverlayLayer)
//
// UIView 자신을 sublayer.delegate로 두면 UIView의 backing layer delegate 흐름과
// 재귀가 발생해 stack overflow(EXC_BAD_ACCESS code=2)가 난다. 따라서 dynamicOverlayLayer
// 만 처리하는 별도 NSObject delegate를 둔다.
private final class OverlayLayerDrawer: NSObject, CALayerDelegate {
    weak var owner: FloorNavigationMapView?

    func draw(_ layer: CALayer, in context: CGContext) {
        guard let owner else { return }
        UIGraphicsPushContext(context)
        owner.drawCurrentPositionMarker(in: context)
        UIGraphicsPopContext()
    }

    // sublayer frame/position 변경 시 implicit animation을 끈다 — heading 회전과 충돌 방지.
    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        return NSNull()
    }
}

#if DEBUG
final class FloorNavigationMapMockViewController: UIViewController {
    private let buildingId: String
    private let floorId: String
    private let destinationName: String
    private let goal: Coordinate

    private let mapView = FloorNavigationMapView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let relocalizeButton = UIButton(type: .system)
    private let outsideButton = UIButton(type: .system)
    private let zoomContainer = UIView()
    private let zoomSlider = UISlider()

    private var floorMap: FloorMapResponse?
    private var routeSteps: [PathStep] = []
    private var routePoints: [CGPoint] = []
    private var routeSegmentLengths: [CGFloat] = []
    private var routeLength: CGFloat = 0
    private var progressM: CGFloat = 0
    private var timer: Timer?
    private var isPaused = false
    private var forceOutsidePolygon = false

    init(buildingId: String, floorId: String, destinationName: String, goal: Coordinate) {
        self.buildingId = buildingId
        self.floorId = floorId
        self.destinationName = destinationName
        self.goal = goal
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MapDesignTokens.Surface.backdropDim
        setupViews()
        loadMap()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    private func setupViews() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)

        let controls = UIStackView()
        controls.axis = .horizontal
        controls.alignment = .center
        controls.distribution = .fillEqually
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        titleLabel.text = "2D Map Mock"
        titleLabel.textColor = MapDesignTokens.Text.primary
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        statusLabel.text = "loading"
        statusLabel.textColor = MapDesignTokens.Text.onChip
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        zoomContainer.backgroundColor = MapDesignTokens.Surface.controlFill
        zoomContainer.layer.cornerRadius = 22
        zoomContainer.layer.masksToBounds = false
        zoomContainer.layer.borderWidth = 1
        zoomContainer.layer.borderColor = MapDesignTokens.Stroke.labelBorder.cgColor
        zoomContainer.layer.shadowColor = UIColor.black.cgColor
        zoomContainer.layer.shadowOpacity = 0.10
        zoomContainer.layer.shadowRadius = 8
        zoomContainer.layer.shadowOffset = CGSize(width: 0, height: 3)
        zoomContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoomContainer)

        zoomSlider.minimumValue = MapDesignTokens.Metric.mapZoomMinimum
        zoomSlider.maximumValue = MapDesignTokens.Metric.mapZoomMaximum
        zoomSlider.value = MapDesignTokens.Metric.mapZoomDefault
        zoomSlider.minimumTrackTintColor = MapDesignTokens.Accent.route
        zoomSlider.maximumTrackTintColor = MapDesignTokens.Stroke.labelBorder
        zoomSlider.thumbTintColor = MapDesignTokens.Text.primary
        zoomSlider.accessibilityLabel = "2D map zoom"
        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        zoomSlider.addTarget(self, action: #selector(onZoomChanged(_:)), for: .valueChanged)
        zoomContainer.addSubview(zoomSlider)

        configureButton(playButton, title: "Pause", action: #selector(onPlayTapped))
        configureButton(relocalizeButton, title: "Reloc", action: #selector(onRelocalizeTapped))
        configureButton(outsideButton, title: "Outside", action: #selector(onOutsideTapped))

        let closeButton = UIButton(type: .system)
        configureButton(closeButton, title: "Close", action: #selector(onCloseTapped))

        [playButton, relocalizeButton, outsideButton, closeButton].forEach(controls.addArrangedSubview)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            controls.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -12),
            controls.heightAnchor.constraint(equalToConstant: 44),

            zoomContainer.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -16),
            zoomContainer.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            zoomContainer.widthAnchor.constraint(equalToConstant: 148),
            zoomContainer.heightAnchor.constraint(equalToConstant: 44),

            zoomSlider.leadingAnchor.constraint(equalTo: zoomContainer.leadingAnchor, constant: 14),
            zoomSlider.trailingAnchor.constraint(equalTo: zoomContainer.trailingAnchor, constant: -14),
            zoomSlider.centerYAnchor.constraint(equalTo: zoomContainer.centerYAnchor),

            mapView.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 64),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
        ])
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(MapDesignTokens.Text.primary, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.backgroundColor = MapDesignTokens.Surface.floorFill
        button.layer.cornerRadius = 8
        button.layer.masksToBounds = true
        button.layer.borderColor = MapDesignTokens.Stroke.floorOutline.cgColor
        button.layer.borderWidth = 1
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func onZoomChanged(_ sender: UISlider) {
        mapView.setZoomScale(CGFloat(sender.value))
    }

    private func loadMap() {
        guard !floorId.isEmpty else {
            applyMap(makeFallbackMap())
            return
        }

        NetworkManager.shared.fetchFloorMap(floorId: floorId, areaId: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let map):
                    self.applyMap(map)
                case .failure(let error):
                    print("[FloorMapMock] fetch failed: \(error)")
                    self.applyMap(self.makeFallbackMap())
                }
            }
        }
    }

    private func applyMap(_ map: FloorMapResponse) {
        floorMap = map
        routePoints = makeMockRoutePoints(map: map)
        routeSteps = routePoints.enumerated().map { index, point in
            PathStep(
                stepNumber: index + 1,
                floorLevel: map.floorLevel,
                position: Position(x: Double(point.x), y: Double(point.y), z: 0),
                instruction: index == routePoints.count - 1 ? "도착" : "진행",
                nodeId: nil
            )
        }
        rebuildRouteLengths()
        progressM = 0
        render(reconfigure: true)
        startTimer()
    }

    private func makeMockRoutePoints(map: FloorMapResponse) -> [CGPoint] {
        let nodesById = map.nodes.reduce(into: [String: FloorMapNode]()) { result, node in
            result[node.id] = node
        }

        if let firstEdge = map.edges.max(by: { $0.lengthM < $1.lengthM }),
           let start = nodesById[firstEdge.fromId],
           let end = nodesById[firstEdge.toId] {
            var ids = [start.id, end.id]
            var previous = start.id
            var current = end.id

            for _ in 0..<5 {
                guard let nextEdge = map.edges
                    .filter({ $0.fromId == current || $0.toId == current })
                    .filter({ edge in
                        let other = edge.fromId == current ? edge.toId : edge.fromId
                        return other != previous
                    })
                    .max(by: { $0.lengthM < $1.lengthM }) else { break }
                let next = nextEdge.fromId == current ? nextEdge.toId : nextEdge.fromId
                ids.append(next)
                previous = current
                current = next
            }

            let points = ids.compactMap { id -> CGPoint? in
                guard let node = nodesById[id] else { return nil }
                return CGPoint(x: node.x, y: node.y)
            }
            if points.count >= 2 {
                return points
            }
        }

        let minX = CGFloat(map.bounds.minX)
        let minY = CGFloat(map.bounds.minY)
        let maxX = CGFloat(map.bounds.maxX)
        let maxY = CGFloat(map.bounds.maxY)
        return [
            CGPoint(x: minX + (maxX - minX) * 0.18, y: minY + (maxY - minY) * 0.22),
            CGPoint(x: minX + (maxX - minX) * 0.68, y: minY + (maxY - minY) * 0.22),
            CGPoint(x: minX + (maxX - minX) * 0.68, y: minY + (maxY - minY) * 0.82)
        ]
    }

    private func rebuildRouteLengths() {
        routeSegmentLengths = []
        routeLength = 0
        guard routePoints.count >= 2 else { return }
        for index in 0..<(routePoints.count - 1) {
            let length = hypot(routePoints[index + 1].x - routePoints[index].x,
                               routePoints[index + 1].y - routePoints[index].y)
            routeSegmentLengths.append(length)
            routeLength += length
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard !isPaused, routeLength > 0 else { return }
        progressM += 0.035
        if progressM > routeLength {
            progressM = 0
        }
        render(reconfigure: false)
    }

    private func render(reconfigure: Bool) {
        guard let floorMap else { return }
        let sample = sampleRoute(progressM: progressM)
        var point = sample.point
        if forceOutsidePolygon {
            point = CGPoint(x: CGFloat(floorMap.bounds.maxX) + 4.0, y: sample.point.y)
        }
        let position = Position(x: Double(point.x), y: Double(point.y), z: 0)
        if reconfigure {
            mapView.configure(map: floorMap,
                              routeSteps: routeSteps,
                              currentPosition: position,
                              currentHeadingDegrees: sample.bearingDegrees,
                              destinationName: destinationName,
                              destinationWorldPoint: routePoints.last)
        } else {
            mapView.updateCurrentPosition(position, headingDegrees: sample.bearingDegrees)
        }
        statusLabel.text = String(format: "progress %.1fm / %.1fm  heading %.0f",
                                  Double(progressM),
                                  Double(routeLength),
                                  Double(sample.bearingDegrees))
    }

    private func sampleRoute(progressM: CGFloat) -> (point: CGPoint, bearingDegrees: Float) {
        guard routePoints.count >= 2 else { return (.zero, 0) }
        var remaining = progressM
        for index in 0..<routeSegmentLengths.count {
            let length = max(routeSegmentLengths[index], 0.001)
            if remaining <= length {
                let start = routePoints[index]
                let end = routePoints[index + 1]
                let t = remaining / length
                let point = CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                )
                let bearing = Float(atan2(end.y - start.y, end.x - start.x) * 180 / .pi)
                return (point, bearing)
            }
            remaining -= length
        }
        let start = routePoints[routePoints.count - 2]
        let end = routePoints[routePoints.count - 1]
        return (end, Float(atan2(end.y - start.y, end.x - start.x) * 180 / .pi))
    }

    private func makeFallbackMap() -> FloorMapResponse {
        let polygon = """
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"kind":"floor_union"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[18,0],[18,5],[10,5],[10,18],[4,18],[4,5],[0,5],[0,0]]]}}]}
        """
        let nodes = [
            FloorMapNode(id: "n0", type: "corridor", x: 2, y: 2.5, z: 0, label: nil, category: nil, connector: nil),
            FloorMapNode(id: "n1", type: "corridor", x: 14, y: 2.5, z: 0, label: nil, category: nil, connector: nil),
            FloorMapNode(id: "n2", type: "corridor", x: 7, y: 2.5, z: 0, label: nil, category: nil, connector: nil),
            FloorMapNode(id: "n3", type: "corridor", x: 7, y: 15, z: 0, label: nil, category: nil, connector: nil),
            FloorMapNode(id: "p1", type: "poi", x: 15.5, y: 2.5, z: 0, label: "POI 15", category: nil, connector: nil),
            FloorMapNode(id: "s1", type: "passage_stairs", x: 7, y: 16, z: 0, label: "St", category: nil, connector: FloorMapConnector(type: "stairs", key: nil))
        ]
        return FloorMapResponse(
            floorId: floorId.isEmpty ? "mock-floor" : floorId,
            buildingId: buildingId.isEmpty ? "mock-building" : buildingId,
            scanId: "mock-scan",
            floorLevel: 1,
            floorName: "1F",
            buildJobId: "mock",
            coordinateSystem: FloorMapCoordinateSystem(frame: "mock", description: nil),
            bounds: FloorMapBounds(minX: 0, minY: 0, maxX: 18, maxY: 18, widthM: 18, heightM: 18),
            polygon: PolygonRaw(raw: Data(polygon.utf8)),
            nodes: nodes,
            edges: [
                FloorMapEdge(id: "e0", fromId: "n0", toId: "n1", lengthM: 12, type: "corridor"),
                FloorMapEdge(id: "e1", fromId: "n2", toId: "n3", lengthM: 12.5, type: "corridor"),
                FloorMapEdge(id: "e2", fromId: "n1", toId: "p1", lengthM: 1.5, type: "poi"),
                FloorMapEdge(id: "e3", fromId: "n3", toId: "s1", lengthM: 1, type: "passage")
            ],
            etag: "mock",
            destinations: nil,
            connectors: nil
        )
    }

    @objc private func onPlayTapped() {
        isPaused.toggle()
        playButton.setTitle(isPaused ? "Play" : "Pause", for: .normal)
    }

    @objc private func onRelocalizeTapped() {
        guard routeLength > 0 else { return }
        progressM = min(routeLength, max(0, progressM + routeLength * 0.22))
        render(reconfigure: true)
    }

    @objc private func onOutsideTapped() {
        forceOutsidePolygon.toggle()
        outsideButton.setTitle(forceOutsidePolygon ? "Inside" : "Outside", for: .normal)
        render(reconfigure: true)
    }

    @objc private func onCloseTapped() {
        dismiss(animated: true)
    }
}
#endif

class ARNavigationViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {

    var buildingId: String = ""
    var floorId: String = ""
    var destinationName: String = ""
    var destinationId: String = ""
    var goal: Coordinate = Coordinate(x: 0, y: 0, z: 0)
    var userCurrentFloorId: String? = nil
    var userCurrentFloorLevel: Int? = nil

    var sceneView: ARSCNView!
    var locateButton: UIButton!
    var closeButton: UIButton!
    var scanningOverlayView: UIView!
    var captureSpinner: UIActivityIndicatorView!
    var captureStatusLabel: UILabel!
    var scanCompleteBadge: UIView!
    var scanFailedView: UIView!
    var scanFailedLabel: UILabel!
    var arrivalBadge: UIView!

    var hudContainerView: UIView!
    // Phase 6: 기존 HUD 멤버는 신규 카드 UX 흐름에서 미사용 — 옵셔널화로 nil 안전
    var destinationPillView: UIView?
    var destinationLabel: UILabel?
    var remainingDistanceLabel: UILabel?
    var instructionCardView: UIView?
    var instructionLabel: UILabel?

    // Phase 6: 신규 목적지 pill 내부 컴포넌트
    // — Phase 6 후속: nav 카드(setupNavCard) 도입으로 destination pill 폐기. 옵셔널 유지(updateNavigationStep 의 옵셔널 체이닝용).
    var destinationIconCircle: UIView?
    var destinationFloorLabel: UILabel?
    var destinationNameLabel: UILabel?

    // Phase 6 후속: 상단 nav 카드 (좌측 정렬, 다음 액션 거리/방향 표시)
    private var navCardView: UIView!
    private var navCardIconView: UIImageView!
    private var navCardDistanceLabel: UILabel!
    private var navCardDirectionLabel: UILabel!

    // nav 카드 하단 보조 카드 — 목적지 이름 + 총 거리
    private var navCardSubView: UIView!
    private var navCardSubNameLabel: UILabel!
    private var navCardSubDistanceLabel: UILabel!

    // Phase 6: 하단 거리/시간 캡슐
    var remainingCapsuleView: UIView!
    var remainingCapsuleLabel: UILabel!

    // 하단 2D 내비게이션 맵
    private var floorNavigationContainerView: UIView!
    private var floorNavigationMapView: FloorNavigationMapView!
    private var floorNavigationGrabberView: UIView!
    private var floorNavigationCollapsedHeightConstraint: NSLayoutConstraint!
    private var floorNavigationExpandedHeightConstraint: NSLayoutConstraint!
    private var isFloorNavigationExpanded = false
    /// 핀치 줌 시작 시점의 베이스 줌 — `.began` 에서 캐시, `.changed` 에서 scale 누적.
    private var floorNavigationZoomBase: CGFloat = CGFloat(MapDesignTokens.Metric.mapZoomDefault)

    // Phase 6: 재측정 버튼 라벨 상태 추적 — 첫 측위 성공 전엔 "주변 스캔", 이후 "재측정".
    private var hasLocalizedSuccessfully = false

    var routeCalculatingView: UIView!
    var routeCalculatingLabel: UILabel!

    var floorTransitionOverlayView: UIView!
    var floorTransitionRestartButton: UIButton!

    // Phase 5: 방향 안내 UI
    private var headingOverlayView: HeadingAlignmentOverlayView!
    private var turnCardView: TurnCardView!

    // Phase 6: AR 공간 3D 회전 화살표 (Logic 의 updateTurnArrow delegate 로 갱신)
    // — AR 마커 시스템(ARMarkerController) 도입으로 dead path. updateTurnArrow 는 no-op.
    private var turnArrowNode: SCNNode?
    private var turnArrowStepIndex: Int?

    // AR 마커 라이프사이클 manager — DistanceMarker / NextArrow 단일 마커 표시.
    private let markerController = ARMarkerController()

    // Phase 7: SuperPoint 디버그 시각화 (DEBUG 빌드 전용)
    #if DEBUG
    private var superPointDebug: SuperPointDebugController?
    #endif

    private var logic: ARNavigationLogic!

    override func viewDidLoad() {
        super.viewDidLoad()

        logic = ARNavigationLogic(
            buildingId: buildingId,
            floorId: floorId,
            destinationName: destinationName,
            destinationId: destinationId,
            goal: goal,
            userCurrentFloorId: userCurrentFloorId,
            userCurrentFloorLevel: userCurrentFloorLevel
        )

        setupARView()
        setupRelocalizeButton()
        setupScanningOverlay()
        setupScanCompleteBadge()
        setupScanFailedView()
        setupArrivalBadge()
        // Phase 6: setupHUD() 폐기 → 신규 setup 으로 대체
        // Phase 6 후속: nav-bar 분해 → 미니맵 위 nav 카드(setupNavCard) + 독립 closeButton(setupCloseButton)
        setupHudContainer()
        setupRemainingCapsule()
        setupFloorNavigationMap()   // navCard 의 부모(floorNavigationContainerView) 먼저 생성
        setupNavCard()
        setupCloseButton()
        setupRouteCalculatingView()
        setupFloorTransitionOverlay()
        // Phase 8: setupHeadingOverlay() / setupTurnCard() 호출 제거 — keyframe 단계 추적 모델
        //          (checkpoint 1개) 로 대체. 함수 본체는 dead path 로 보존.

        logic.delegate = self
        logic.arSession = sceneView.session
        logic.scene = sceneView.scene
        // Phase 8: setGuidanceDelegate 호출 제거 — headingOverlayView/turnCardView 가 IUO 인데
        //          setupHeadingOverlay/setupTurnCard 미호출이라 nil. delegate 메서드 호출 시 강제 언래핑 크래시.
        //          GuidanceDirector 인스턴스는 보존(향후 Phase 5 부활 가능성). delegate 미등록 → no-op.
        // TODO(phase8+): GuidanceDirector 인스턴스 자체 옵셔널화 또는 폐기.

        // Phase 7: SuperPoint extractor.
        // Phase 6 UI 정리: 상단 SP / DUMP 디버그 버튼은 사용자 요청으로 비활성.
        // SuperPointDebugController 인스턴스화 자체를 끔 — keypoint 오버레이/추론 시간/dump 버튼 모두 노출 X.
        logic.setupSuperPointExtractor()

        // Phase 8: 화면 더블탭 → 측위 재시작 (무한 테스트용)
        setupRetapGestureForTesting()

        // Phase 6: 닫기 / 재측정 버튼이 scanningOverlay·floorTransitionOverlay 등에 가려지지 않도록 항상 최상단으로.
        // Phase 6 후속: nav 카드·closeButton 모두 self.view 직속 좌·우 상단 배치.
        self.view.bringSubviewToFront(hudContainerView)
        hudContainerView.bringSubviewToFront(floorNavigationContainerView)
        self.view.bringSubviewToFront(navCardView)
        self.view.bringSubviewToFront(navCardSubView)
        self.view.bringSubviewToFront(closeButton)
        self.view.bringSubviewToFront(locateButton)

        // AR 마커 시스템 부모 노드 등록 — Logic 이 updateMarkers 발신 시 controller 가 직접 노드 추가.
        markerController.attach(to: sceneView.scene.rootNode)
        // PathChevron 시스템 부모 노드 등록 — Logic 이 drawPathFromSteps 시 chevron 노드를 직접 추가.
        logic.attachChevronParent(sceneView.scene.rootNode)
    }

    /// 화면 더블탭 시 측위 재시작 — 무한 테스트용. logic.startLocalizationFlow() 가 idempotent.
    private func setupRetapGestureForTesting() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onSceneRetapped))
        tap.numberOfTapsRequired = 2
        sceneView.addGestureRecognizer(tap)
    }

    @objc private func onSceneRetapped() {
        logic.startLocalizationFlow()
    }

    // MARK: - UI 세팅

    private func setupARView() {
        sceneView = ARSCNView(frame: self.view.bounds)
        self.view.addSubview(sceneView)
        sceneView.delegate = self
        sceneView.showsStatistics = false
        sceneView.autoenablesDefaultLighting = true
    }

    /// Phase 6 후속: 미니맵 컨테이너 위에 띄우는 nav 카드 (좌측 정렬).
    /// self.view 자식, safe area 좌상단(leading+16 / top+12). 좌측 아이콘 + 큰 거리 라벨 + 하단 방향 라벨.
    private func setupNavCard() {
        let card = UIView()
        card.backgroundColor = NavCardStyle.background
        card.layer.cornerRadius = NavCardStyle.cornerRadius
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.25
        card.layer.shadowRadius = 12
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.layer.masksToBounds = false
        card.translatesAutoresizingMaskIntoConstraints = false
        card.isHidden = true
        self.view.addSubview(card)
        navCardView = card

        let iconView = UIImageView(image: actionImage(for: .straight))
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(iconView)
        navCardIconView = iconView

        let distanceLabel = UILabel()
        distanceLabel.text = "—m"
        distanceLabel.textColor = .white
        distanceLabel.font = .systemFont(ofSize: NavCardStyle.distanceFontSize, weight: .bold)
        distanceLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(distanceLabel)
        navCardDistanceLabel = distanceLabel

        let directionLabel = UILabel()
        directionLabel.text = "직진"
        directionLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        directionLabel.font = .systemFont(ofSize: NavCardStyle.directionFontSize, weight: .regular)
        directionLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(directionLabel)
        navCardDirectionLabel = directionLabel

        let safeArea = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: NavCardStyle.paddingLeft),
            iconView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: NavCardStyle.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: NavCardStyle.iconSize),

            distanceLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: NavCardStyle.iconGap),
            distanceLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: NavCardStyle.paddingTop),
            distanceLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -NavCardStyle.paddingRight),

            directionLabel.leadingAnchor.constraint(equalTo: distanceLabel.leadingAnchor),
            directionLabel.topAnchor.constraint(equalTo: distanceLabel.bottomAnchor, constant: 2),
            directionLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -NavCardStyle.paddingRight),
            directionLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -NavCardStyle.paddingBottom),
        ])

        // 보조 카드: 목적지 이름 + 총 거리. nav 카드 하단에 부착, 좌측 정렬.
        let sub = UIView()
        sub.backgroundColor = NavCardStyle.background
        sub.layer.cornerRadius = 10
        sub.layer.shadowColor = UIColor.black.cgColor
        sub.layer.shadowOpacity = 0.25
        sub.layer.shadowRadius = 12
        sub.layer.shadowOffset = CGSize(width: 0, height: 4)
        sub.layer.masksToBounds = false
        sub.translatesAutoresizingMaskIntoConstraints = false
        sub.isHidden = true
        self.view.addSubview(sub)
        navCardSubView = sub

        let nameLabel = UILabel()
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        sub.addSubview(nameLabel)
        navCardSubNameLabel = nameLabel

        let dotLabel = UILabel()
        dotLabel.text = "·"
        dotLabel.font = .systemFont(ofSize: 13)
        dotLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        dotLabel.translatesAutoresizingMaskIntoConstraints = false
        sub.addSubview(dotLabel)

        let distLabel = UILabel()
        distLabel.font = .systemFont(ofSize: 13, weight: .regular)
        distLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        distLabel.translatesAutoresizingMaskIntoConstraints = false
        sub.addSubview(distLabel)
        navCardSubDistanceLabel = distLabel

        NSLayoutConstraint.activate([
            sub.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 4),
            sub.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: sub.leadingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: sub.centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140),
            dotLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            dotLabel.centerYAnchor.constraint(equalTo: sub.centerYAnchor),
            distLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: 6),
            distLabel.centerYAnchor.constraint(equalTo: sub.centerYAnchor),
            distLabel.trailingAnchor.constraint(equalTo: sub.trailingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: sub.topAnchor, constant: 6),
            nameLabel.bottomAnchor.constraint(equalTo: sub.bottomAnchor, constant: -6),
        ])
    }

    /// Phase 6 후속: 독립 closeButton — 안전영역 top-trailing 모서리, blur 백드롭, 44pt 원형.
    private func setupCloseButton() {
        closeButton = UIButton(type: .system)
        let assetIcon = UIImage(named: "closeThick")?.withRenderingMode(.alwaysTemplate)
        let fallbackConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let fallback = UIImage(systemName: "xmark", withConfiguration: fallbackConfig)
        closeButton.setImage(assetIcon ?? fallback, for: .normal)
        closeButton.imageView?.contentMode = .scaleAspectFit
        closeButton.imageEdgeInsets = UIEdgeInsets(top: 11, left: 11, bottom: 11, right: 11)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        closeButton.layer.cornerRadius = 22
        closeButton.layer.masksToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(onCloseButtonTapped), for: .touchUpInside)

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 22
        blur.layer.masksToBounds = true
        closeButton.insertSubview(blur, at: 0)

        self.view.addSubview(closeButton)

        let safeArea = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            blur.topAnchor.constraint(equalTo: closeButton.topAnchor),
            blur.leadingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: closeButton.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: closeButton.bottomAnchor),
        ])
    }

    @objc private func onCloseButtonTapped() {
        dismiss(animated: true)
    }

    private func setupRelocalizeButton() {
        // Phase 6: 하단 중앙 캡슐 (52pt 높이, blur, viewfinder + "재측정")
        // 인스턴스는 기존 locateButton 그대로 재사용.
        locateButton = UIButton(type: .system)
        // 초기 default — 첫 측위 성공(setLocateButtonVisible(true)) 시 "재측정" 으로 전환.
        locateButton.setTitle("주변 스캔", for: .normal)
        locateButton.setTitleColor(.white, for: .normal)
        locateButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        let assetIcon = UIImage(named: "scan")?.withRenderingMode(.alwaysTemplate)
        let fallbackConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let fallback = UIImage(systemName: "viewfinder", withConfiguration: fallbackConfig)
        let icon = assetIcon ?? fallback
        locateButton.setImage(icon, for: .normal)
        locateButton.imageView?.contentMode = .scaleAspectFit
        locateButton.tintColor = .white
        locateButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)
        locateButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: -6)
        locateButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        locateButton.backgroundColor = UIColor(white: 0.0, alpha: 0.55)
        locateButton.layer.cornerRadius = 26
        locateButton.layer.masksToBounds = true
        locateButton.layer.borderWidth = 1
        locateButton.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        locateButton.translatesAutoresizingMaskIntoConstraints = false
        locateButton.addTarget(self, action: #selector(onLocateButtonTapped), for: .touchUpInside)

        // blur 백드롭
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 26
        blur.layer.masksToBounds = true
        locateButton.insertSubview(blur, at: 0)

        self.view.addSubview(locateButton)

        let safeArea = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            locateButton.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -16),
            locateButton.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            locateButton.heightAnchor.constraint(equalToConstant: 52),

            blur.topAnchor.constraint(equalTo: locateButton.topAnchor),
            blur.leadingAnchor.constraint(equalTo: locateButton.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: locateButton.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: locateButton.bottomAnchor),
        ])
    }

    private func setupScanningOverlay() {
        let bounds = self.view.bounds

        scanningOverlayView = UIView(frame: bounds)
        scanningOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        scanningOverlayView.isHidden = true
        scanningOverlayView.isUserInteractionEnabled = false

        // 스캔 아이콘 (SF Symbol)
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 60, weight: .thin)
        let iconImage = UIImage(systemName: "viewfinder", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.frame = CGRect(x: bounds.midX - 40, y: bounds.midY - 120, width: 80, height: 80)

        // 메인 안내 문구
        let titleLabel = UILabel()
        titleLabel.text = "주변을 천천히 둘러보세요"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.frame = CGRect(x: 20, y: bounds.midY - 20, width: bounds.width - 40, height: 30)

        // 보조 안내 문구 (정적)
        let subtitleLabel = UILabel()
        subtitleLabel.text = "스마트폰을 들고 천천히 움직여 보세요."
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.frame = CGRect(x: 20, y: bounds.midY + 16, width: bounds.width - 40, height: 40)

        // 무한 회전 spinner — phase 가 nil 이 아닐 때 동작.
        captureSpinner = UIActivityIndicatorView(style: .large)
        captureSpinner.color = .white
        captureSpinner.hidesWhenStopped = true
        captureSpinner.frame = CGRect(x: bounds.midX - 18, y: bounds.midY + 70, width: 36, height: 36)

        // phase 상태 라벨 — .localizing 시 "측위 중..." 표시. .capturing 시엔 빈 텍스트(스피너만).
        captureStatusLabel = UILabel()
        captureStatusLabel.text = ""
        captureStatusLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        captureStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        captureStatusLabel.textAlignment = .center
        captureStatusLabel.isHidden = true
        captureStatusLabel.frame = CGRect(x: 20, y: bounds.midY + 114, width: bounds.width - 40, height: 20)

        scanningOverlayView.addSubview(iconView)
        scanningOverlayView.addSubview(titleLabel)
        scanningOverlayView.addSubview(subtitleLabel)
        scanningOverlayView.addSubview(captureSpinner)
        scanningOverlayView.addSubview(captureStatusLabel)
        self.view.addSubview(scanningOverlayView)
    }

    private func setupScanCompleteBadge() {
        let bounds = self.view.bounds

        // 반투명 어두운 배경
        scanCompleteBadge = UIView(frame: bounds)
        scanCompleteBadge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        scanCompleteBadge.isHidden = true
        scanCompleteBadge.isUserInteractionEnabled = false

        // 필(pill) 형태 배지
        let pill = UIView()
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        pill.layer.cornerRadius = 22
        pill.translatesAutoresizingMaskIntoConstraints = false
        scanCompleteBadge.addSubview(pill)

        // 체크마크 아이콘
        let checkConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let checkImage = UIImage(systemName: "checkmark.circle.fill", withConfiguration: checkConfig)
        let checkView = UIImageView(image: checkImage)
        checkView.tintColor = .systemBlue
        checkView.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(checkView)

        // "스캔 완료" 텍스트
        let label = UILabel()
        label.text = "스캔 완료"
        label.textColor = .darkText
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        self.view.addSubview(scanCompleteBadge)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: scanCompleteBadge.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: scanCompleteBadge.bottomAnchor, constant: -bounds.height * 0.35),
            pill.heightAnchor.constraint(equalToConstant: 44),

            checkView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            checkView.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 22),
            checkView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: checkView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -20),
        ])
    }

    private func setupScanFailedView() {
        let bounds = self.view.bounds

        scanFailedView = UIView(frame: bounds)
        scanFailedView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        scanFailedView.isHidden = true
        scanFailedView.isUserInteractionEnabled = false

        // 실패 아이콘
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        let iconImage = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .systemOrange
        iconView.contentMode = .scaleAspectFit
        iconView.frame = CGRect(x: bounds.midX - 25, y: bounds.midY - 80, width: 50, height: 50)

        // 실패 메시지
        scanFailedLabel = UILabel()
        scanFailedLabel.textColor = .white
        scanFailedLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        scanFailedLabel.textAlignment = .center
        scanFailedLabel.numberOfLines = 0
        scanFailedLabel.frame = CGRect(x: 20, y: bounds.midY - 16, width: bounds.width - 40, height: 60)

        scanFailedView.addSubview(iconView)
        scanFailedView.addSubview(scanFailedLabel)
        self.view.addSubview(scanFailedView)
    }

    private func setupArrivalBadge() {
        let bounds = self.view.bounds

        // 도착 dim 컨테이너 — 검정 0.55 dim 으로 시선을 pill/버튼에 집중.
        // hit-test 는 자식(pill 영역 외 거의 transparent) 외엔 pass-through.
        arrivalBadge = HUDPassthroughView(frame: bounds)
        arrivalBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        arrivalBadge.isHidden = true
        arrivalBadge.isUserInteractionEnabled = true
        arrivalBadge.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // 필(pill) 형태 배지
        let pill = UIView()
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        pill.layer.cornerRadius = 22
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOpacity = 0.15
        pill.layer.shadowRadius = 6
        pill.layer.shadowOffset = CGSize(width: 0, height: 2)
        pill.translatesAutoresizingMaskIntoConstraints = false
        arrivalBadge.addSubview(pill)

        // 위치 핀 아이콘
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let iconImage = UIImage(systemName: "mappin.circle.fill", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .systemRed
        iconView.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(iconView)

        // "목적지 도착" 텍스트
        let label = UILabel()
        label.text = "목적지 도착"
        label.textColor = .darkText
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.addSubview(label)

        // 확인 버튼 — pill 아래 표시
        let confirmButton: UIButton
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.filled()
            config.title = "확인"
            config.baseBackgroundColor = .systemBlue
            config.baseForegroundColor = .white
            config.cornerStyle = .capsule
            confirmButton = UIButton(configuration: config)
        } else {
            confirmButton = UIButton(type: .system)
            confirmButton.setTitle("확인", for: .normal)
            confirmButton.setTitleColor(.white, for: .normal)
            confirmButton.backgroundColor = .systemBlue
            confirmButton.layer.cornerRadius = 22
            confirmButton.layer.masksToBounds = true
        }
        confirmButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.addTarget(self, action: #selector(onArrivalConfirmTapped), for: .touchUpInside)
        arrivalBadge.addSubview(confirmButton)

        self.view.addSubview(arrivalBadge)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: arrivalBadge.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: arrivalBadge.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 44),
            // pill 가로 폭은 자식(iconView + label) intrinsic content + 좌우 inset 으로 결정 — 모호한 width 0 방지
            pill.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -16),
            pill.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 20),

            iconView.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            confirmButton.centerXAnchor.constraint(equalTo: arrivalBadge.centerXAnchor),
            confirmButton.topAnchor.constraint(equalTo: pill.bottomAnchor, constant: 16),
            confirmButton.widthAnchor.constraint(equalToConstant: 140),
            confirmButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        _ = bounds  // suppress unused-warning
    }

    /// 도착 pill 의 "확인" 버튼 콜백 — AR/타이머 정리 후 root(네이버 지도)로 복귀.
    @objc private func onArrivalConfirmTapped() {
        arrivalBadge.isHidden = true

        logic.stopCapture()
        logic.stopArrivalCheck()
        logic.stopPathProgressTracking()
        logic.stopPeriodicRelocalize()
        markerController.hideAll()
        sceneView.session.pause()

        let presentingNav = (presentingViewController as? UINavigationController)
            ?? presentingViewController?.navigationController
        if presentingViewController != nil {
            dismiss(animated: true) {
                presentingNav?.popToRootViewController(animated: false)
            }
        } else {
            navigationController?.popToRootViewController(animated: true)
        }
    }

    // MARK: - Phase 6 신규 HUD setup (setupHUD 분해)

    private func setupHudContainer() {
        let bounds = self.view.bounds
        // Phase 6: PassthroughView 로 transparent 영역은 sceneView 의 더블탭 제스처에 위임.
        // 자식 버튼은 정상 터치 수신.
        hudContainerView = HUDPassthroughView(frame: bounds)
        hudContainerView.isUserInteractionEnabled = true
        hudContainerView.isHidden = true
        self.view.addSubview(hudContainerView)
    }

    // Phase 6 후속: setupDestinationPill 폐기 — 미니맵 위 nav 카드(setupNavCard) 가 거리/방향을 직접 표시.
    // destinationPillView / destinationIconCircle / destinationFloorLabel / destinationNameLabel 옵셔널은
    // updateNavigationStep 의 안전한 옵셔널 체이닝용으로 유지(현재 모두 nil).

    /// docs Phase 6 §5 — 하단 거리/시간 캡슐 (44pt 높이, blur, attributed).
    private func setupRemainingCapsule() {
        let capsule = UIView()
        capsule.backgroundColor = UIColor(white: 0.0, alpha: 0.55)
        capsule.layer.cornerRadius = 22
        capsule.layer.masksToBounds = true
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.isHidden = true
        hudContainerView.addSubview(capsule)
        remainingCapsuleView = capsule

        // blur 백드롭
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 22
        blur.layer.masksToBounds = true
        capsule.insertSubview(blur, at: 0)

        remainingCapsuleLabel = UILabel()
        remainingCapsuleLabel.text = "남은 거리 —"
        remainingCapsuleLabel.textColor = .white
        remainingCapsuleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        remainingCapsuleLabel.textAlignment = .center
        remainingCapsuleLabel.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(remainingCapsuleLabel)

        let safeArea = self.view.safeAreaLayoutGuide
        // 재측정 버튼 위 16pt — locateButton 은 setupRelocalizeButton 에서 생성됨
        NSLayoutConstraint.activate([
            capsule.heightAnchor.constraint(equalToConstant: 44),
            capsule.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            capsule.bottomAnchor.constraint(equalTo: locateButton.topAnchor, constant: -16),

            blur.topAnchor.constraint(equalTo: capsule.topAnchor),
            blur.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),

            remainingCapsuleLabel.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 18),
            remainingCapsuleLabel.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -18),
            remainingCapsuleLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
        ])
    }

    private func setupFloorNavigationMap() {
        let container = UIView()
        container.backgroundColor = MapDesignTokens.Surface.backdropDim
        container.layer.cornerRadius = MapDesignTokens.Metric.containerTopCornerRadius
        container.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        container.layer.cornerCurve = .continuous
        container.layer.masksToBounds = true
        container.layer.borderWidth = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isUserInteractionEnabled = true
        container.isHidden = true
        hudContainerView.addSubview(container)
        floorNavigationContainerView = container

        floorNavigationMapView = FloorNavigationMapView()
        floorNavigationMapView.translatesAutoresizingMaskIntoConstraints = false
        floorNavigationMapView.isUserInteractionEnabled = false
        container.addSubview(floorNavigationMapView)

        let grabber = UIView()
        grabber.backgroundColor = MapDesignTokens.Surface.grabber
        grabber.layer.cornerRadius = 2
        grabber.layer.masksToBounds = true
        grabber.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grabber)
        floorNavigationGrabberView = grabber

        floorNavigationCollapsedHeightConstraint = container.heightAnchor.constraint(
            equalTo: self.view.heightAnchor,
            multiplier: MapDesignTokens.Metric.containerHeightRatio
        )
        floorNavigationExpandedHeightConstraint = container.heightAnchor.constraint(equalTo: self.view.heightAnchor)
        floorNavigationExpandedHeightConstraint.isActive = false

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: hudContainerView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: hudContainerView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            floorNavigationCollapsedHeightConstraint,

            floorNavigationMapView.topAnchor.constraint(equalTo: container.topAnchor),
            floorNavigationMapView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            floorNavigationMapView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            floorNavigationMapView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            grabber.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            grabber.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 4),
        ])

        // 위/아래 swipe 제스처 — collapsed ↔ expanded 토글. expand 버튼 폐기 후 도입.
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(onFloorNavigationSwipeUp))
        swipeUp.direction = .up
        container.addGestureRecognizer(swipeUp)

        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(onFloorNavigationSwipeDown))
        swipeDown.direction = .down
        container.addGestureRecognizer(swipeDown)

        // 핀치 줌 — zoom slider 폐기 후 도입. floorNavigationMapView 가 isUserInteractionEnabled=false 이므로
        // container 에 부착.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onFloorNavigationPinch(_:)))
        container.addGestureRecognizer(pinch)

        // +/- 줌 컨트롤 — 우하단 흰 알약. 핀치와 동일한 setZoomScale 호출. 미니맵 자식이라 expanded 모드에서도 함께 이동.
        let zoomControls = UIView()
        zoomControls.backgroundColor = MapDesignTokens.Surface.controlFill
        zoomControls.layer.cornerRadius = 14
        zoomControls.layer.masksToBounds = false
        zoomControls.layer.borderWidth = 1
        zoomControls.layer.borderColor = MapDesignTokens.Stroke.labelBorder.cgColor
        zoomControls.layer.shadowColor = UIColor.black.cgColor
        zoomControls.layer.shadowOpacity = 0.12
        zoomControls.layer.shadowRadius = 8
        zoomControls.layer.shadowOffset = CGSize(width: 0, height: 3)
        zoomControls.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(zoomControls)

        let plusButton = UIButton(type: .system)
        plusButton.setImage(UIImage(named: "plusThick")?.withRenderingMode(.alwaysTemplate), for: .normal)
        plusButton.tintColor = MapDesignTokens.Text.primary
        plusButton.imageView?.contentMode = .scaleAspectFit
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.addTarget(self, action: #selector(onFloorNavigationZoomIn), for: .touchUpInside)
        zoomControls.addSubview(plusButton)

        let zoomSeparator = UIView()
        zoomSeparator.backgroundColor = MapDesignTokens.Stroke.labelBorder
        zoomSeparator.translatesAutoresizingMaskIntoConstraints = false
        zoomControls.addSubview(zoomSeparator)

        let minusButton = UIButton(type: .system)
        minusButton.setImage(UIImage(named: "minusThick")?.withRenderingMode(.alwaysTemplate), for: .normal)
        minusButton.tintColor = MapDesignTokens.Text.primary
        minusButton.imageView?.contentMode = .scaleAspectFit
        minusButton.translatesAutoresizingMaskIntoConstraints = false
        minusButton.addTarget(self, action: #selector(onFloorNavigationZoomOut), for: .touchUpInside)
        zoomControls.addSubview(minusButton)

        NSLayoutConstraint.activate([
            zoomControls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            zoomControls.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            zoomControls.widthAnchor.constraint(equalToConstant: 44),

            plusButton.topAnchor.constraint(equalTo: zoomControls.topAnchor),
            plusButton.leadingAnchor.constraint(equalTo: zoomControls.leadingAnchor),
            plusButton.trailingAnchor.constraint(equalTo: zoomControls.trailingAnchor),
            plusButton.heightAnchor.constraint(equalToConstant: 44),

            zoomSeparator.topAnchor.constraint(equalTo: plusButton.bottomAnchor),
            zoomSeparator.leadingAnchor.constraint(equalTo: zoomControls.leadingAnchor, constant: 8),
            zoomSeparator.trailingAnchor.constraint(equalTo: zoomControls.trailingAnchor, constant: -8),
            zoomSeparator.heightAnchor.constraint(equalToConstant: 1),

            minusButton.topAnchor.constraint(equalTo: zoomSeparator.bottomAnchor),
            minusButton.leadingAnchor.constraint(equalTo: zoomControls.leadingAnchor),
            minusButton.trailingAnchor.constraint(equalTo: zoomControls.trailingAnchor),
            minusButton.heightAnchor.constraint(equalToConstant: 44),
            minusButton.bottomAnchor.constraint(equalTo: zoomControls.bottomAnchor),
        ])
    }

    @objc private func onFloorNavigationSwipeUp() {
        guard !isFloorNavigationExpanded else { return }
        setFloorNavigationExpanded(true, animated: true)
    }

    @objc private func onFloorNavigationSwipeDown() {
        guard isFloorNavigationExpanded else { return }
        setFloorNavigationExpanded(false, animated: true)
    }

    @objc private func onFloorNavigationPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            floorNavigationZoomBase = floorNavigationMapView.currentZoomScale
        case .changed:
            let next = floorNavigationZoomBase * gesture.scale
            floorNavigationMapView.setZoomScale(next)
        default: break
        }
    }

    @objc private func onFloorNavigationZoomIn() {
        let next = floorNavigationMapView.currentZoomScale * 1.3
        floorNavigationMapView.setZoomScale(next)
    }

    @objc private func onFloorNavigationZoomOut() {
        let next = floorNavigationMapView.currentZoomScale / 1.3
        floorNavigationMapView.setZoomScale(next)
    }

    private func setFloorNavigationExpanded(_ expanded: Bool, animated: Bool) {
        guard isFloorNavigationExpanded != expanded else { return }
        isFloorNavigationExpanded = expanded

        floorNavigationCollapsedHeightConstraint.isActive = !expanded
        floorNavigationExpandedHeightConstraint.isActive = expanded
        floorNavigationContainerView.layer.cornerRadius = expanded ? 0 : MapDesignTokens.Metric.containerTopCornerRadius

        setARSceneRenderingPausedForFloorMap(expanded)
        setNonMapHUDHiddenForExpandedMap(expanded)

        if expanded {
            self.view.bringSubviewToFront(navCardView)
            self.view.bringSubviewToFront(navCardSubView)
        }

        let updates = { self.view.layoutIfNeeded() }
        if animated {
            UIView.animate(withDuration: 0.28,
                           delay: 0,
                           usingSpringWithDamping: 0.9,
                           initialSpringVelocity: 0,
                           options: [.curveEaseInOut],
                           animations: updates)
        } else {
            updates()
        }
    }

    private func setNonMapHUDHiddenForExpandedMap(_ hidden: Bool) {
        // Phase 6 후속: nav 카드는 expanded 모드에서도 노출 유지 — fade 대상에서 제외.
        let views: [UIView?] = [
            remainingCapsuleView,
            locateButton,
            routeCalculatingView,
            closeButton
        ]
        UIView.animate(withDuration: hidden ? 0.18 : 0.2) {
            views.compactMap { $0 }.forEach { view in
                view.alpha = hidden ? 0 : 1
                view.isUserInteractionEnabled = !hidden
            }
        }
    }

    private func setARSceneRenderingPausedForFloorMap(_ paused: Bool) {
        sceneView.scene.rootNode.isHidden = paused
    }

    private func setupRouteCalculatingView() {
        routeCalculatingView = UIView()
        routeCalculatingView.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        routeCalculatingView.layer.cornerRadius = 16
        routeCalculatingView.layer.shadowColor = UIColor.black.cgColor
        routeCalculatingView.layer.shadowOpacity = 0.15
        routeCalculatingView.layer.shadowRadius = 8
        routeCalculatingView.layer.shadowOffset = CGSize(width: 0, height: 2)
        routeCalculatingView.translatesAutoresizingMaskIntoConstraints = false
        routeCalculatingView.isHidden = true
        routeCalculatingView.isUserInteractionEnabled = false
        self.view.addSubview(routeCalculatingView)

        routeCalculatingLabel = UILabel()
        routeCalculatingLabel.text = "경로를 계산 중입니다…"
        routeCalculatingLabel.textColor = .darkText
        routeCalculatingLabel.font = .systemFont(ofSize: 16, weight: .medium)
        routeCalculatingLabel.textAlignment = .center
        routeCalculatingLabel.translatesAutoresizingMaskIntoConstraints = false
        routeCalculatingView.addSubview(routeCalculatingLabel)

        let safeArea = self.view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            routeCalculatingView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            routeCalculatingView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -100),

            routeCalculatingLabel.leadingAnchor.constraint(equalTo: routeCalculatingView.leadingAnchor, constant: 20),
            routeCalculatingLabel.trailingAnchor.constraint(equalTo: routeCalculatingView.trailingAnchor, constant: -20),
            routeCalculatingLabel.topAnchor.constraint(equalTo: routeCalculatingView.topAnchor, constant: 14),
            routeCalculatingLabel.bottomAnchor.constraint(equalTo: routeCalculatingView.bottomAnchor, constant: -14),
        ])
    }

    private func setupFloorTransitionOverlay() {
        let bounds = self.view.bounds

        // 도착 UI(arrivalBadge) 와 동일한 패턴 — 검정 dim + 중앙 흰 pill + 그 아래 파란 capsule 버튼.
        floorTransitionOverlayView = UIView(frame: bounds)
        floorTransitionOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        floorTransitionOverlayView.isHidden = true
        floorTransitionOverlayView.isUserInteractionEnabled = true
        floorTransitionOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // 필(pill) 형태 안내 라벨
        let pill = UIView()
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        pill.layer.cornerRadius = 22
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOpacity = 0.15
        pill.layer.shadowRadius = 6
        pill.layer.shadowOffset = CGSize(width: 0, height: 2)
        pill.translatesAutoresizingMaskIntoConstraints = false
        floorTransitionOverlayView.addSubview(pill)

        // 아이콘 (층 이동 의미 — 위아래 화살표 원형)
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let iconImage = UIImage(systemName: "arrow.up.arrow.down.circle.fill", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(iconView)

        // pill 안 안내 텍스트
        let label = UILabel()
        label.text = "도착층으로 이동"
        label.textColor = .darkText
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.addSubview(label)

        // "이동 완료" 버튼 (파란 capsule, iOS 15+ Configuration)
        var buttonConfig = UIButton.Configuration.filled()
        buttonConfig.cornerStyle = .capsule
        buttonConfig.image = UIImage(systemName: "checkmark")
        buttonConfig.imagePadding = 8
        buttonConfig.baseBackgroundColor = .systemBlue
        buttonConfig.baseForegroundColor = .white
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        var titleAttr = AttributedString("이동 완료")
        titleAttr.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        buttonConfig.attributedTitle = titleAttr

        floorTransitionRestartButton = UIButton(configuration: buttonConfig, primaryAction: nil)
        floorTransitionRestartButton.translatesAutoresizingMaskIntoConstraints = false
        floorTransitionRestartButton.addTarget(self, action: #selector(onFloorTransitionRestartTapped), for: .touchUpInside)
        floorTransitionOverlayView.addSubview(floorTransitionRestartButton)

        self.view.addSubview(floorTransitionOverlayView)

        NSLayoutConstraint.activate([
            // pill 중앙, 가로 폭은 자식(iconView + label) intrinsic + 좌우 inset 으로 결정
            pill.centerXAnchor.constraint(equalTo: floorTransitionOverlayView.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: floorTransitionOverlayView.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 44),
            pill.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -16),
            pill.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 20),

            iconView.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            // 이동 완료 버튼 — pill 아래 16pt 간격
            floorTransitionRestartButton.centerXAnchor.constraint(equalTo: floorTransitionOverlayView.centerXAnchor),
            floorTransitionRestartButton.topAnchor.constraint(equalTo: pill.bottomAnchor, constant: 16),
        ])
    }

    private func setupHeadingOverlay() {
        headingOverlayView = HeadingAlignmentOverlayView(frame: self.view.bounds)
        headingOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(headingOverlayView)
    }

    private func setupTurnCard() {
        turnCardView = TurnCardView(frame: .zero)
        turnCardView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(turnCardView)

        let safeArea = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            turnCardView.widthAnchor.constraint(equalToConstant: TurnCardView.cardWidth),
            turnCardView.heightAnchor.constraint(equalToConstant: TurnCardView.cardHeight),
            turnCardView.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: TurnCardView.topInset),
            turnCardView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -TurnCardView.trailingInset),
        ])
    }

    @objc private func onFloorTransitionRestartTapped() {
        logic.restartFromFloorTransition()
    }

    @objc private func onLocateButtonTapped() {
        logic.startLocalizationFlow()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        // LiDAR sceneDepth — V3 localize multipart 의 depth 첨부 용. 미지원 단말이면 frameSemantics 미세팅 → frame.sceneDepth=nil.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        // LiDAR scene mesh — WallCenteringController 가 좌우 벽 raycast 에 사용.
        // 미지원 단말(non-LiDAR)이면 미세팅 → frame.anchors 에 ARMeshAnchor 0개 → controller no-op.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        sceneView.session.delegate = self
        sceneView.session.run(configuration)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        logic.stopCapture()
        logic.stopArrivalCheck()
        logic.stopPathProgressTracking()
        logic.stopPeriodicRelocalize()
        markerController.hideAll()
        sceneView.session.pause()
    }

    // MARK: - ARSessionDelegate (Phase 7)

    /// 매 ARFrame마다 SuperPoint 추론 cadence를 평가하고 통과 시 extractor 호출.
    /// 무거운 처리는 logic.processARFrame 내부에서 cadence 게이트로 차단된다.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        logic.processARFrame(frame)
    }
}

// MARK: - ARNavigationLogicDelegate

extension ARNavigationViewController: ARNavigationLogicDelegate {

    func updateStatus(_ message: String, color: UIColor) {
        // Phase 6: instructionLabel 은 신규 흐름에서 미사용 — 옵셔널 체이닝.
        instructionLabel?.text = message
        instructionLabel?.textColor = color == .white ? .darkText : color
    }

    func setLoading(_ loading: Bool) {
        locateButton.isEnabled = !loading
        locateButton.alpha = loading ? 0.5 : 1.0
    }

    func setCaptureProgress(phase: CaptureProgressPhase?) {
        guard let phase else {
            captureSpinner.stopAnimating()
            captureStatusLabel.isHidden = true
            captureStatusLabel.text = ""
            return
        }
        let statusText: String = {
            switch phase {
            case .capturing: return ""        // 카메라 촬영 언급 X — spinner 만
            case .localizing: return "측위 중..."
            }
        }()
        captureSpinner.startAnimating()
        captureStatusLabel.isHidden = statusText.isEmpty
        captureStatusLabel.text = statusText
    }

    func setScanningOverlay(visible: Bool) {
        if visible {
            scanningOverlayView.alpha = 0
            scanningOverlayView.isHidden = false
            UIView.animate(withDuration: 0.3) {
                self.scanningOverlayView.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.3) {
                self.scanningOverlayView.alpha = 0
            } completion: { _ in
                self.scanningOverlayView.isHidden = true
            }
        }
    }

    func showScanComplete() {
        scanningOverlayView.isHidden = true

        scanCompleteBadge.alpha = 0
        scanCompleteBadge.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.scanCompleteBadge.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            UIView.animate(withDuration: 0.4) {
                self.scanCompleteBadge.alpha = 0
            } completion: { _ in
                self.scanCompleteBadge.isHidden = true
            }
        }
    }

    func showArrivalNotification() {
        setHUDVisible(false)
        arrivalBadge.alpha = 0
        arrivalBadge.isHidden = false
        // arrivalBadge 가 hudContainerView 보다 먼저 추가되었을 수 있으므로 최상단으로 끌어올림.
        self.view.bringSubviewToFront(arrivalBadge)
        UIView.animate(withDuration: 0.3) {
            self.arrivalBadge.alpha = 1
        }
        // 자동 페이드 아웃 없음 — 사용자가 "확인" 버튼을 눌러야 root 복귀.
    }

    func showScanFailed(message: String) {
        scanningOverlayView.isHidden = true
        scanFailedLabel.text = message

        scanFailedView.alpha = 0
        scanFailedView.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.scanFailedView.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.4) {
                self.scanFailedView.alpha = 0
            } completion: { _ in
                self.scanFailedView.isHidden = true
            }
        }
    }

    func updateHUD(destinationName: String, remainingDistance: Float, instruction: String?) {
        // Phase 6: 기존 IUO 라벨들은 신규 카드 UX 에서 미사용 — 옵셔널 체이닝.
        destinationLabel?.text = destinationName
        remainingDistanceLabel?.text = String(format: "약 %.0fm", remainingDistance)
        instructionLabel?.text = instruction ?? "경로를 따라가세요"
    }

    func updateNavigationStep(_ vm: NavigationStepViewModel) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 1. 좌상단 nav 카드 — 다음 액션 아이콘 + 거리(굵게) + 방향 라벨. path 확정 후 첫 update 에서 노출.
            self.navCardView.isHidden = false
            self.navCardIconView.image = self.actionImage(for: vm.action)
            let navDistInt = max(0, Int(vm.distanceMeters.rounded()))
            let kernAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: NavCardStyle.distanceFontSize, weight: .bold),
                .foregroundColor: UIColor.white,
                .kern: -0.5
            ]
            self.navCardDistanceLabel.attributedText = NSAttributedString(
                string: "\(navDistInt)m", attributes: kernAttrs
            )
            self.navCardDirectionLabel.text = self.actionLabel(for: vm.action)

            // nav 카드 하단 보조 카드 — 목적지 이름 + 총 거리
            self.navCardSubView.isHidden = false
            self.navCardSubNameLabel.text = vm.destinationName
            let totalIntSub = max(0, Int(vm.remainingTotalMeters.rounded()))
            self.navCardSubDistanceLabel.text = "\(totalIntSub)m"

            // 미니맵 위 거리 배지 — 회전 아이콘 + 다음 액션까지 거리 forward
            self.floorNavigationMapView.updateNextAction(vm.action, distanceMeters: CGFloat(vm.distanceMeters))

            // Phase 6 후속: destination pill 폐기 — 옵셔널 체이닝으로 안전 갱신(현재 nil, no-op).
            if let floor = vm.destinationFloorLevel {
                self.destinationFloorLabel?.text = "\(floor)F · 목적지"
            } else {
                self.destinationFloorLabel?.text = "목적지"
            }
            self.destinationNameLabel?.text = vm.destinationName

            // 6. 하단 거리/시간 캡슐 — attributed
            let totalInt = max(0, Int(vm.remainingTotalMeters.rounded()))
            let cap = NSMutableAttributedString(
                string: "남은 거리 ",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: UIColor.white,
                ]
            )
            cap.append(NSAttributedString(
                string: "\(totalInt)m",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 16, weight: .heavy),
                    .foregroundColor: UIColor.systemBlue,
                ]
            ))
            cap.append(NSAttributedString(
                string: " | ",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.5),
                ]
            ))
            cap.append(NSAttributedString(
                string: "약 \(vm.remainingMinutes)분",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: UIColor.white,
                ]
            ))
            self.remainingCapsuleLabel.attributedText = cap
        }
    }

    func updateTurnArrow(_ vm: TurnArrowViewModel?) {
        // AR 마커 시스템(NextArrow) 도입으로 무력화. updateMarkers 가 통합 처리.
        // 잔여 turnArrowNode 가 있으면 1회만 정리.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.turnArrowNode?.removeFromParentNode()
            self.turnArrowNode = nil
            self.turnArrowStepIndex = nil
            _ = vm
        }
    }

    func updateMarkers(_ markers: [ARMarkerNode]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let pov = self.sceneView.pointOfView else {
                self.markerController.hideAll()
                return
            }
            let camPos = pov.simdWorldPosition
            // SceneKit 카메라 전방 = simdWorldFront ( -z 축 회전 결과 ). passed 방향성 판정용.
            let camFwd = pov.simdWorldFront
            self.markerController.update(activeMarkers: markers, cameraPos: camPos, cameraForward: camFwd)
        }
    }

    /// [DEAD PATH] AR 마커 시스템(NextArrow) 도입으로 폐기. 호출처 없음.
    /// 향후 복구 대비로 함수 본체 보존 (private 미사용 — Swift warning 가능).
    /// 우회전 화살표 베이스 path. 좌/우 모두 동일 path 사용 — yaw 회전으로만 방향 차이.
    /// SCNShape extrusionDepth 0.05m. brand-blue + emission 으로 어두운 환경 시인성 확보.
    private func makeTurnArrowSCNNode(direction: TurnDirection, kind: TurnArrowKind) -> SCNNode {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 0.4))
        path.addLine(to: CGPoint(x: 0.4, y: 0.4))
        path.addLine(to: CGPoint(x: 0.4, y: 0.5))
        path.addLine(to: CGPoint(x: 0.6, y: 0.3))
        path.addLine(to: CGPoint(x: 0.4, y: 0.1))
        path.addLine(to: CGPoint(x: 0.4, y: 0.2))
        path.addLine(to: CGPoint(x: 0.2, y: 0.2))
        path.addLine(to: CGPoint(x: 0.2, y: 0))
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0.05)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0/255, green: 102/255, blue: 255/255, alpha: 1)
        mat.emission.contents = UIColor(red: 0/255, green: 102/255, blue: 255/255, alpha: 1).withAlphaComponent(0.6)
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        mat.isDoubleSided = true
        shape.materials = [mat]
        return SCNNode(geometry: shape)
    }

    /// [DEAD PATH] makeTurnArrowSCNNode 와 함께 폐기. 호출처 없음.
    /// TurnDirection × TurnArrowKind → SceneKit Y-yaw (rad).
    /// SceneKit 좌수/+Y up 기준 가정 — 시뮬레이터 검증으로 부호 확정 권고. 필요시 반전.
    private func turnArrowYaw(direction: TurnDirection, kind: TurnArrowKind) -> Float {
        switch (direction, kind) {
        case (.left, .sharp):   return Float.pi / 2
        case (.right, .sharp):  return -Float.pi / 2
        case (.left, .slight):  return Float.pi / 4
        case (.right, .slight): return -Float.pi / 4
        case (.uTurn, _):       return Float.pi
        default:                return 0
        }
    }

    /// NavigationActionKind → 카드 아이콘. 핸드오프 매핑(Montage SVG)을 우선 사용하고,
    /// 매핑 표에 없는 액션은 SF Symbol 로 폴백한다.
    private func actionImage(for action: NavigationActionKind) -> UIImage? {
        let assetName: String?
        let sfSymbol: String?
        switch action {
        case .straight:        assetName = "arrowUpThick";        sfSymbol = "arrow.up"
        case .turnLeft:        assetName = "arrowTurnDownLeft";   sfSymbol = "arrow.turn.up.left"
        case .turnRight:       assetName = "arrowTurnDownRight";  sfSymbol = "arrow.turn.up.right"
        case .arrive:          assetName = "flagFill";            sfSymbol = "flag.checkered"
        case .unknown:         assetName = "arrowUpThick";        sfSymbol = "arrow.up"
        case .turnSlightLeft:  assetName = nil;                   sfSymbol = "arrow.up.left"
        case .turnSlightRight: assetName = nil;                   sfSymbol = "arrow.up.right"
        case .uturn:           assetName = nil;                   sfSymbol = "arrow.uturn.down"
        case .stairsUp,
             .stairsDown:      assetName = nil;                   sfSymbol = "figure.stairs"
        case .elevator:        assetName = nil;                   sfSymbol = "arrow.up.arrow.down.square"
        }
        if let name = assetName, let img = UIImage(named: name) {
            return img.withRenderingMode(.alwaysTemplate)
        }
        if let sf = sfSymbol {
            let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
            return UIImage(systemName: sf, withConfiguration: cfg)
        }
        return nil
    }

    /// NavigationActionKind → 한국어 라벨.
    private func actionLabel(for action: NavigationActionKind) -> String {
        switch action {
        case .straight: return "직진"
        case .turnLeft: return "좌회전"
        case .turnRight: return "우회전"
        case .turnSlightLeft: return "좌측 진행"
        case .turnSlightRight: return "우측 진행"
        case .uturn: return "유턴"
        case .stairsUp: return "계단 (오르기)"
        case .stairsDown: return "계단 (내려가기)"
        case .elevator: return "엘리베이터"
        case .arrive: return "도착"
        case .unknown: return "직진"
        }
    }

    func setHUDVisible(_ visible: Bool) {
        if visible {
            hudContainerView.alpha = 0
            hudContainerView.isHidden = false
            UIView.animate(withDuration: 0.3) {
                self.hudContainerView.alpha = 1
            }
            // HUD 표시 복귀 시 PathChevron 도 동반 노출.
            logic.setChevronHidden(false)
        } else {
            UIView.animate(withDuration: 0.3) {
                self.hudContainerView.alpha = 0
            } completion: { _ in
                self.hudContainerView.isHidden = true
            }
            // Phase 6: HUD 숨김 시 AR 공간 turn 화살표도 동반 정리.
            self.turnArrowNode?.removeFromParentNode()
            self.turnArrowNode = nil
            self.turnArrowStepIndex = nil
            // AR 마커도 동반 정리.
            self.markerController.hideAll()
            // PathChevron 도 동반 숨김.
            logic.setChevronHidden(true)
        }
    }

    func showFloorNavigationMap(_ map: FloorMapResponse,
                                routeSteps: [PathStep],
                                currentPosition: Position?,
                                currentHeadingDegrees: Float?,
                                destinationName: String?,
                                destinationWorldPoint: CGPoint?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.floorNavigationMapView.configure(
                map: map,
                routeSteps: routeSteps,
                currentPosition: currentPosition,
                currentHeadingDegrees: currentHeadingDegrees,
                destinationName: destinationName,
                destinationWorldPoint: destinationWorldPoint
            )
            guard self.floorNavigationContainerView.isHidden else { return }
            self.floorNavigationContainerView.alpha = 0
            self.floorNavigationContainerView.isHidden = false
            UIView.animate(withDuration: 0.25) {
                self.floorNavigationContainerView.alpha = 1
            }
        }
    }

    func updateFloorNavigationPosition(_ position: Position?, headingDegrees: Float?) {
        DispatchQueue.main.async { [weak self] in
            self?.floorNavigationMapView.updateCurrentPosition(position, headingDegrees: headingDegrees)
        }
    }

    func hideFloorNavigationMap() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  !self.floorNavigationContainerView.isHidden else { return }
            if self.isFloorNavigationExpanded {
                self.setFloorNavigationExpanded(false, animated: false)
            }
            UIView.animate(withDuration: 0.2) {
                self.floorNavigationContainerView.alpha = 0
            } completion: { _ in
                self.floorNavigationContainerView.isHidden = true
            }
        }
    }

    func setLocateButtonVisible(_ visible: Bool) {
        if visible {
            // 첫 측위 성공 이후엔 "재측정" 으로 라벨 전환.
            if !hasLocalizedSuccessfully {
                hasLocalizedSuccessfully = true
                locateButton.setTitle("재측정", for: .normal)
            }
            locateButton.alpha = 0
            locateButton.isHidden = false
            UIView.animate(withDuration: 0.2) {
                self.locateButton.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.2) {
                self.locateButton.alpha = 0
            } completion: { _ in
                self.locateButton.isHidden = true
            }
        }
    }

    func showRouteCalculating(_ visible: Bool) {
        if visible {
            routeCalculatingView.alpha = 0
            routeCalculatingView.isHidden = false
            UIView.animate(withDuration: 0.3) {
                self.routeCalculatingView.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.3) {
                self.routeCalculatingView.alpha = 0
            } completion: { _ in
                self.routeCalculatingView.isHidden = true
            }
        }
    }

    func showFloorTransition(transitionType: String, targetFloor: Int?, currentFloor: Int?) {
        // UI는 정적(아이콘/텍스트 변경 없음). transitionType/targetFloor 는 향후 확장용으로 시그니처 보존.
        _ = (transitionType, targetFloor, currentFloor)

        floorTransitionOverlayView.alpha = 0
        floorTransitionOverlayView.isHidden = false
        self.view.bringSubviewToFront(floorTransitionOverlayView)
        UIView.animate(withDuration: 0.3) {
            self.floorTransitionOverlayView.alpha = 1
        }
    }

    func hideFloorTransition() {
        UIView.animate(withDuration: 0.3) {
            self.floorTransitionOverlayView.alpha = 0
        } completion: { _ in
            self.floorTransitionOverlayView.isHidden = true
        }
    }
}

// MARK: - GuidanceDirectorDelegate (Phase 5)

extension ARNavigationViewController: GuidanceDirectorDelegate {

    func guidance(_ director: GuidanceDirector, showInitialAlignment direction: TurnDirection, angle: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.headingOverlayView.show(direction: direction, angleDeg: angle, mode: .initial)
        }
    }

    func guidance(_ director: GuidanceDirector, showReorient direction: TurnDirection, angle: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.headingOverlayView.show(direction: direction, angleDeg: angle, mode: .reorient)
        }
    }

    func guidanceDismissAlignmentOverlay(_ director: GuidanceDirector) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.headingOverlayView.dismiss()
        }
    }

    func guidance(_ director: GuidanceDirector, showTurnCard direction: TurnDirection, distance: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.turnCardView.update(direction: direction, distanceMeters: distance)
            self.turnCardView.showSlideIn(in: self.view)
        }
    }

    func guidance(_ director: GuidanceDirector, updateTurnCardDistance distance: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.turnCardView.updateDistance(distance)
        }
    }

    func guidanceHideTurnCard(_ director: GuidanceDirector) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.turnCardView.hideSlideOut()
        }
    }
}

// MARK: - UIImage 리사이즈 헬퍼 (Phase 6)

private extension UIImage {
    /// vector 자산을 button 표시 사이즈로 리샘플링.
    func resized(to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
