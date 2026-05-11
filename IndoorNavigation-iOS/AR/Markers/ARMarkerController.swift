import UIKit
import SceneKit
import simd

// MARK: - ARMarkerController
// 사양 §3 / §8 (AR_MARKER_3D.md). 단일 마커 라이프사이클 manager.
// Logic 이 makeActiveMarkerList 로 발신한 1~2개의 후보 중 controller 가 단일 표시를 보장한다.
//
// 상태 전이 (사양 §3 + 인계 시점 B+D 보정):
//   d > 50m  → hidden (제거 또는 fadeOut)
//   d ≤ 50m  → DistanceMarker
//   d ≤ 10m  → NextArrow (회전 step 일 때) — 크로스페이드
//   d ≤ 3m AND markerBehind → passed (fadeOut 후 정리)  ← B(3m) + D(방향성) 적용
//   d ≤ 3m 이지만 마커가 카메라 앞쪽이면 → 그대로 NextArrow 유지 (아직 통과 전)
//
// 거리 스케일 (시인성 보정):
//   worldScale = clamp(d / 10, 0.8, 2.5)

final class ARMarkerController {

    // MARK: - 내부 상태

    /// 현재 표시 중인 단일 마커 정보 (있을 수 있음 / 없을 수 있음).
    private struct ActiveEntry {
        let id: String
        var kind: MarkerKind
        var node: SCNNode
        var worldPosition: simd_float3
    }

    private weak var parentNode: SCNNode?
    private var current: ActiveEntry?

    // MARK: - 외부 인터페이스

    /// 마커 노드들을 추가할 부모 노드(보통 scene.rootNode) 를 등록.
    func attach(to parent: SCNNode) {
        self.parentNode = parent
    }

    /// Logic 으로부터 매 tick 호출. 후보 중 우선순위 마커 1개로 desiredState 산출 후 transition 적용.
    /// 메인 스레드에서 호출 가정 (caller 가 DispatchQueue.main.async 로 감싼다).
    ///
    /// cameraForward: SceneKit world 좌표계의 카메라 전방 벡터 (pointOfView.simdWorldFront).
    ///   passed 판정에서 마커가 카메라 뒤쪽에 있는지 (= 사용자가 마커를 등진 상태) 부호 검사에 사용.
    func update(activeMarkers: [ARMarkerNode], cameraPos: simd_float3, cameraForward: simd_float3) {
        guard let parent = parentNode else { return }

        // 우선 마커 선택: nextTurn 후보가 있으면 그 후보(가까운 turn), 없으면 distance 후보.
        // hidden 후보는 무시 (Logic 측에서 만들지 않음 권장이지만 안전망).
        let desired = pickDesired(from: activeMarkers, cameraPos: cameraPos)

        guard let desired = desired else {
            // 표시할 마커 없음 → 기존 마커 fadeOut 처리.
            removeCurrentIfAny()
            return
        }

        // 거리 산출 (XZ 평면)
        let d = horizontalDistance(from: cameraPos, to: desired.worldPosition)

        // 방향성 판정: 마커가 카메라 뒤쪽인지 (XZ 평면). 부호만 보므로 정규화 불필요.
        // dot((cam - marker), forwardXZ) > 0 → 마커는 카메라 뒤 = 사용자가 통과한 상태.
        let backX = cameraPos.x - desired.worldPosition.x
        let backZ = cameraPos.z - desired.worldPosition.z
        let rawDot = backX * cameraForward.x + backZ * cameraForward.z
        let markerBehind = rawDot > 0

        // 거리 기반 desiredState (사양 §3 + B+D 보정) — Logic 이 보낸 kind 를 그대로 따르되, 거리/방향 임계로 hidden/passed 보정.
        let resolvedKind = resolveKind(rawKind: desired.kind, distance: d, markerBehind: markerBehind)

        switch resolvedKind {
        case .hidden:
            removeCurrentIfAny()
            return
        case .passed:
            // 0.5s fadeOut 후 정리. 새 마커 enter 는 다음 tick 의 다른 후보가 담당.
            removeCurrentIfAny()
            return
        case .distance, .nextTurn, .elevator, .stairs, .destination:
            applyOrSwap(
                desiredId: desired.id,
                desiredKind: resolvedKind,
                desiredWorldPos: desired.worldPosition,
                distance: d,
                parent: parent
            )
        }
    }

    /// 모든 마커 정리. ViewController dismiss / setHUDVisible(false) 시 호출.
    func hideAll() {
        removeCurrentIfAny()
    }

    // MARK: - 핵심 transition

