import Foundation
import simd
import QuartzCore

// MARK: - 공용 타입

enum TurnDirection: Equatable {
    case left
    case right
    case uTurn
}

enum AlignmentMode {
    case initial
    case reorient
}

// MARK: - Delegate

protocol GuidanceDirectorDelegate: AnyObject {
    func guidance(_ director: GuidanceDirector, showInitialAlignment direction: TurnDirection, angle: Double)
    func guidance(_ director: GuidanceDirector, showReorient direction: TurnDirection, angle: Double)
    func guidanceDismissAlignmentOverlay(_ director: GuidanceDirector)
    func guidance(_ director: GuidanceDirector, showTurnCard direction: TurnDirection, distance: Double)
    func guidance(_ director: GuidanceDirector, updateTurnCardDistance distance: Double)
    func guidanceHideTurnCard(_ director: GuidanceDirector)
}

// MARK: - GuidanceDirector

/// 매 ARFrame tick에서 호출받아 5-1(초기 정렬)·5-2(턴 카드)·5-3(재정렬) UX 트리거 조건을
/// 평가하고 delegate 콜백으로 발행한다. UIKit/SceneKit 의존성 없음.
final class GuidanceDirector {

    weak var delegate: GuidanceDirectorDelegate?
    private(set) var isPaused: Bool = false

    // MARK: - 내부 타입

    private struct Turn {
        let position: simd_float3
        let direction: TurnDirection
    }

    // MARK: - 경로 캐시
    private var smoothedPoints: [simd_float3] = []
    private var turns: [Turn] = []

    // MARK: - 턴 카드 상태
    private var currentTurnLookupCursor: Int = 0
    private var activeTurnIndex: Int? = nil

    // MARK: - 상태 머신
    private enum State {
        case idle
        case initialAlignment
        case navigating
        case majorReorient
    }
    private var state: State = .idle
    private var initialAlignmentTriggered: Bool = false
    private var reorientStartTime: TimeInterval? = nil

    // MARK: - 임계값 상수
    private let initialShowThresholdDeg: Double = 30
    private let initialDismissThresholdDeg: Double = 15
    private let reorientShowThresholdDeg: Double = 60
    private let reorientDismissThresholdDeg: Double = 20
    private let reorientDurationSec: TimeInterval = 2.0
    private let turnAngleThresholdDeg: Double = 25
    private let turnUTurnThresholdDeg: Double = 150
    private let turnCardShowDistance: Float = 15.0
    private let turnCardPassDistance: Float = 0.8

    // MARK: - Public API

    /// 모든 상태 초기화 + delegate에 dismiss/hide 발행. 새 흐름 시작/도착/층전환 재시작 직전에 호출.
    func reset() {
        smoothedPoints = []
        turns = []
        currentTurnLookupCursor = 0
        activeTurnIndex = nil
        state = .idle
        initialAlignmentTriggered = false
        reorientStartTime = nil
        isPaused = false

        delegate?.guidanceDismissAlignmentOverlay(self)
        delegate?.guidanceHideTurnCard(self)
    }

    /// 경로 수신 직후 1회 호출. 턴 인덱스 룩업 빌드 + initialAlignment 상태 진입.
    /// ARNavigationLogic에서 RDP 단순화된 후 spline 보간된 점열을 받음. turn 판정도 같은 점열 기반.
    func setRoute(smoothedPoints: [simd_float3]) {
        self.smoothedPoints = smoothedPoints
        buildTurns(from: smoothedPoints)
        currentTurnLookupCursor = 0
        activeTurnIndex = nil
        state = .initialAlignment
        initialAlignmentTriggered = false
        reorientStartTime = nil
        isPaused = false
    }

    /// 매 0.1초 tick. ARNavigationLogic의 pathProgressTimer에서 호출.
    func update(cameraPosition: simd_float3, cameraForward: simd_float3, currentTargetWaypointIndex: Int) {
        guard !isPaused else { return }
        guard !smoothedPoints.isEmpty else { return }
        evaluate(cameraPosition: cameraPosition,
                 cameraForward: cameraForward,
                 currentTargetWaypointIndex: currentTargetWaypointIndex)
    }

