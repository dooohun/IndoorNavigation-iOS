# Phase 8 클라이언트 풀스택 흐름

서버 3 endpoint + 클라 SuperPoint·매칭·PnP 인프라가 연결된 전체 측위·내비게이션 흐름.

---

## 단계별 흐름

```
[사용자: 빌딩 선택 → POI 선택 → AR 진입]
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│ 1. 첫 로컬라이즈                                          │
│ ─────────────────────────────────────────────────────── │
│  - 사용자에게 "주변을 둘러봐 주세요" 오버레이              │
│  - ARFrame N장 캡처 (yaw 분산 — Phase 8 문서 4장)        │
│  - JPEG 인코딩                                           │
│  - POST /localize/v3 (multipart)                        │
│      images=[N장], building_id=...                       │
│  - 응답:                                                 │
│      pose (tx, ty, tz, R) — 매핑 좌표계                  │
│      mapId (= scanId) — 시작 floor 식별자                │
│      floorLevel, confidence, numMatches                  │
│  - confidence 임계 미만 → 재스캔 안내                     │
└─────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│ 2. 길찾기                                                │
│ ─────────────────────────────────────────────────────── │
│  - POST /buildings/{id}/pathfinding                     │
│      startScanId = mapId (1단계 응답)                    │
│      startX/Y/Z = pose.tx/ty/tz                          │
│      destinationName = 사용자 선택 POI                   │
│      verticalPreference = ELEVATOR                      │
│  - 응답:                                                 │
│      steps[] — 폴리라인 노드 (x, y, z, floorLevel)       │
│      floorTransitions[] — 층 전환 지점                   │
│      routeMetadata                                       │
│  - 422 PATH_NOT_FOUND + STAIRS → ELEVATOR fallback 재시도│
│  - 422 SNAP_DISTANCE_EXCEEDED → 측위 정확도 부족 →        │
│      1단계 재시도 또는 사용자 안내                         │
└─────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│ 3. Feature Pack 다운로드 (패턴 A)                         │
│ ─────────────────────────────────────────────────────── │
│  - POST /buildings/{id}/feature-points/lookup           │
│      queries = steps[] 좌표 (최대 64개)                  │
│      options = { radiusM: 2.5, maxKeyframesPerQuery: 5 }│
│  - 응답:                                                 │
│      keyframes[] — base64 SuperPoint feature pack        │
│      model — extractor 메타                              │
│      stats — byteSize, totalKeypoints                    │
│  - **첫 호출 30s~1분 (cache build) → 진행 spinner 표시**  │
│  - 디코드 후 메모리 적재 (현재 mock_bundle 자리)          │
└─────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│ 4. AR 추적 (클라 단독, 서버 호출 없음)                     │
│ ─────────────────────────────────────────────────────── │
│  매 ARFrame:                                             │
│  - 클라 SuperPoint 추출 (Phase 7-1 인프라 ✓)             │
│  - 메모리 keyframes 와 cosine similarity 매칭 ✓          │
│  - best keyframe + 2D-3D 점 쌍 추출 ✓                    │
│  - DLT PnP solver 6DoF ✓                                 │
│  - 결과 pose 를 ARKit pose 와 정렬 (단계 5 미구현)        │
│  - 폴리라인 위 진행률 갱신                                │
│  - 사용자에게 다음 안내 (turn card / 도착 등 — Phase 5)   │
└─────────────────────────────────────────────────────────┘
      │ (사용자 이동에 따라 주기적)
      ▼
┌─────────────────────────────────────────────────────────┐
│ 5. 인접 keyframe Prefetch (패턴 B)                        │
│ ─────────────────────────────────────────────────────── │
│  - POST .../feature-points/lookup                       │
│      queries = [현재 위치] (1개)                         │
│      options = { radiusM: 1.5, maxKeyframesPerQuery: 3 }│
│  - 응답: 1~3 keyframe (작음, 즉시 응답)                   │
│  - LRU 메모리 윈도우에 추가 (Phase 9 청크 저장소)         │
│  - 멀어진 keyframe 제거                                  │
└─────────────────────────────────────────────────────────┘
      │
      ▼
[도착 — Phase 4 도착 UX]
```