    private func applyOrSwap(
        desiredId: String,
        desiredKind: MarkerKind,
        desiredWorldPos: simd_float3,
        distance: Float,
        parent: SCNNode
    ) {
        // 거리 스케일
        let s = clampScale(distance / 10.0)

        guard var entry = current else {
            // 신규 enter 애니메이션
            let node = buildNode(for: desiredKind)
            node.position = SCNVector3(desiredWorldPos.x, desiredWorldPos.y, desiredWorldPos.z)
            // 시작 상태: scale 0.6, opacity 0
            node.scale = SCNVector3(s * 0.6, s * 0.6, s * 0.6)
            setOpacity(node, opacity: 0)
            parent.addChildNode(node)

            // enter 애니메이션: 0.35s easeOut, scale 0.6 → 1, opacity 0 → 1.
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.35
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            node.scale = SCNVector3(s, s, s)
            setOpacity(node, opacity: 1)
            SCNTransaction.commit()

            current = ActiveEntry(id: desiredId, kind: desiredKind, node: node, worldPosition: desiredWorldPos)
            return
        }

        // 같은 id + 같은 kind 류 (distance ↔ distance, nextTurn ↔ nextTurn 동일 direction) → swap 없이 scale/pos 갱신 + texture 만 교체
        if entry.id == desiredId, sameKindFamily(entry.kind, desiredKind) {
            if case .distance(let oldM) = entry.kind, case .distance(let newM) = desiredKind, oldM != newM {
                swapDistanceTexture(node: entry.node, meters: newM)
                entry.kind = desiredKind
            }
            entry.worldPosition = desiredWorldPos
            entry.node.position = SCNVector3(desiredWorldPos.x, desiredWorldPos.y, desiredWorldPos.z)
            entry.node.scale = SCNVector3(s, s, s)
            current = entry
            return
        }

        // 종류 다름 → 0.3s 크로스페이드 (동일 worldPosition, 신규 노드는 desiredWorldPos 사용)
        let oldNode = entry.node
        let newNode = buildNode(for: desiredKind)
        newNode.position = SCNVector3(desiredWorldPos.x, desiredWorldPos.y, desiredWorldPos.z)
        newNode.scale = SCNVector3(s, s, s)
        setOpacity(newNode, opacity: 0)
        parent.addChildNode(newNode)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.30
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .linear)
        SCNTransaction.completionBlock = { [weak oldNode] in
            oldNode?.removeFromParentNode()
        }
        setOpacity(oldNode, opacity: 0)
        setOpacity(newNode, opacity: 1)
        SCNTransaction.commit()