    /// 층 전환 모달이 뜨는 동안 안내 UI 일시 정지.
    func pause() {
        isPaused = true
        delegate?.guidanceDismissAlignmentOverlay(self)
        delegate?.guidanceHideTurnCard(self)
    }

    /// 외부 호출용 재개 메서드(현재는 setRoute가 isPaused = false로 자동 해제).
    func resume() {
        isPaused = false
    }

    // MARK: - 턴 룩업 빌드

    /// 단순화된 점열을 한 번 순회하며 인접 두 세그먼트 각도 차가 임계값 이상인 점을
    /// turns 배열에 (위치, 방향) 쌍으로 모은다.
    private func buildTurns(from simplifiedPoints: [simd_float3]) {
        turns = []
        guard simplifiedPoints.count >= 3 else { return }
        for i in 1..<(simplifiedPoints.count - 1) {
            let prev = simplifiedPoints[i - 1]
            let cur = simplifiedPoints[i]
            let nxt = simplifiedPoints[i + 1]
            guard let v1 = normalizeXZ(simd_float2(cur.x - prev.x, cur.z - prev.z)),
                  let v2 = normalizeXZ(simd_float2(nxt.x - cur.x, nxt.z - cur.z)) else { continue }
            let angleDeg = vectorAngleSignedDeg(from: v1, to: v2)
            if abs(angleDeg) >= turnAngleThresholdDeg {
                turns.append(Turn(position: cur, direction: turnDirection(forSignedDeg: angleDeg)))
            }
        }
    }

    // MARK: - 상태 머신 평가

    private func evaluate(cameraPosition: simd_float3,
                          cameraForward: simd_float3,
                          currentTargetWaypointIndex: Int) {
        // 카메라 헤딩 XZ 투영
        let camDirXZ = normalizeXZ(simd_float2(cameraForward.x, cameraForward.z))
        guard let camDir = camDirXZ else { return }

        switch state {
        case .idle:
            return

        case .initialAlignment:
            guard let targetWp = nextWaypoint(after: currentTargetWaypointIndex) else {
                // 경로가 비정상이면 그냥 navigating으로 넘어감
                state = .navigating
                return
            }
            guard let toWp = normalizeXZ(simd_float2(targetWp.x - cameraPosition.x,
                                                     targetWp.z - cameraPosition.z)) else {
                state = .navigating
                return
            }
            let yawDelta = vectorAngleSignedDeg(from: camDir, to: toWp)

            if !initialAlignmentTriggered {
                if abs(yawDelta) >= initialShowThresholdDeg {
                    initialAlignmentTriggered = true
                    let dir = turnDirection(forSignedDeg: yawDelta)
                    delegate?.guidance(self, showInitialAlignment: dir, angle: yawDelta)
                } else {
                    // 처음부터 정면이면 initial 단계 건너뜀
                    state = .navigating
                }
            } else {
                if abs(yawDelta) <= initialDismissThresholdDeg {
                    delegate?.guidanceDismissAlignmentOverlay(self)
                    state = .navigating
                }
            }

        case .navigating:
            // 턴 카드 평가는 reorient와 독립
            evaluateTurnCard(cameraPosition: cameraPosition)

            // 큰 방향 이탈 감지 (다음 waypoint 기준)
            guard let targetWp = nextWaypoint(after: currentTargetWaypointIndex) else { return }
            guard let toWp = normalizeXZ(simd_float2(targetWp.x - cameraPosition.x,
                                                     targetWp.z - cameraPosition.z)) else { return }
            let yawDelta = vectorAngleSignedDeg(from: camDir, to: toWp)

            if abs(yawDelta) >= reorientShowThresholdDeg {
                let now = CACurrentMediaTime()
                if let start = reorientStartTime {
                    if now - start >= reorientDurationSec {
                        let dir = turnDirection(forSignedDeg: yawDelta)
                        delegate?.guidance(self, showReorient: dir, angle: yawDelta)
                        // 재정렬 동안 턴 카드는 가린다(중첩 방지)
                        delegate?.guidanceHideTurnCard(self)
                        activeTurnIndex = nil
                        state = .majorReorient
                        reorientStartTime = nil
                    }
                } else {
                    reorientStartTime = now
                }
            } else {
                reorientStartTime = nil
            }

        case .majorReorient:
            guard let targetWp = nextWaypoint(after: currentTargetWaypointIndex) else { return }
            guard let toWp = normalizeXZ(simd_float2(targetWp.x - cameraPosition.x,
                                                     targetWp.z - cameraPosition.z)) else { return }
            let yawDelta = vectorAngleSignedDeg(from: camDir, to: toWp)

            if abs(yawDelta) <= reorientDismissThresholdDeg {
                delegate?.guidanceDismissAlignmentOverlay(self)
                state = .navigating
            }
        }
    }

