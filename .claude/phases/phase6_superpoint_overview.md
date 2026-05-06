# Phase 6: SuperPoint 온보드 내비게이션 — 개요 (전면 재설계)

## 상태

**미구현 (신규 아키텍처)** — Phase 2~5의 VPS 단발 로컬라이즈 + ARKit pose 적분 기반 내비게이션을 폐기하고, 클라이언트·서버 양쪽에서 SuperPoint 특징점을 사용하는 지속적 매칭 기반 구조로 전면 교체한다.

본 문서는 **개요·아키텍처·롤아웃**만 다룬다. 모듈별 상세는 Phase 7~11을 참조한다.

---

## 변경 동기

기존 구조의 한계:
1. 단발 로컬라이즈 + ARKit pose 적분 → 장거리·장시간 이동 시 IMU 드리프트 누적.
2. 재로컬라이즈 부재 → 길 잃음·추적 실패 복구 불가.
3. 매번 multipart 이미지 업로드 → 네트워크 RTT 가 사용자 체감 지연.

신규 구조의 의도:
- 온보드 SuperPoint 추론 + 메모리상 특징점 DB와의 PnP 6DoF 재추정으로 매 프레임 가까운 빈도로 정확한 자기 위치 갱신.
- 체크포인트(행동 요구 지점) 단위 안내로 사람 인지 가능한 단위에서만 UX 트리거.
- 서버는 (a) 최초 로컬라이즈, (b) 메모리 청크 프리페치/리페치 두 역할만.

---

## 핵심 아키텍처

```
┌─────────────────────────────────────────────────────────────────────┐
│  ARNavigationViewController  (UI 호스팅, Phase 4·5 오버레이 유지)   │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  NavigationCoordinator         상태 머신 + 모든 모듈 오케스트레이션  │
└─────────────────────────────────────────────────────────────────────┘
   │            │              │             │              │
   ▼            ▼              ▼             ▼              ▼
┌──────┐  ┌──────────┐  ┌──────────────┐  ┌──────────┐  ┌────────────┐
│ARKit │  │SuperPoint│  │FeatureMap    │  │PoseTrack │  │Checkpoint  │
│Sess. │  │Extractor │  │ChunkStore    │  │er(PnP)   │  │Engine      │
└──────┘  └──────────┘  └──────────────┘  └──────────┘  └────────────┘
                              │                              │
                              ▼                              ▼
                       ┌──────────────┐              ┌──────────────┐
                       │NetworkManager│              │GuidanceDir.  │
                       │(localize +   │              │(Phase 5 UX)  │
                       │ chunk fetch) │              └──────────────┘
                       └──────────────┘
```

| 모듈 | 책임 | 담당 Phase |
|------|------|-----------|
| `SuperPointExtractor` | ARFrame → keypoints + descriptors (Core ML) | [Phase 7](phase7_superpoint_extractor.md) |
| 서버 SuperPoint 로컬라이즈 | 첫 위치 특정 + 재로컬라이즈 | [Phase 8](phase8_superpoint_localize.md) |
| `FeatureMapChunkStore` | 청크 적재·LRU·prefetch | [Phase 9](phase9_feature_chunk_store.md) |
| `PoseTracker` | PnP 6DoF + ARKit drift 보정 | [Phase 10](phase10_pose_tracker.md) |
| `CheckpointEngine` + `GuidanceDirector` 입력 교체 + 복구 | 체크포인트·UX 트리거·길 잃음 복구 | [Phase 11](phase11_checkpoint_guidance.md) |

---

## 상태 머신 (NavigationCoordinator)

```
[idle]
   │ start()
   ▼
[scanningInitial]            ← Phase 2 스캔 UI
   │ localize success
   ▼
[fetchingRoute]
   │ route received
   ▼
[fetchingInitialChunks]
   │ chunks loaded
   ▼
[tracking] ─────────────────────────┐
   │   trackingFailure 5s            │
   │   ▼                             │
   │ [relocalizing] ─ success ───────┘
   │
   │ floor transition reached
   ▼
[floorTransitionInteraction]   ← Phase 3
   │ resumed on new floor
   ▼
[tracking]
   │ arrival checkpoint reached
   ▼
[arrived]                      ← Phase 4
```

---

## 단계적 도입 (Rollout)

| 마일스톤 | 내용 | Phase |
|----------|------|-------|
| M1 | SuperPoint 추출 인프라 단독 동작 (keypoint 오버레이 검증) | Phase 7 |
| M2 | 신규 서버 로컬라이즈 동작, 기존 `localize` 와 결과 비교 | Phase 8 |
| M3 | 청크 저장소 + LRU 윈도우 + prefetch | Phase 9 |
| M4 | PoseTracker 메인 루프, ARKit drift 그래프 검증 | Phase 10 |
| M5 | CheckpointEngine + Phase 5 UX wiring | Phase 11 |
| M6 | 길 잃음 복구 + Phase 3·4 통합, 기존 측위 코드 제거 | Phase 11 |

각 마일스톤은 별도 브랜치 + PR. M5 완료 시점에 기존 `ARNavigationLogic` 측위 코드를 제거.

---

## 호환성 정책

Phase 2~5 의 기능 요구사항(시각 경로 렌더링, 헤딩 정렬 가이드, 턴 카드, 풀스크린 회전 안내, 도착 UX, 층 전환)은 **그대로 유지**. 본 Phase 6~11 은 측위·매칭·체크포인트 레이어만 갈아끼운다.

- Phase 5 UX 입력 소스를 `PoseTracker` 결과로 교체 (Phase 11)
- Phase 3 층 전환 트리거를 체크포인트로 통합 (Phase 11)
- Phase 4 도착 트리거를 `arrival` 체크포인트로 통합 (Phase 11)
- 시각 경로 렌더링(리본·쉐브론) 은 SceneKit 헬퍼로 추출해 살림. 입력만 새 pose 시스템에서.

---

## 관련 파일 (전체 마일스톤 합산)

신규 디렉토리: `IndoorNavigation-iOS/Tracking/`
- `SuperPointExtractor.swift`, `FeatureMapChunkStore.swift`, `PoseTracker.swift`, `CheckpointEngine.swift`, `NavigationCoordinator.swift`
- `Models/` (`SuperPointFrame`, `FeatureMapChunk`, `Checkpoint`, `PoseEstimate`)
- `Resources/SuperPoint.mlmodel`

수정:
- `NetworkManager.swift` — 신규 엔드포인트 2개
- `ARNavigationViewController.swift` — `NavigationCoordinator` 호스팅
- `Guidance/GuidanceDirector.swift` — 입력 소스 교체
- `CoordinateTransformer.swift` — 정렬 행렬 정리

폐기 (M6 시점):
- `ARNavigationLogic.swift` 의 단발 로컬라이즈 + ARKit pose 적분 측위 로직

---

## 의존성

- 서버 측: 신규 엔드포인트 2개(`localize-sp`, `feature-chunks`) 합의 + 청크 빌드 파이프라인. Phase 8·9 시작 전 합의 필수.
- 모델: SuperPoint Core ML 변환본 + descriptor 규약 클라이언트·서버 동일 보장.
- Phase 3, 4, 5: 인터렉션·UX 그대로. 입력만 본 Phase 결과로 교체.
