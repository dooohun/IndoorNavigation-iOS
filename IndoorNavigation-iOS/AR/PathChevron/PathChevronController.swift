import UIKit
import SceneKit
import simd

// MARK: - PathChevronController
//
// 바닥 경로 chevron(^) 시스템 — 기존 sphere + cylinder path 시각화를 대체.
// 동시 표시는 2개로 한정(사용자 위치 기준 path 진행 방향 앞 두 개). spawn/consume 큐 모델.
//
// 외부 인터페이스:
//   attach(to:)              — chevron 노드들이 추가될 부모 노드 등록 (보통 scene.rootNode)
//   setRoute(arPoints:floorY:cameraPos:) — path 갱신 시 distribution 재계산 + 큐 초기화
//   tickCamera(cameraPos:)   — 1Hz 마다 호출. 가장 앞 chevron 통과 시 제거 + 신규 spawn
//   setHidden(_:)            — 가시성 토글 (층 전환 모달 등에서 사용)
//   clear()                  — 모든 chevron 제거 + 상태 리셋
//
// 분포 알고리즘:
//   - spacing 2.5m, segmentStartOffset 1.0m, segmentEndPadding 0.5m
//   - 각 segment (a, b) 에 대해 XZ 평면 길이 > 1.5m 일 때만 chevron 배치
//   - yaw = atan2(-dir.x, -dir.z)  (SceneKit eulerAngles.x = -π/2 + .y = yaw 적용 후 apex world 방향 = (-sin(yaw), -cos(yaw)) → 진행 방향 (dirX, dirZ) 정렬)
//   - cameraPos 가 nil 아니면 카메라보다 뒤쪽(path 진행 방향 기준) chevron 은 skip
//
// 애니메이션:
//   - CADisplayLink (main runloop common mode) 로 sequential pulse opacity 갱신
//   - period 1.6s, offset 0.5s, pulse = sin(phase/0.4 * π) (phase < 0.4 일 때만)
//   - opacity = 0.55 + pulse * 0.45  → 각 chevron material instance 의 transparency 로 적용

final class PathChevronController {

    // MARK: - 상수

    /// chevron 외곽 path (test.html 참조). UIBezierPath 단위는 m 가까운 비율 — extrusionDepth 0.16 와 함께 실측 크기 약 2m × 0.9m × 0.16m.
    private static let chevronExtrusionDepth: CGFloat = 0.16
    /// chevron 노드 scale. 메시 자체만 축소 — 분포 spacing 은 미변경.
    private static let chevronScale: Float = 0.5
    /// chevron 분포 spacing (m).
    private static let spacing: Float = 2.5
    /// 각 segment 시작 지점 offset (m). 너무 가까운 첫 chevron 회피.
    private static let segmentStartOffset: Float = 1.0
    /// 각 segment 끝 지점 padding (m). 마지막 chevron 이 다음 segment 와 겹치지 않도록.
    private static let segmentEndPadding: Float = 0.5
    /// segment 가 너무 짧으면 chevron 배치 skip 하는 임계 (m).
    private static let minSegmentLength: Float = 1.5
    /// 동시 표시 chevron 최대 개수.
    private static let maxVisibleEntries: Int = 2
    /// 가장 앞 chevron 통과 판정 거리 (m, XZ).
    private static let passThresholdXZ: Float = 1.0
    /// 펄스 애니메이션 주기 (s).
    private static let pulsePeriod: Double = 1.6
    /// 펄스 애니메이션 시작 오프셋 (s).
    private static let pulseOffset: Double = 0.5

    // MARK: - 분포 단위

    /// setRoute 에서 산출한 chevron 배치 후보 1개. spawn 시점에 actual SCNNode 로 인스턴스화.
    private struct DistributionPoint {
        let position: simd_float3   // chevron world position (Y 는 floorY + height/2 + ε)
        let yaw: Float              // SceneKit Y 회전각 (rad)
    }