    /// 턴 카드 등장/거리갱신/퇴장. waypoint 인덱스에 의존하지 않고 turns 배열 기반으로만 평가.
    private func evaluateTurnCard(cameraPosition: simd_float3) {
        // (A) 활성 턴이 있는 경우: 거리 갱신 + 통과 판정
        if let activeIdx = activeTurnIndex {
            let turn = turns[activeIdx]
            let dx = cameraPosition.x - turn.position.x
            let dz = cameraPosition.z - turn.position.z
            let dist = sqrt(dx * dx + dz * dz)

            var passed = dist <= turnCardPassDistance

            // 다음 turn이 있으면 진행 방향 dot product 가드
            if !passed, activeIdx + 1 < turns.count {
                let nextTurn = turns[activeIdx + 1]
                if let progressDir = normalizeXZ(simd_float2(nextTurn.position.x - turn.position.x,
                                                             nextTurn.position.z - turn.position.z)) {
                    let toCam = simd_float2(cameraPosition.x - turn.position.x,
                                            cameraPosition.z - turn.position.z)
                    if simd_dot(progressDir, toCam) > 0 {
                        passed = true
                    }
                }
            }

            if passed {
                delegate?.guidanceHideTurnCard(self)
                activeTurnIndex = nil
                currentTurnLookupCursor = activeIdx + 1
            } else {
                delegate?.guidance(self, updateTurnCardDistance: Double(dist))
            }
            return
        }

        // (B) 활성 턴 없음: 다음 후보 평가
        if currentTurnLookupCursor < turns.count {
            let candidate = turns[currentTurnLookupCursor]
            let dx = cameraPosition.x - candidate.position.x
            let dz = cameraPosition.z - candidate.position.z
            let dist = sqrt(dx * dx + dz * dz)
            if dist <= turnCardShowDistance {
                activeTurnIndex = currentTurnLookupCursor
                delegate?.guidance(self, showTurnCard: candidate.direction, distance: Double(dist))
            }
        }
    }

    // MARK: - 헬퍼

    /// currentTargetWaypointIndex가 가리키는 다음 waypoint(없으면 nil).
    private func nextWaypoint(after currentTargetWaypointIndex: Int) -> simd_float3? {
        guard currentTargetWaypointIndex >= 0,
              currentTargetWaypointIndex < smoothedPoints.count else { return nil }
        return smoothedPoints[currentTargetWaypointIndex]
    }

    /// 단위 벡터 정규화. 영벡터면 nil.
    private func normalizeXZ(_ v: simd_float2) -> simd_float2? {
        let len = simd_length(v)
        guard len > 0.0001 else { return nil }
        return v / len
    }

    /// 두 단위 벡터 간 부호 있는 각도 (도). cross(2D 외적) 양수 → 시계 반대(여기 컨벤션상 우측).
    /// 두 입력은 XZ 평면 단위 벡터(.y 슬롯에 z 성분).
    private func vectorAngleSignedDeg(from v1: simd_float2, to v2: simd_float2) -> Double {
        let dot = simd_dot(v1, v2)
        // 2D 외적: v1.x*v2.y - v1.y*v2.x. .y 슬롯이 z이므로 결과 부호는 ARKit XZ 평면 컨벤션에 의존.
        let cross = v1.x * v2.y - v1.y * v2.x
        let rad = atan2(Double(cross), Double(dot))
        return rad * 180.0 / .pi
    }

    /// 부호 있는 각도 → 좌/우/유턴.
    private func turnDirection(forSignedDeg deg: Double) -> TurnDirection {
        if abs(deg) >= turnUTurnThresholdDeg { return .uTurn }
        return deg > 0 ? .right : .left
    }
}
