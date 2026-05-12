import UIKit
import SceneKit

// MARK: - 마커 SCNNode 빌더
// 사양 §2 / §4 (AR_MARKER_3D.md). NextArrow / Elevator / Stairs / DestinationPin 네 빌더 + 공통 부유 모션.
// (DistanceMarker 는 PathChevron 시스템 도입으로 폐기 — 2026-05-11)
// caller (ARMarkerController) 가 노드 트리에 추가하고 scale/position/transparency 만 조절한다.
//
// 노드 계층 (사용자 요청: 글씨 항상 사용자 향함 — Y축 빌보드 제약 적용):
//   root (controller 가 world position/scale 제어)
//    └ motionNode (부유 모션: position.y ±4cm bobbing — yaw 부유는 빌보드 제약과 충돌하므로 제거)
//       └ billboardNode (SCNBillboardConstraint .Y — 글씨가 항상 카메라 향함)
//          ├ diamond body
//          ├ text panel
//          └ chevrons (NextArrow 일 때)

enum ARMarkerNodeBuilder {

    /// 10m 거리 기준 본체 변 길이(m). 사양 §1 의 0.6m 대비 사용자 요청으로 2배.
    static let baseSize: CGFloat = 1.2

    // MARK: - NextArrow

    /// 다이아몬드 본체 + "Next" 텍스트 plane + 셰브론 체인(2개) sequential blink.
    /// direction 이 .left 면 셰브론을 본체 왼쪽에 배치 (전체 chain 노드를 Y축 π 회전으로 거울).
    /// 사양 §2-2 / §4.
    static func buildNextArrow(direction: TurnDirection) -> SCNNode {
        let root = SCNNode()
        root.name = "nextArrowMarker"

        let motionNode = SCNNode()
        motionNode.name = "motionNode"
        root.addChildNode(motionNode)

        let billboardNode = makeBillboardNode()
        motionNode.addChildNode(billboardNode)

        let body = MarkerGeometryFactory.makeDiamondBody(size: baseSize)
        billboardNode.addChildNode(body)

        // 중앙 "Next" 텍스트 (텍스처 1회 생성 → 재사용)
        let texSize: CGFloat = baseSize * 0.95
        let textPlane = SCNPlane(width: texSize, height: texSize)
        let textMat = SCNMaterial()
        textMat.lightingModel = .constant
        let nextTex = MarkerGeometryFactory.makeNextTextTexture()
        textMat.diffuse.contents = nextTex
        textMat.transparent.contents = nextTex
        textMat.isDoubleSided = false
        textMat.writesToDepthBuffer = false
        textPlane.materials = [textMat]
        let textNode = SCNNode(geometry: textPlane)
        textNode.name = "nextText"
        textNode.position = SCNVector3(0, 0, Float(baseSize * 0.05 / 2 + 0.02))
        billboardNode.addChildNode(textNode)

        // 셰브론 체인 — chain 노드 자체를 좌회전 시 Y 180° 회전해 거울 대칭 (scale.x 음수 회피)
        let chain = SCNNode()
        chain.name = "chevronChain"
        if direction == .left {
            chain.eulerAngles = SCNVector3(0, Float.pi, 0)
        }
        // 본체보다 살짝 앞 (z+) 으로 띄워 z-fighting 방지
        chain.position = SCNVector3(0, 0, Float(baseSize * 0.05 / 2 + 0.005))
        billboardNode.addChildNode(chain)

        // chain 의 local 좌표는 항상 "우회전 기준" (오른쪽으로 향함). 좌회전은 chain 자체가 Y축 거울이라 결과적으로 왼쪽.
        let chevScale: CGFloat = baseSize * 0.78
        let xStart: CGFloat = baseSize * 1.05
        let xStep: CGFloat = baseSize * 0.78

        for i in 0..<2 {
            let chev = MarkerGeometryFactory.makeChevron()
            chev.scale = SCNVector3(Float(chevScale), Float(chevScale), Float(chevScale))
            chev.position = SCNVector3(
                Float(xStart + xStep * CGFloat(i)),
                0,
                0
            )
            chev.name = "chevron_\(i)"
            chain.addChildNode(chev)

            attachSequentialBlink(to: chev, index: i)
        }

        attachFloatingMotion(to: motionNode)
        return root
    }

    // MARK: - ElevatorMarker

    /// 다이아몬드 본체 + "엘리베이터" 한글 텍스트 plane. 사양 §2-4 — 하단 삼각형/셰브론 등 보조 그래픽 없음.
    /// node.name = "elevatorMarker", 자식 textPlane.name = "elevatorText".
    static func buildElevatorMarker() -> SCNNode {
        let root = SCNNode()
        root.name = "elevatorMarker"

        let motionNode = SCNNode()
        motionNode.name = "motionNode"
        root.addChildNode(motionNode)

        let billboardNode = makeBillboardNode()
        motionNode.addChildNode(billboardNode)

        let body = MarkerGeometryFactory.makeDiamondBody(size: baseSize)
        billboardNode.addChildNode(body)

        let texSize: CGFloat = baseSize * 0.95
        let textPlane = SCNPlane(width: texSize, height: texSize)
        let textMat = SCNMaterial()
        textMat.lightingModel = .constant
        let tex = MarkerGeometryFactory.makeElevatorTextTexture()
        textMat.diffuse.contents = tex
        textMat.transparent.contents = tex
        textMat.isDoubleSided = false
        textMat.writesToDepthBuffer = false
        textPlane.materials = [textMat]
        let textNode = SCNNode(geometry: textPlane)
        textNode.name = "elevatorText"
        textNode.position = SCNVector3(0, 0, Float(baseSize * 0.05 / 2 + 0.02))
        billboardNode.addChildNode(textNode)

        attachFloatingMotion(to: motionNode)
        return root
    }

