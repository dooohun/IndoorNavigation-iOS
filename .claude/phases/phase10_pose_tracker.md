# Phase 10: 온보드 Pose 추적 (PnP 6DoF)

## 상태

**미구현** — [Phase 6 개요](phase6_superpoint_overview.md) 참조.

## 목표

매 ARFrame 가까운 빈도로 SuperPoint feature ↔ 활성 청크 DB 매칭 + PnP 로 6DoF world pose 를 재추정한다. ARKit pose 의 누적 drift 를 보정하고, 신뢰도 NG 시 Phase 8 재로컬라이즈로 위임한다.

마일스톤: M4.

---

## 기능 목록

### 10-1. PoseTracker 메인 루프

매 호출마다:
1. **Phase 7 SuperPointExtractor 호출** → `SuperPointFrame`
2. **Phase 9 활성 청크 descriptors 와 매칭**
   - mutual nearest neighbor (양방향 최근접)
   - Lowe ratio test (e.g. 0.8)
3. **2D-3D 대응쌍 → solvePnPRansac**
   - OpenCV (또는 순수 Swift PnP 구현). iOS 에서는 OpenCV.framework 사용 또는 자체 구현 검토.
4. **신뢰도 평가**:
   - inlier 수 ≥ `pnp.minInliers`
   - 평균 reprojection error ≤ `pnp.maxReprojectionPx`
   - 직전 pose 와의 변위가 물리적 가능 범위 (이상치 탐지)
5. **신뢰도 OK** → world pose 갱신 + ARKit drift 보정 행렬 업데이트
6. **신뢰도 NG** → ARKit pose 에 일시 의존 + 적응 빈도 상승 + 누적 시간 추적

### 10-2. 인터페이스

```swift
protocol PoseTracking {
    func track(frame: SuperPointFrame, arkitPose: simd_float4x4) -> PoseEstimate
    var confidenceState: PoseConfidenceState { get }
}

struct PoseEstimate {
    let worldTransform: simd_float4x4
    let confidence: Double
    let inlierCount: Int
    let reprojectionErrorPx: Double
    let timestamp: TimeInterval
}

enum PoseConfidenceState {
    case ok
    case degraded(consecutiveNGSec: Double)
    case lost
}
```

### 10-3. ARKit Drift 보정

- [ ] world pose ↔ ARKit world 사이의 정렬 행렬 `T_align` 보유.
- [ ] PoseTracker 신뢰도 OK 일 때마다 EMA 로 `T_align` 업데이트 (급격한 점프 방지).
- [ ] 신뢰도 NG 동안에는 `T_align` 고정 + ARKit pose 그대로 적용.
- [ ] 시각 경로 렌더링·체크포인트 거리 계산은 모두 `T_align` 적용 후 좌표 사용.

### 10-4. 추론 빈도 협업 (Phase 7)

- [ ] `confidenceState` 변화에 따라 Phase 7 `SuperPointExtractor` 의 빈도 hint 갱신.
  - `ok` → 5Hz
  - `degraded` → 10Hz
  - `lost` → Phase 8 재로컬라이즈 위임 (PoseTracker 는 일시 정지)

### 10-5. 검증 시각화 (디버그 빌드)

- [ ] PoseTracker world pose vs ARKit world pose drift 그래프 (시간축).
- [ ] inlier 수, reprojection error 의 시계열 로그.
- [ ] 매칭 시각화 (디버그 토글): 현 프레임 keypoint ↔ 매칭된 청크 keypoint 연결선.

---

## 파라미터

| 이름 | 초기값 | 의미 |
|------|--------|------|
| `pnp.minInliers` | 25 | PnP 신뢰 inlier 최소값 |
| `pnp.maxReprojectionPx` | 2.0 | 평균 reprojection error 상한 |
| `pnp.ransacIterations` | 200 | RANSAC 반복 |
| `match.ratioThreshold` | 0.8 | Lowe ratio test |
| `match.maxMatches` | 256 | 프레임당 매칭 상한 |
| `align.emaAlpha` | 0.2 | drift 보정 EMA 계수 |
| `tracking.maxJumpM` | 1.5 | 직전 pose 대비 최대 변위 (이상치 컷) |

---

## 완료 기준 (Definition of Done)

1. 보행 중 5Hz 이상으로 PnP pose 갱신 + ARKit drift 보정 동작 확인.
2. 단일 floor 30m 경로 기준, 끝까지 시각 경로 어긋남이 ±0.5m 이내 유지.
3. 신뢰도 NG 5초 누적 시 `lost` 상태 전이 + Phase 8 재로컬라이즈 위임.
4. drift 그래프에서 ARKit-only 대비 PoseTracker 보정 결과의 정확도 향상이 가시적.

---

## 의존성

- 선행: Phase 7 (SuperPointFrame), Phase 9 (activeChunks)
- 후속: Phase 11 (CheckpointEngine 가 `PoseEstimate` 를 입력으로 사용)
- 외부: OpenCV-iOS (또는 순수 Swift PnP) — 결정 필요.

---

## 미해결 이슈

- [ ] **OpenCV vs 자체 PnP**: 라이선스(BSD)·바이너리 크기·성능. iOS 앱 크기 영향 평가.
- [ ] **매칭 가속**: brute-force 가 활성 6 × 1k keypoints × 256d 에서 5Hz 가능한가, Metal/SIMD 최적화 필요 여부.
- [ ] **이상치 컷 임계**: 직전 pose 대비 1.5m 변위가 빠른 회전·뜀에서 false positive 일지.
- [ ] **층 식별**: PoseTracker 가 floor 변경을 감지할 수 있나, 아니면 `floorTransition` 체크포인트로만 처리?
