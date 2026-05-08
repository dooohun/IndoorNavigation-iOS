# Phase 8 진행 상태 (2026-05-08 박제)

후속 세션은 본 문서로 부터 시작하면 됨. 현재까지 작업 누적 + 결정 분기 + 추천 진로 정리.

---

## 누적 커밋 (8개)

```
bd23ef7 feat(phase8): RANSAC PnP solver + Lowe ratio test (outlier 면역 시도)  ← 직전
e7146cc docs(phase8-api): 서버 3 endpoint 사양 + 풀스택 흐름 + DTO 계획
3cb0131 feat(phase8): ARNavigationLogic 에 PnP 호출 통합
39ef045 feat(phase8): DLT PnP solver + 2D-3D 점 쌍 추출 인프라
f5d4fb6 feat(phase8): InputOrientation 추가 + portrait 회전 처리
8d642e8 feat(phase8): mock bundle cosine similarity 매칭 통합 + orientation 진단
fe5a06a feat(phase8): mock bundle JSON 인프라 (Codable + 5kf mock)
aacfbfb feat(phase7-1): 서버 SuperPoint 매핑 형식과 클라 추출 동기화 (전 단계)
```

## 현재까지 완성된 인프라 (✓)

- **Phase 7-1 완료** — Core ML SuperPoint 추출, 960×540 입력, 발열 안정 (Phase 7-1 워크스페이스 참고)
- **Mock bundle JSON 파이프라인** — `tools/npz_to_json.py`, `LocalizationBundle` Codable, `MockBundleProvider`
- **InputOrientation 회전 처리** — portrait 자연 자세 호환 (매칭 영역 안 30%+ 매칭률 입증)
- **DescriptorMatcher** — vDSP_mmul cosine similarity + Lowe ratio test
- **PnP 인프라** — `MatchedPointPair`, `DLTPnPSolver` (LAPACK SVD), `RansacPnPSolver`
  - synthetic 단위 테스트 (clean / outlier / etc.) 모두 PASS

## 막힌 지점 — 실측 PnP 정확도

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

## 다음 결정 분기 (3 옵션)

### A. 매칭 미세 튜닝 (단기, 효과 미지수)
- ratio 1.15 ~ 1.2 중간값 시도
- 또는 절대 threshold 0.85+ 로 높임
- 효과 한계 — 본질적으로 단순 NN 한계 안 풀림

### B. 매칭/PnP 보류 + 서버 통신 인프라 우선 ★ 추천
- V3/pathfinding/lookup endpoint Swift Codable + NetworkManager 메서드
- 첫 측위는 서버가 (LightGlue 사용) 정확
- 추적은 일단 ARKit drift 따라가다 주기적 V3 재호출
- LightGlue iOS 도입은 별도 트랙
- **B1**: DTO 정의
- **B2**: NetworkManager 메서드 (모킹)
- **B3**: V3 흐름 (4-5장 캡처 + multipart 업로드)
- **B4**: pathfinding 호출
- **B5**: lookup 호출 + mock bundle 자리에 실 응답
- **B6**: wiring (`MockBundleProvider` → `NetworkBundleProvider`)
- 서버 답 받기 전 B1+B2 미리 가능

### C. LightGlue iOS 도입 (장기)
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