    /// 현재 표시 중인 chevron 1개 분량.
    private struct ActiveEntry {
        let node: SCNNode
        let material: SCNMaterial   // 독립 material instance (pulse opacity 제어용)
        let distributionIndex: Int  // distribution 내 index — animation phase 계산용
        let position: simd_float3
    }

    // MARK: - 상태

    private weak var parentNode: SCNNode?
    private var distribution: [DistributionPoint] = []
    private var nextSpawnIndex: Int = 0
    private var entries: [ActiveEntry] = []
    private var isHiddenState: Bool = false

    private var displayLink: CADisplayLink?
    private var animationStartTime: CFTimeInterval = 0
    /// CADisplayLink retain cycle 회피용 weak proxy.
    /// displayLink 는 target 을 strong retain 하므로 self 를 직접 target 으로 쓰면 deinit 이 호출되지 않는다.
    /// proxy 가 controller 를 weak 으로 잡고 selector forwarding 하여 사이클 차단.
    private let displayLinkProxy = DisplayLinkProxy()

    // MARK: - 외부 인터페이스

    init() {
        displayLinkProxy.target = self
    }

    /// chevron 노드들이 추가될 부모 노드 등록. ViewController 가 sceneView 준비 후 1회 호출.
    func attach(to parent: SCNNode) {
        self.parentNode = parent
    }

    /// path 갱신 시 호출. arPoints 는 AR world 좌표계의 path 점들 (XZ 평면 진행).
    /// floorY 는 모든 chevron 의 Y 베이스. cameraPos 가 주어지면 그 뒤쪽 chevron 은 spawn 큐에서 제외.
    func setRoute(arPoints: [simd_float3], floorY: Float, cameraPos: simd_float3?) {
        // 기존 entries 제거 + 상태 리셋
        for e in entries {
            e.node.removeFromParentNode()
        }
        entries.removeAll()
        distribution.removeAll()
        nextSpawnIndex = 0

        guard arPoints.count >= 2 else {
            stopAnimationIfIdle()
            return
        }

        // chevron Y 위치 — 바닥에서 살짝 띄움 (extrusion 두께 절반 + 미세 ε)
        // scale 적용 시 실제 두께도 축소되므로 chevronScale 반영.
        let chevronY: Float = floorY + Float(Self.chevronExtrusionDepth) * Self.chevronScale / 2 + 0.005

        // 각 segment 별로 chevron 분포 계산
        for i in 0..<(arPoints.count - 1) {
            let a = arPoints[i]
            let b = arPoints[i + 1]
            let vx = b.x - a.x
            let vz = b.z - a.z
            let len = sqrt(vx * vx + vz * vz)
            guard len > Self.minSegmentLength else { continue }

            // 진행 방향 unit (XZ 평면)
            let dirX = vx / len
            let dirZ = vz / len

            // SceneKit eulerAngles.x = -π/2 + .y = yaw 적용 후 apex world 방향 = (-sin(yaw), -cos(yaw)).
            // 진행 방향 (dirX, dirZ) 가리키게 하려면 sin(yaw)=-dirX, cos(yaw)=-dirZ → yaw = atan2(-dirX, -dirZ).
            let yaw: Float = atan2(-dirX, -dirZ)

            // segment 내 chevron 위치 — startOffset 부터 (len - endPadding) 까지 spacing 간격
            var s: Float = Self.segmentStartOffset
            let endLimit: Float = len - Self.segmentEndPadding
            while s <= endLimit {
                let x = a.x + dirX * s
                let z = a.z + dirZ * s
                let pos = simd_float3(x, chevronY, z)
                distribution.append(DistributionPoint(position: pos, yaw: yaw))
                s += Self.spacing
            }
        }

        // cameraPos 가 주어지면 카메라보다 뒤쪽 chevron 은 skip — nextSpawnIndex 를 카메라 이후로 설정.
        // 판정: 각 chevron 의 진행 방향 단위벡터 d 와 (chevron - cam) 의 XZ dot 부호.
        //       dot < 0 → chevron 이 카메라 뒤 (path 방향 기준).
        if let cam = cameraPos {
            for (idx, p) in distribution.enumerated() {
                // chevron yaw 로부터 진행 방향 dir 복원 (yaw = atan2(-dx, -dz) → dx=-sin(yaw), dz=-cos(yaw))
                let dx = -sin(p.yaw)
                let dz = -cos(p.yaw)
                let fx = p.position.x - cam.x
                let fz = p.position.z - cam.z
                let dot = dx * fx + dz * fz
                if dot < 0 {
                    nextSpawnIndex = idx + 1
                }
            }
        }

        // 초기 spawn — 큐 가득 채우기
        spawnUntilFull()

        if !entries.isEmpty {
            startAnimationIfNeeded()
        } else {
            stopAnimationIfIdle()
        }
    }

