# Phase 9: 특징점 청크 저장소 + 프리페치

## 상태

**미구현** — [Phase 6 개요](phase6_superpoint_overview.md) 참조.

## 목표

서버에서 받은 SuperPoint 청크를 메모리에 효율적으로 적재·관리하고, 사용자 위치를 따라 거리 기반 prefetch / LRU eviction 으로 hot 영역만 유지한다.

마일스톤: M3.

---

## 기능 목록

### 9-1. 신규 API: `feature-chunks`

요청 (제안):
```json
POST /buildings/{buildingId}/feature-chunks
{
  "chunkIds": ["chunk_3F_A12", "chunk_3F_A13", ...],
  "schemaVersion": 1
}
```

응답 (제안):
```json
{
  "chunks": [
    {
      "chunkId": "chunk_3F_A12",
      "floorId": "...",
      "bounds": { "minX": ..., "maxX": ..., "minY": ..., "maxY": ..., "minZ": ..., "maxZ": ... },
      "keypoints3D": [[x, y, z], ...],
      "descriptors": "<base64 float16 N×256>",
      "schemaVersion": 1
    }
  ]
}
```

### 9-2. 청크 격자 정의

- [ ] 청크 격자: floor당 10m × 10m AABB. `chunkId = "chunk_{floorLevel}_{gridX}_{gridY}"` 형태 (서버와 협의 후 확정).
- [ ] 클라이언트 측 격자 인덱싱: 경로 폴리라인을 `floor(coord / 10)` 으로 매핑해 청크 ID 집합 산출.

### 9-3. 데이터 모델 + 저장소

```swift
struct FeatureMapChunk {
    let chunkId: String
    let floorId: String
    let bounds: SimpleAABB
    let keypoints3D: [SIMD3<Float>]
    let descriptors: MLMultiArray
    let descriptorIndex: ANNIndex?  // 옵션
}

protocol FeatureMapStore {
    func loadChunks(_ ids: [String]) async throws
    func evictDistantChunks(currentPosition: SIMD3<Float>, radiusM: Float)
    func activeChunks() -> [FeatureMapChunk]
}
```

### 9-4. Hot/Cold 윈도우

- [ ] 동시 활성(hot) 청크 최대 K개 (`chunk.maxActive`, 초기 6).
- [ ] 현재 위치 ± `chunk.windowRadiusM`(25m) 내 청크만 hot.
- [ ] 윈도우 밖 청크는 LRU 디스크 캐시로 데몬화 (메모리 evict, 디스크 보존).

### 9-5. Prefetch 정책

- [ ] PoseTracker 결과로부터 진행 방향 + 속도 산출.
- [ ] 윈도우 끝까지 거리 < `chunk.prefetchTriggerM`(8m) 이면 다음 청크 묶음 비동기 prefetch.
- [ ] prefetch 실패 시 사용자에게 노출하지 않고 K초 재시도. 임계 초과 시 비치명 토스트.

### 9-6. 디스크 캐시

- [ ] 최근 방문 건물의 청크는 디스크 캐시(앱 sandbox `Caches/`) 보존.
- [ ] 캐시 키: `{buildingId}_{chunkId}_{schemaVersion}`.
- [ ] 캐시 무효화: `schemaVersion` 변경 시 일괄 삭제.

### 9-7. NetworkManager 통합

```swift
extension NetworkManager {
    func fetchFeatureChunks(
        buildingId: String,
        chunkIds: [String],
        completion: @escaping (Result<[FeatureMapChunk], Error>) -> Void
    )
}
```

---

## 파라미터

| 이름 | 초기값 | 의미 |
|------|--------|------|
| `chunk.windowRadiusM` | 25 | hot chunk 유지 반경 |
| `chunk.maxActive` | 6 | 동시 hot chunk 개수 |
| `chunk.prefetchTriggerM` | 8 | 다음 청크 prefetch 임계 거리 |
| `chunk.gridSizeM` | 10 | 청크 격자 한 변 (서버와 동일) |
| `chunk.diskCacheMaxMB` | 200 | 디스크 캐시 상한 |

---

## 완료 기준 (Definition of Done)

1. Phase 8 의 `initialChunkIds` 로 청크 다운로드 + 메모리 적재 완료.
2. 사용자 이동에 따라 hot 청크가 자동 갱신됨 (윈도우 시뮬레이터 검증).
3. K(=6) 초과 시 LRU eviction 동작 확인.
4. prefetch 가 윈도우 끝 8m 진입 시 트리거되어 신규 청크가 끊김 없이 hot 으로 승격.
5. 비행기 모드에서도 디스크 캐시된 청크는 즉시 활성화 가능.

---

## 의존성

- 선행: Phase 8 (`initialChunkIds`, schemaVersion)
- 후속: Phase 10 (PoseTracker 가 `activeChunks()` 를 매칭 대상으로 사용)

---

## 미해결 이슈

- [ ] **청크 격자 정의**: 평수 기반(10m × 10m) vs SLAM 키프레임 군집 기반. 서버 빌드 파이프라인과 합의.
- [ ] **ANN 인덱스**: brute-force(활성 6 × 1k keypoints) 가 모바일에서 충분한가, Faiss-iOS / HNSW 도입 여부.
- [ ] **오프라인 캐시 정책**: 최근 방문 건물의 1F 청크는 항상 디스크 보존? 사용자 설정 노출?
- [ ] **descriptor 메모리 사이즈**: 청크당 평균 keypoints 수 가정 (예: 1k) 가 실제로 어느 정도일지 서버 데이터로 검증.