        current = ActiveEntry(id: desiredId, kind: desiredKind, node: newNode, worldPosition: desiredWorldPos)
    }

    private func removeCurrentIfAny() {
        guard let entry = current else { return }
        let node = entry.node
        SCNTransaction.begin()
        // 0.3 → 0.5: 신규 enter (0.35s) 와 자연스럽게 이어지도록 fadeOut 길이 연장.
        SCNTransaction.animationDuration = 0.50
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .linear)
        SCNTransaction.completionBlock = { [weak node] in
            node?.removeFromParentNode()
        }
        setOpacity(node, opacity: 0)
        SCNTransaction.commit()
        current = nil
    }

    // MARK: - 유틸

    /// 후보 중 우선 마커 선택.
    /// 단일 마커 정책 — 후보가 여러 개여도 controller 가 1개만 표시.
    /// 우선순위 (사양 §2-3 / §2-4):
    ///   1) destination — 3m 이내일 때만 최우선 (최종 목적지 도착 직전 신호)
    ///   2) nextTurn — 회전 직전 강한 신호
    ///   3) elevator — 층 이동 노드
    ///   4) stairs — 층 이동 노드
    ///   5) distance — 일반 거리 마커
    private func pickDesired(from candidates: [ARMarkerNode], cameraPos: simd_float3) -> ARMarkerNode? {
        if candidates.isEmpty { return nil }
        // 1) destination (3m 이내일 때만 최우선)
        if let dst = candidates.first(where: { c in
            if case .destination = c.kind { return true } else { return false }
        }) {
            let d = horizontalDistance(from: cameraPos, to: dst.worldPosition)
            if d <= 3.0 { return dst }
        }
        // 2) nextTurn
        if let nt = candidates.first(where: { c in
            if case .nextTurn = c.kind { return true } else { return false }
        }) {
            return nt
        }
        // 3) elevator
        if let ev = candidates.first(where: { c in
            if case .elevator = c.kind { return true } else { return false }
        }) {
            return ev
        }
        // 4) stairs
        if let st = candidates.first(where: { c in
            if case .stairs = c.kind { return true } else { return false }
        }) {
            return st
        }
        // 5) distance
        return candidates.first(where: { c in
            if case .distance = c.kind { return true } else { return false }
        })
    }

    /// 거리 + raw kind + 방향성 → 실제 표시 kind. 사양 §3 상태 전이 매핑 + 인계 시점 B+D 보정.
    ///   d > 50m                          → hidden
    ///   d ≤ 3m AND markerBehind          → passed  (B: 임계 3m + D: 방향성)
    ///   d > 10m                          → distance (rawKind 가 .nextTurn 이어도 강등)
    ///   d ≤ 10m AND rawKind == nextTurn  → nextTurn
    ///   그 외                            → distance
    /// rawKind 가 .nextTurn(.uTurn) 이면 hidden (NextArrow 는 좌/우 전용).
    ///
    /// markerBehind: 카메라가 마커를 등진 상태 (XZ 평면 dot 부호로 판정). 짧은 거리에서 ARKit
    /// 노이즈로 부호가 흔들릴 수 있으나 통과 직후엔 명확히 양수가 되므로 안정적.
    private func resolveKind(rawKind: MarkerKind, distance: Float, markerBehind: Bool) -> MarkerKind {
        if distance > 50.0 { return .hidden }

        switch rawKind {
        case .destination:
            // 사양 §3: 3m 이내일 때만 표시. 통과해도 유지 (passed 처리 X — 도착지 인식 유지).
            return distance > 3.0 ? .hidden : .destination

        case .elevator, .stairs:
            // 사양 §2-4: DistanceMarker 와 동일 거리 임계. 단 통과 처리 X
            // (층 전환 시 logic 의 advance 가드가 자동으로 노드 교체).
            return rawKind

        case .nextTurn(let dir):
            // uTurn 입력은 hidden (사양: NextArrow 는 회전(좌/우) 전용).
            if dir == .uTurn { return .hidden }
            // B + D: 3m 이내 + 사용자가 마커 등진 상태일 때만 passed.
            if distance <= 3.0 && markerBehind { return .passed }
            // 사양 §3: 10m 초과면 distance 강등 (같은 worldPos 에서 DistanceMarker 로 표시).
            if distance > 10.0 {
                return .distance(meters: Int(distance.rounded()))
            }
            return rawKind

        case .distance:
            // B + D: 3m 이내 + 사용자가 마커 등진 상태일 때만 passed.
            if distance <= 3.0 && markerBehind { return .passed }
            // 거리 갱신은 controller 가 raw distance 로 덮어씀 (round).
            return .distance(meters: Int(distance.rounded()))

        case .hidden, .passed:
            return rawKind
        }
    }

    private func sameKindFamily(_ a: MarkerKind, _ b: MarkerKind) -> Bool {
        switch (a, b) {
        case (.distance, .distance): return true
        case (.nextTurn(let da), .nextTurn(let db)): return da == db
        case (.elevator, .elevator): return true
        case (.stairs, .stairs): return true
        case (.destination, .destination): return true
        default: return false
        }
    }

    private func buildNode(for kind: MarkerKind) -> SCNNode {
        switch kind {
        case .distance(let m):
            return ARMarkerNodeBuilder.buildDistanceMarker(meters: max(5, min(50, m)))
        case .nextTurn(let dir):
            // .left / .right 만 빌드 (uTurn 은 resolveKind 에서 hidden 처리됨 — 방어적 fallback).
            let direction: TurnDirection = (dir == .left) ? .left : .right
            return ARMarkerNodeBuilder.buildNextArrow(direction: direction)
        case .elevator:
            return ARMarkerNodeBuilder.buildElevatorMarker()
        case .stairs:
            return ARMarkerNodeBuilder.buildStairsMarker()
        case .destination:
            return ARMarkerNodeBuilder.buildDestinationPin()
        case .hidden, .passed:
            return SCNNode()
        }
    }

    /// distance 마커 텍스처 swap. node 트리 내 "distanceText" plane 의 first material diffuse 만 교체.
    /// 텍스처 생성은 캐시 기반 — hit 시 메인 스레드에서 즉시 swap, miss 시 백그라운드 생성 후 메인 적용
    /// (이전엔 매 swap 마다 1024² UIGraphicsImageRenderer 2회 호출로 메인 블로킹 → AR 렌더 프레임 드롭).
    private func swapDistanceTexture(node: SCNNode, meters: Int) {
        let clamped = max(5, min(50, meters))
        guard let textPlane = node.childNode(withName: "distanceText", recursively: true),
              let mat = textPlane.geometry?.firstMaterial else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let tex = MarkerGeometryFactory.makeDistanceTextTexture(meters: clamped)
            DispatchQueue.main.async { [weak mat] in
                guard let mat = mat else { return }
                mat.diffuse.contents = tex
                mat.transparent.contents = tex
            }
        }
    }

    /// 노드와 모든 자식의 opacity 일괄 설정 (transparent material 의 chevron blink 와 충돌하지 않도록 노드 opacity 만 사용).
    private func setOpacity(_ node: SCNNode, opacity: CGFloat) {
        node.opacity = opacity
    }

    /// 사양 §3 거리 스케일 clamp.
    private func clampScale(_ s: Float) -> Float {
        return max(0.8, min(2.5, s))
    }

    /// XZ 평면 거리 (Y 무시).
    private func horizontalDistance(from cam: simd_float3, to pos: simd_float3) -> Float {
        let dx = cam.x - pos.x
        let dz = cam.z - pos.z
        return sqrt(dx * dx + dz * dz)
    }
}