    /// 1Hz 마다 ARNavigationLogic 이 호출. 첫 chevron 까지 거리 < 1m 면 제거하고 다음 spawn.
    func tickCamera(cameraPos: simd_float3) {
        guard !entries.isEmpty else {
            // entries 비었지만 distribution 남았으면 첫 spawn 시도 (예: setRoute 시점 cameraPos nil 케이스 보완)
            if nextSpawnIndex < distribution.count {
                spawnUntilFull()
                if !entries.isEmpty {
                    startAnimationIfNeeded()
                }
            }
            return
        }

        // 가장 앞 chevron 통과 판정
        if let head = entries.first {
            let dx = cameraPos.x - head.position.x
            let dz = cameraPos.z - head.position.z
            let distXZ = sqrt(dx * dx + dz * dz)
            if distXZ < Self.passThresholdXZ {
                head.node.removeFromParentNode()
                entries.removeFirst()
            }
        }

        // 큐 보충
        if entries.count < Self.maxVisibleEntries {
            spawnUntilFull()
        }

        if entries.isEmpty {
            stopAnimationIfIdle()
        }
    }

    /// 가시성 토글. 층 전환 모달 표시 시 hidden = true.
    /// displayLink 는 visible 무관하게 entries 있는 동안 유지 (다시 보일 때 phase 연속성).
    func setHidden(_ hidden: Bool) {
        isHiddenState = hidden
        for e in entries {
            e.node.isHidden = hidden
        }
    }

    /// 모든 chevron 제거 + 상태 리셋. 새 trial 진입 시 호출.
    func clear() {
        for e in entries {
            e.node.removeFromParentNode()
        }
        entries.removeAll()
        distribution.removeAll()
        nextSpawnIndex = 0
        stopAnimationIfIdle()
    }

    // MARK: - 큐 spawn / 노드 생성

    /// entries 가 maxVisibleEntries 까지 채워질 때까지 nextSpawnIndex 부터 노드 인스턴스화 + parent 부착.
    private func spawnUntilFull() {
        guard let parent = parentNode else { return }
        while entries.count < Self.maxVisibleEntries, nextSpawnIndex < distribution.count {
            let p = distribution[nextSpawnIndex]
            let (node, mat) = buildChevronNode(yaw: p.yaw)
            node.position = SCNVector3(p.position.x, p.position.y, p.position.z)
            node.isHidden = isHiddenState
            parent.addChildNode(node)
            entries.append(ActiveEntry(
                node: node,
                material: mat,
                distributionIndex: nextSpawnIndex,
                position: p.position
            ))
            nextSpawnIndex += 1
        }
    }