    // MARK: - StairsMarker

    /// 다이아몬드 본체 + "계단" 한글 텍스트 plane. 사양 §2-4 — 하단 삼각형/셰브론 등 보조 그래픽 없음.
    /// node.name = "stairsMarker", 자식 textPlane.name = "stairsText".
    static func buildStairsMarker() -> SCNNode {
        let root = SCNNode()
        root.name = "stairsMarker"

        let motionNode = SCNNode()
        motionNode.name = "motionNode"
        root.addChildNode(motionNode)

        let billboardNode = makeBillboardNode()
        motionNode.addChildNode(billboardNode)

        let body = MarkerGeometryFactory.makeDiamondBody(size: baseSize)
        billboardNode.addChildNode(body)

        let texSize: CGFloat = baseSize * 0.95
        let textPlane = SCNPlane(width: texSize, height: texSize)
        let textMat = SCNMaterial()
        textMat.lightingModel = .constant
        let tex = MarkerGeometryFactory.makeStairsTextTexture()
        textMat.diffuse.contents = tex
        textMat.transparent.contents = tex
        textMat.isDoubleSided = false
        textMat.writesToDepthBuffer = false
        textPlane.materials = [textMat]
        let textNode = SCNNode(geometry: textPlane)
        textNode.name = "stairsText"
        textNode.position = SCNVector3(0, 0, Float(baseSize * 0.05 / 2 + 0.02))
        billboardNode.addChildNode(textNode)

        attachFloatingMotion(to: motionNode)
        return root
    }

    // MARK: - DestinationPin

    /// 10m 거리 기준 핀 본체 폭 (m). 사양 §2-3 — 5m 거리 0.45m 기준에서 baseSize 와 균형 잡힌 0.9m.
    static let pinBaseSize: CGFloat = 0.9

    /// 빨강 지도 핀 (사양 §2-3). 다이아몬드 마커와 동일한 motion + Y축 빌보드 구조 유지.
    /// node.name = "destinationPin".
    static func buildDestinationPin() -> SCNNode {
        let root = SCNNode()
        root.name = "destinationPin"

        let motionNode = SCNNode()
        motionNode.name = "motionNode"
        root.addChildNode(motionNode)

        let billboardNode = makeBillboardNode()
        motionNode.addChildNode(billboardNode)

        let pinBody = MarkerGeometryFactory.makeDestinationPinBody(size: Self.pinBaseSize)
        billboardNode.addChildNode(pinBody)

        attachFloatingMotion(to: motionNode)
        return root
    }

    // MARK: - 빌보드 노드

    /// Y축 빌보드 제약 노드 — 부모(motionNode) 의 yaw 와 무관하게 자식 그룹이 카메라를 향함.
    /// 사용자 요청 "글씨 항상 사용자 향함" 적용. ARSCNView 의 pointOfView 가 매 프레임 갱신되므로 자동 추적.
    private static func makeBillboardNode() -> SCNNode {
        let node = SCNNode()
        node.name = "billboardNode"
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        node.constraints = [billboard]
        return node
    }

    // MARK: - 공통 모션

    /// 사양 §4 부유 모션. 사용자 요청(글씨 가독성 우선)으로 yaw ±10° 진동은 제거.
    /// y 위치 ±4cm (1.10 rad/s → 주기 ~5.7s) 만 유지.
    private static func attachFloatingMotion(to node: SCNNode) {
        let duration: TimeInterval = 60  // 무한 반복용 base — 내부 sin 은 절대 시간 사용
        let baseY = node.position.y
        let startT = CACurrentMediaTime()
        let action = SCNAction.customAction(duration: duration) { node, _ in
            let t = Float(CACurrentMediaTime() - startT)
            node.position.y = baseY + sin(t * 1.10) * 0.04
        }
        node.runAction(SCNAction.repeatForever(action), forKey: "floatingMotion")
    }

    /// 셰브론 sequential blink. period 1.4s, 두 셰브론 0.5s 간격 (index 0 → 0s, index 1 → 0.5s).
    /// opacity 0.4 → 1.0 sin 펄스 (사양은 0.35 → 1.0 이지만 펄스 비활성 구간에서도 가시성 유지를 위해 floor 상향).
    private static func attachSequentialBlink(to chevron: SCNNode, index: Int) {
        guard let mat = chevron.geometry?.firstMaterial else { return }
        // 초기 opacity 1.0 — 첫 프레임부터 가시 보장 (이전엔 첫 프레임 transparency 가 0.35 floor 라 거의 안 보임)
        mat.transparency = 1.0
        let period: Float = 1.4
        let offset: Float = Float(index) * 0.5
        let startT = CACurrentMediaTime()
        let action = SCNAction.customAction(duration: 60) { _, _ in
            let t = Float(CACurrentMediaTime() - startT)
            let raw = (t - offset).truncatingRemainder(dividingBy: period)
            let phase = ((raw + period).truncatingRemainder(dividingBy: period)) / period
            let pulse: Float
            if phase < 0.4 {
                pulse = sin((phase / 0.4) * Float.pi)
            } else {
                pulse = 0
            }
            // floor 0.4 (이전 0.35) — 펄스 비활성 구간에서도 사용자가 셰브론을 명확히 인지
            mat.transparency = CGFloat(0.4 + pulse * 0.6)
        }
        chevron.runAction(SCNAction.repeatForever(action), forKey: "chevronBlink_\(index)")
    }
}
