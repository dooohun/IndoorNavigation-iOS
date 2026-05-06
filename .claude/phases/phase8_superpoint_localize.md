# Phase 8: 서버 SuperPoint 로컬라이즈

## 상태

**미구현** — [Phase 6 개요](phase6_superpoint_overview.md) 참조.

## 목표

Phase 7 의 SuperPoint 결과를 서버에 전송해 6DoF 위치를 특정하는 신규 엔드포인트를 도입한다. 최초 진입 시점과 길 잃음 복구 시점에 호출된다.

마일스톤: M2.

---

## 기능 목록

### 8-1. 초기 스캔 → 로컬라이즈

- [ ] 스캔 안내 오버레이 표시 (Phase 2-1 UI 재사용)
- [ ] **N장의 ARFrame 캡처** (3~5장)
  - 카메라 yaw 가 충분히 분산되도록 큰 yaw delta 임계로 샘플링
- [ ] 각 프레임에 대해 Phase 7 `SuperPointExtractor.extract` 호출
- [ ] 누적된 `SuperPointFrame` 들을 `localize-sp` 엔드포인트에 전송
- [ ] 응답으로 6DoF pose + floor + 초기 청크 ID 수신 → Phase 9 청크 다운로드 트리거

### 8-2. 신규 API: `localize-sp`

요청 (제안):
```json
POST /buildings/{buildingId}/slam/v4/localize-sp
{
  "buildingId": "...",
  "schemaVersion": 1,
  "frames": [
    {
      "imageIndex": 0,
      "intrinsics": { "fx": ..., "fy": ..., "cx": ..., "cy": ... },
      "keypoints": [[u, v, score], ...],
      "descriptors": "<base64 float16 N×256>"
    }
  ]
}
```

응답 (제안):
```json
{
  "pose": { "x": ..., "y": ..., "z": ..., "qx": ..., "qy": ..., "qz": ..., "qw": ... },
  "floorId": "...",
  "floorLevel": 3,
  "confidence": 0.92,
  "initialChunkIds": ["chunk_3F_A12", "chunk_3F_A13"]
}
```

- 이미지 원본은 서버 디버그 모드에서만 동봉 (정식 배포는 특징점만).
- `schemaVersion` 으로 SuperPoint 가중치 버전 동기화 검증.

### 8-3. 재로컬라이즈 호출 정책

호출 조건:
- Phase 10 PoseTracker 신뢰도 NG 누적 5초
- Phase 11 다음 체크포인트 방향 ↔ 사용자 헤딩 ±90° 어긋남 5초 지속
- 사용자 명시적 "다시 인식" 버튼 탭

호출 동작:
- [ ] 풀스크린 안내 오버레이 (Phase 5 `HeadingAlignmentOverlayView` 재사용, 문구만 "주변을 다시 둘러봐 주세요")
- [ ] 8-1 흐름 재실행 (단, 이미 청크 적재 상태이므로 응답 즉시 추적 재개)
- [ ] 복구 성공 후 가장 가까운 체크포인트부터 안내 재개 (Phase 11 협업)

### 8-4. NetworkManager 통합

```swift
extension NetworkManager {
    func localizeWithSuperPoint(
        buildingId: String,
        frames: [SuperPointFrame],
        completion: @escaping (Result<SuperPointLocalizeResponse, Error>) -> Void
    )
}
```

- [ ] 기존 `localize` 함수와 별도. 마이그레이션 기간 동안 둘 다 유지.
- [ ] 응답 DTO `SuperPointLocalizeResponse` 신규 추가.

---

## 파라미터

| 이름 | 초기값 | 의미 |
|------|--------|------|
| `localize.scanFrameCount` | 4 | 초기 스캔 프레임 수 |
| `localize.minYawDeltaDeg` | 15 | 프레임 간 yaw 분산 최소값 |
| `localize.requestTimeoutSec` | 10 | 응답 대기 타임아웃 |
| `relocalize.failureWindowSec` | 5 | PoseTracker NG 누적 임계 |
| `relocalize.headingDeviationDeg` | 90 | 헤딩 이탈 임계 |
| `relocalize.headingDeviationWindowSec` | 5 | 헤딩 이탈 누적 시간 |

---

## 완료 기준 (Definition of Done)

1. 초기 스캔 → `localize-sp` 호출 → 6DoF pose + floor + initialChunkIds 수신 성공.
2. 동일 위치에서 기존 `localize` 와 비교했을 때 위치 오차 ±0.3m, yaw 오차 ±5° 이내.
3. PoseTracker NG 5초 지속 시 자동 재로컬라이즈 트리거 + 안내 오버레이 표시.
4. `schemaVersion` 불일치 시 명시적 에러 (앱 강제 업데이트 안내).

---

## 의존성

- 선행: Phase 7 (SuperPointExtractor)
- 후속: Phase 9 (initialChunkIds 로 청크 다운로드)
- 서버: 엔드포인트 합의 필요. 본 Phase 작업 전 합의.

---

## 미해결 이슈

- [ ] **모델 동기화**: SuperPoint 가중치 변경 시 서버 청크 descriptor 재구축 필요. `schemaVersion` 운영 정책 (강제 업데이트? 그레이스 기간?).
- [ ] **이미지 동봉 모드**: 디버그 빌드에서만 활성? 프로덕션은 절대 비활성?
- [ ] **응답 신뢰도 임계**: confidence 임계값 (예: 0.7 미만은 재시도 유도) 결정.