    /// chevron SCNNode + material 반환. SCNGeometry 는 매 인스턴스마다 새로 만들어 material 인스턴스를 독립.
    /// pulse opacity 가 entry 별 독립 phase 로 제어되어야 하므로 material 공유 X.
    private func buildChevronNode(yaw: Float) -> (SCNNode, SCNMaterial) {
        // chevron 외곽 — bezier (test.html 참조). 바닥 ^ 형상.
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -0.95, y: -0.35))
        path.addQuadCurve(to: CGPoint(x: -1.00, y: -0.22), controlPoint: CGPoint(x: -1.02, y: -0.35))
        path.addLine(to: CGPoint(x: -0.05, y: 0.50))
        path.addQuadCurve(to: CGPoint(x: 0.05, y: 0.50), controlPoint: CGPoint(x: 0, y: 0.58))
        path.addLine(to: CGPoint(x: 1.00, y: -0.22))
        path.addQuadCurve(to: CGPoint(x: 0.95, y: -0.35), controlPoint: CGPoint(x: 1.02, y: -0.35))
        path.addLine(to: CGPoint(x: 0.78, y: -0.35))
        path.addQuadCurve(to: CGPoint(x: 0.62, y: -0.29), controlPoint: CGPoint(x: 0.70, y: -0.35))
        path.addLine(to: CGPoint(x: 0, y: 0.18))
        path.addLine(to: CGPoint(x: -0.62, y: -0.29))
        path.addQuadCurve(to: CGPoint(x: -0.78, y: -0.35), controlPoint: CGPoint(x: -0.70, y: -0.35))
        path.close()

        let geo = SCNShape(path: path, extrusionDepth: Self.chevronExtrusionDepth)
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = UIColor(red: 29.0/255.0, green: 161.0/255.0, blue: 242.0/255.0, alpha: 1.0)
        mat.roughness.contents = 0.38
        mat.metalness.contents = 0.0
        mat.clearCoat.contents = 0.7
        mat.clearCoatRoughness.contents = 0.2
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        mat.transparency = 1.0
        geo.materials = [mat]

        let node = SCNNode(geometry: geo)
        node.name = "pathChevron"
        // chevron 메시 자체만 축소. 분포 spacing 은 미변경.
        node.scale = SCNVector3(Self.chevronScale, Self.chevronScale, Self.chevronScale)
        // SCNShape 는 XY 평면에 extrusion. 바닥에 눕히려면 -π/2 X 회전. 그 후 진행 방향 yaw.
        node.eulerAngles = SCNVector3(-Float.pi / 2, yaw, 0)
        // ribbon/path 보다 위에 그려져 z-fighting 방지.
        node.renderingOrder = 10
        return (node, mat)
    }

    // MARK: - 펄스 애니메이션 (CADisplayLink)

    private func startAnimationIfNeeded() {
        guard displayLink == nil else { return }
        animationStartTime = CACurrentMediaTime()
        // displayLink retain cycle 회피 — proxy 를 통한 weak forwarding.
        let link = CADisplayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimationIfIdle() {
        guard entries.isEmpty else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tickAnimation() {
        let t = CACurrentMediaTime() - animationStartTime
        let period = Self.pulsePeriod
        let offset = Self.pulseOffset

        for (i, e) in entries.enumerated() {
            // 각 entry 의 phase 는 큐 내 순서(i) 기반 — 도착 순서대로 sequential pulse.
            let rawPhase = (t - Double(i) * offset).truncatingRemainder(dividingBy: period)
            let phase = (rawPhase + period).truncatingRemainder(dividingBy: period) / period
            let pulse: Double
            if phase < 0.4 {
                pulse = sin((phase / 0.4) * .pi)
            } else {
                pulse = 0
            }
            let opacity = 0.55 + pulse * 0.45
            e.material.transparency = CGFloat(opacity)
        }
    }

    // MARK: - deinit

    deinit {
        displayLink?.invalidate()
        displayLink = nil
    }
}

// MARK: - DisplayLinkProxy
//
// CADisplayLink 는 target 을 strong retain 한다. PathChevronController 를 직접 target 으로 쓰면
// controller -> displayLink -> controller 사이클이 형성되어 deinit/invalidate 가 호출되지 않는다.
// 본 proxy 는 controller 를 weak 으로 잡고 tick selector 를 forwarding 한다.
//
// 사이클 구조:
//   controller -> proxy (strong, 멤버)
//   proxy -> controller (weak)         ← 사이클 차단
//   displayLink -> proxy (strong)
//   proxy 자체는 controller 해제 시 함께 해제됨
private final class DisplayLinkProxy {
    weak var target: PathChevronController?

    @objc func tick() {
        target?.tickAnimation()
    }
}
