import UIKit
import SceneKit
import simd

// MARK: - ARMarkerController
// 단일 마커 라이프사이클 manager. Logic 이 보낸 단일 후보를 받아 표시.
//
// 거리 임계 (controller 보유분):
//   nextTurn 입력 d > 10m → hidden (PathChevron 시스템 도입으로 distance 강등 제거)
//   d ≤ 3m AND markerBehind → passed (fadeOut 후 정리, 통과 UX 목적)
//   그 외 → Logic 이 보낸 kind 그대로 표시 (destination/elevator/stairs 는 거리 무관)
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

        // 우선 마커 선택: nextTurn / destination / elevator / stairs 순.
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
        case .nextTurn, .elevator, .stairs, .destination:
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

        // 같은 id + 같은 kind 류 (nextTurn ↔ nextTurn 동일 direction) → swap 없이 scale/pos 갱신
        if entry.id == desiredId, sameKindFamily(entry.kind, desiredKind) {
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
    /// 우선순위:
    ///   1) destination — 거리 무관 최우선 (Logic 단순화 정책: arrive step 도달 시 즉시 발신)
    ///   2) nextTurn — 회전 직전 강한 신호
    ///   3) elevator — 층 이동 노드
    ///   4) stairs — 층 이동 노드
    /// cameraPos 시그니처는 호출 흐름 안전망으로 유지.
    private func pickDesired(from candidates: [ARMarkerNode], cameraPos: simd_float3) -> ARMarkerNode? {
        if candidates.isEmpty { return nil }
        // 1) destination (거리 무관 최우선)
        if let dst = candidates.first(where: { c in
            if case .destination = c.kind { return true } else { return false }
        }) {
            return dst
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
        return candidates.first(where: { c in
            if case .stairs = c.kind { return true } else { return false }
        })
    }

    /// raw kind + 거리 + 방향성 → 실제 표시 kind.
    ///   nextTurn  : >10m → hidden (PathChevron 시스템 도입으로 distance 강등 폐기),
    ///               ≤3m + behind → passed, 그 외 그대로
    ///   destination/elevator/stairs : 거리 무관 그대로 (통과 처리 X)
    ///   nextTurn(uTurn) : hidden
    ///
    /// markerBehind: 카메라가 마커를 등진 상태 (XZ 평면 dot 부호). 통과 직후 명확히 양수.
    private func resolveKind(rawKind: MarkerKind, distance: Float, markerBehind: Bool) -> MarkerKind {
        switch rawKind {
        case .destination:
            // 거리 무관 표시. 통과해도 유지 (도착지 인식 유지).
            return .destination

        case .elevator, .stairs:
            // 거리 무관 표시. 통과 처리 X (층 전환 시 logic 의 advance 가드가 자동으로 노드 교체).
            return rawKind

        case .nextTurn(let dir):
            // uTurn 입력은 hidden (NextArrow 는 회전(좌/우) 전용).
            if dir == .uTurn { return .hidden }
            // 3m 이내 + 마커 등진 상태 → passed (통과 fadeOut UX).
            if distance <= 3.0 && markerBehind { return .passed }
            // >10m 면 hidden. PathChevron 시스템이 원거리 안내 담당.
            if distance > 10.0 {
                return .hidden
            }
            return rawKind

        case .hidden, .passed:
            return rawKind
        }
    }

    private func sameKindFamily(_ a: MarkerKind, _ b: MarkerKind) -> Bool {
        switch (a, b) {
        case (.nextTurn(let da), .nextTurn(let db)): return da == db
        case (.elevator, .elevator): return true
        case (.stairs, .stairs): return true
        case (.destination, .destination): return true
        default: return false
        }
    }

    private func buildNode(for kind: MarkerKind) -> SCNNode {
        switch kind {
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
