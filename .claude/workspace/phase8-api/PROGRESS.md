# Phase 8 진행 상태 (2026-05-08 박제)

후속 세션은 본 문서로 부터 시작하면 됨. 현재까지 작업 누적 + 결정 분기 + 추천 진로 정리.

---

## 누적 커밋 (14개+)

```
(B4 — 후속 SHA 채움)
docs(phase8-api): PROGRESS B4 완료 박제                          ← B4 #3
feat(phase8-b4): startV3Pathfinding wiring + handleLocalizeV3Success 분기 교체  ← B4 #2
feat(phase8-b4): PathfindingResponse → [PathStep] 어댑터 + 단위 테스트  ← B4 #1
98ddb01 feat(phase8-b3): V3 측위 응답 처리 + ARKit 정렬 통합  ← B3
7d39129 refactor(phase8-b3): mock attemptPnP UserDefaults 토글로 분리 (V3 통합 사전 정리)
083fe93 feat(phase8-b3): LocalizeV3Pose → simd_float4x4 변환 헬퍼 + 단위 테스트
6c67861 docs(phase8-api): 진행 상태 + 다음 단계 결정 박제 (세션 정리)
bd23ef7 feat(phase8): RANSAC PnP solver + Lowe ratio test (outlier 면역 시도)
e7146cc docs(phase8-api): 서버 3 endpoint 사양 + 풀스택 흐름 + DTO 계획
3cb0131 feat(phase8): ARNavigationLogic 에 PnP 호출 통합
39ef045 feat(phase8): DLT PnP solver + 2D-3D 점 쌍 추출 인프라
f5d4fb6 feat(phase8): InputOrientation 추가 + portrait 회전 처리
8d642e8 feat(phase8): mock bundle cosine similarity 매칭 통합 + orientation 진단
fe5a06a feat(phase8): mock bundle JSON 인프라 (Codable + 5kf mock)
aacfbfb feat(phase7-1): 서버 SuperPoint 매핑 형식과 클라 추출 동기화 (전 단계)
```

(B1/B2 NetworkManager 메서드 + DTO 정의 커밋은 이전 세션에서 합쳐짐)

## 현재까지 완성된 인프라 (✓)

- **Phase 7-1 완료** — Core ML SuperPoint 추출, 960×540 입력, 발열 안정 (Phase 7-1 워크스페이스 참고)
- **Mock bundle JSON 파이프라인** — `tools/npz_to_json.py`, `LocalizationBundle` Codable, `MockBundleProvider`
- **InputOrientation 회전 처리** — portrait 자연 자세 호환 (매칭 영역 안 30%+ 매칭률 입증)
- **DescriptorMatcher** — vDSP_mmul cosine similarity + Lowe ratio test
- **PnP 인프라** — `MatchedPointPair`, `DLTPnPSolver` (LAPACK SVD), `RansacPnPSolver`
  - synthetic 단위 테스트 (clean / outlier / etc.) 모두 PASS
- **B1/B2 — DTO + NetworkManager 메서드** (이전 세션) — `LocalizeV3Request/Response`, `PathfindingRequest/Response`, `LookupRequest/Response`, 3 메서드 모두 모킹 응답 검증
- **B3 완료 — V3 측위 흐름 ARNavigationLogic 통합**
  - `LocalizeV3Pose` → `simd_float4x4` 변환 helpers (matrix/quaternion 양방향, fallback)
  - `useV3Localize` 토글 + `sendToServerV3` + `handleLocalizeV3Success`
  - `localizedScanId` 캐싱 (B4 인계)
  - `attemptPnP` 는 `#if DEBUG + UserDefaults("useMockPnP")` 로 격리 (mock 디버깅·LightGlue base 보존)
  - 단위 테스트 12 통과 (5 신규 + 7 기존)
- **B4 완료 — V3 pathfinding 호출 wiring + 응답 어댑터**
  - `PathfindingResponse.toPathSteps()` extension (DTO → 기존 [PathStep])
  - `useV3Pathfinding` 토글 + `startV3Pathfinding` 메서드 (NetworkManager.pathfinding 호출 + drawPathNodes 어댑팅)
  - `handleLocalizeV3Success` 의 `else` 분기 교체 (`startCoordinateRoute` → `startV3Pathfinding`)
  - floorTransitions[] 는 `detectFloorTransition` 키워드 매칭으로 자동 처리 (별도 매핑 불요)
  - 단위 테스트 15 통과 (3 신규 + 12 기존)

## 막힌 지점 — 실측 PnP 정확도 (이전 결론)

LightGlue 검증으로 매처 한계 확정. C 트랙(LightGlue Core ML 변환) 병행 진행 중.



여러 시도 결과:

| 설정 | 결과 |
|------|------|
| DLT 단독 (outlier 무방어) | pairs 100~150, reproj **1000~40000px** (의미 없음) |
| RANSAC + thr 5px / minIn 12 | best inlier **0~2** → 100% nil |
| RANSAC + thr 20px / minIn 8 | best inlier **0~4** → 거의 nil, 가끔 성공 시 reproj 1000+ |
| + Lowe ratio 1.3 | matched 100~150 → **5~13 폭락** (true positive 까지 잘림) |

**진단 결론 (커밋 bd23ef7 메시지에 자세히)**:
- 매칭 자체는 정상 (matched 30% 이상, best_kf 일관)
- 그러나 **단순 cosine similarity NN 매칭의 false positive 가 압도적**
- top-1 / top-2 점수 분포가 좁아서 (≈ 같은 값) ratio test 도 효과 제한
- **LightGlue 같은 학습 매처 없이는 정밀 PnP 측위 어려움**

## 새로 받은 정보 — 서버 endpoint 3개

서버 사양 워크스페이스에 박제됨 (`SERVER_API.md` / `CLIENT_FLOW.md` / `DTO_PLAN.md`):

1. **POST /localize/v3** — 이미지 multipart 업로드 → 서버가 SP+LightGlue 매칭 → pose, mapId, floorLevel
2. **POST /buildings/{id}/pathfinding** — startScanId + 좌표 + destinationName → steps[] (폴리라인)
3. **POST /buildings/{id}/feature-points/lookup** — 좌표 배열 → keyframe SP feature pack (route_bundle.npz 형식)

⚠️ 미해결 5개 (서버 팀 답 필요): URL 정확화 / pose 응답 형식 / pathfinding 좌표계 / cache build 진행률 / pose 변환 방향

---

## 다음 결정 분기 — B3 완료, 다음은 B4 + C 트랙 병행

### B 트랙 진행 상황

- **B1** ✅ DTO 정의 (이전 세션)
- **B2** ✅ NetworkManager 메서드 (이전 세션, 모킹 응답 검증)
- **B3** ✅ V3 흐름 (4-5장 캡처 + multipart 업로드 + 응답 처리)
- **B4** ✅ pathfinding 호출 wiring (`localizedScanId` + translation → `PathfindingRequest` → drawPathNodes 어댑터)
- **B5** ▶️ 다음 — lookup 호출 + mock bundle 자리에 실 응답
- **B6** wiring (`MockBundleProvider` → `NetworkBundleProvider`)
- **C 트랙 (병행)** — LightGlue iOS 통합 (PyTorch → Core ML 변환 + Swift 추론 인터페이스)

### C 트랙 (병행 진행 중)

- LightGlue PyTorch → Core ML 변환 (며칠)
- Swift 추론 인터페이스
- 본격 정밀 측위 가능
- 큰 작업, 별도 PR

---

## 추천 진로 — B 진행

이유:
1. 단순 NN 매칭은 정밀 측위 본질적 한계 (LightGlue 없이는)
2. 서버 V3 가 LightGlue 매칭 + 정확한 pose 제공 — 그걸 바로 사용
3. 추적은 ARKit pose 신뢰 + 주기 V3 재호출 — 실용적
4. B 인프라 끝나면 풀스택 동작 가능. LightGlue 는 그 후 별도 진행

### 후속 세션 시작점

1. `.claude/workspace/phase8-api/SERVER_API.md` 읽기 — 3 endpoint 사양
2. `.claude/workspace/phase8-api/DTO_PLAN.md` 읽기 — Codable struct 잠정 정의
3. **B1 시작** — `IndoorNavigation-iOS/Network/SuperPointDTO.swift` (또는 비슷한 위치) 신규
   - LocalizeV3Request/Response, PathfindingRequest/Response, LookupRequest/Response
   - 단위 테스트: 기존 `mock_bundle.json` 으로 디코딩 검증 (LookupResponse 와 형식 매핑)
4. **B2** — `NetworkManager` 에 3 메서드 추가 + 모킹 응답 테스트

서버 답 받아오면 ⚠️ 미해결 항목 (특히 pose 응답 형식) 정확화 후 진행. 받기 전에는 가정으로 시작 — 답 받으면 fix.

### 보류 — 매칭/PnP 작업

`DescriptorMatcher` / `RansacPnPSolver` / `attemptPnP` 코드는 그대로 유지 (mock 디버깅 + LightGlue 도입 시 base 로 재사용).
콘솔 로그는 noisy 하니 일시 비활성화 검토 가능. 일단 그대로.

## 사용자 작업 스타일 메모 (참고)

- "얍얍" 으로 빠른 진행 선호
- 답답해할 때 핵심만 짧게 답변 원함
- 체크포인트 커밋을 의미 단위로 박는 것 선호 (3개 / 작업 단위로 자주)
- 실기기 측정 결과를 그대로 console 로그로 보내옴 — 그걸 분석해서 다음 단계 결정하는 흐름