---

## 책임 분담

| 역할 | 서버 | 클라 |
|------|------|------|
| 첫 위치 결정 | ✅ 이미지 → SP+LightGlue 매칭 | 📷 ARFrame 캡처·업로드 |
| 길찾기 | ✅ 그래프 라우팅 | — |
| Feature pack | ✅ keyframe SP feature 응답 | 💾 메모리 적재 |
| 추적 (60Hz) | — | ✅ SP 추출 + 매칭 + PnP |
| ARKit 정렬 | — | ✅ local_transform 적용 |
| 시각화 | — | ✅ 폴리라인 + 안내 |

**핵심 아이디어**: 서버는 (a) 첫 진입과 (b) feature pack 두 역할만. 추적 60Hz 는 서버 round-trip 없이 클라 단독.

---

## 현재 클라 구현 상태 (2026-05-08)

| 단계 | 상태 |
|------|------|
| 1. 첫 로컬라이즈 (V3 multipart) | ❌ 미구현 |
| 2. Pathfinding | ❌ 미구현 |
| 3. Feature pack lookup (패턴 A) | ❌ 미구현 (mock JSON 으로 대체) |
| 4-1. SuperPoint 추출 | ✅ Phase 7-1 완료 |
| 4-2. 매칭 (cosine similarity) | ✅ DescriptorMatcher 완료 |
| 4-3. 2D-3D 쌍 추출 + PnP | ✅ MatchedPointExtractor + DLTPnPSolver 완료 |
| 4-4. ARKit 정렬 | ❌ 미구현 (단계 5) |
| 4-5. 폴리라인 진행률 / 안내 | ❌ 미구현 (Phase 5/11) |
| 5. 패턴 B prefetch + LRU | ❌ 미구현 (Phase 9) |

---

## 단계별 구현 PR 분리 (제안)

| Step | 내용 | 의존 | 작업 양 |
|------|------|------|--------|
| **B1** | DTO 정의 (Localize/Pathfinding/Lookup 요청·응답 Codable) + 단위 테스트 | 없음 | 작음 |
| **B2** | NetworkManager 3 endpoint 메서드 + 모킹 응답 테스트 | B1 | 중 |
| **B3** | 첫 로컬라이즈 흐름 (ARFrame 캡처 + JPEG + multipart 업로드 + 응답 파싱 + 재시도) | B2 | 중 |
| **B4** | pathfinding 호출 + steps[] 폴리라인 변환 (현재 mock 폴리라인 자리) | B2 | 중 |
| **B5** | feature-points/lookup 패턴 A + 응답 메모리 적재 (mock bundle → 실 응답) | B2, B4 | 중 |
| **B6** | wiring (`MockBundleProvider` → `NetworkBundleProvider`) | B5 | 작음 |
| **B7** | 패턴 B 주기 prefetch + LRU (Phase 9 부분) | B6 | 큼 |

병렬 진행 가능: **B1+B2 가 끝나면 B3/B4/B5 동시 작업 가능**.

---

## 미해결 질문 요약 (서버 답 필요)

1. localize/v3 endpoint URL + `pose` 응답 형식 + 권장 이미지 개수/형식
2. pathfinding `steps[].position` 좌표계 (ARKit world 와 일치 여부)
3. lookup `viewDirection` 형식 (`[x,y,z]` 추정 확정)
4. 첫 호출 cache build 시 클라 진행률 알림 가능 여부
5. `pose` 4×4 행렬 변환 방향 (camera→world / world→camera) 명시 — 우리 PnP 와 호환성

질문 답 받으면 `DTO_PLAN.md` 의 ⚠️ 항목 정확화 후 B1 진행.
