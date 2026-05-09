# Phase 2: 온디바이스 SuperPoint + LightGlue 추출 인프라

## 상태

**구현됨 (M1 완료)** — Core ML SuperPoint 추출 + Core ML LightGlue 매칭 모두 mlpackage 로드·추론 동작. Phase 3~5 의 모든 측위·매칭 흐름이 본 인프라를 호출한다.

## 목표

ARFrame 한 장에서 keypoints + L2 정규화된 256-d descriptor 를 뽑고, 두 frame 간 학습된 매칭(LightGlue)을 수행하는 온디바이스 추론 레이어. 모든 후속 phase 의 입력원.

---

## 현재 구현

### 2-1. SuperPoint 추출 (`SuperPointExtractor.swift`)

| 항목 | 값 |
|------|-----|
| 입력 해상도 | 480 × 640 (`PixelBufferPreprocessor` 가 회전·crop·리사이즈) |
| 출력 keypoints | `(u, v, score)` 픽셀 좌표 (입력 해상도 기준), 최대 1024개 |
| 출력 descriptors | `MLMultiArray (N × 256, float16)`, 행 단위 L2 정규화 |
| 모델 파일 | `IndoorNavigation-iOS/SuperPoint.mlpackage` |
| 구현 클래스 | `SuperPointExtractorML` (운영) / `SuperPointExtractorStub` (mlmodel 미가용 fallback) |

호출 인터페이스:
```swift
protocol SuperPointExtracting: AnyObject {
    func extract(image: CVPixelBuffer, intrinsics: simd_float3x3,
                 timestamp: TimeInterval, orientation: InputOrientation) -> SuperPointFrame
    func warmUp()
}
```

### 2-2. LightGlue 매칭 (`Matching/LightGlueMatcherEngine.swift`)

| 항목 | 값 |
|------|-----|
| 정적 keypoint 한도 | **1024 고정** (변환 스크립트가 박음. depth/width confidence·flash 비활성) |
| 디스크립터 차원 | 256 |
| 입력 | `keypoints0/1`, `descriptors0/1`, `image_size0/1` |
| 출력 | `matches0 (1×1024 Int32, -1=no match)`, `scores0 (1×1024 Float16, 0..1)` |
| 모델 파일 | `LightGlueMatcher.mlpackage` (Core ML 자동 생성 클래스 `LightGlueMatcher`) |
| 변환 스크립트 | `tools/lightglue_to_coreml.py` |

Match 출력:
```swift
struct Match {
    let queryIdx: Int     // keypoints0 인덱스
    let refIdx: Int       // keypoints1 인덱스
    let score: Float      // sigmoid 0..1
}
```

### 2-3. 추론 cadence (`InferenceCadenceController.swift`)

- 현재 동작: 추적 메인 루프에서 **매 2초** LightGlue 매칭 (커밋 `5b8a968`, `90fcf1b`).
- 매 frame 매칭은 main 스레드 점유 차단 위해 비활성화 (커밋 `69e4645`).
- cadence 컨트롤러는 별도 분리되어 있으나, 현재 호출부는 `ARNavigationLogic` 의 타이머에 직결.

### 2-4. 보조 모듈

| 파일 | 책임 |
|------|------|
| `Preprocessing/PixelBufferPreprocessor.swift` | ARFrame → 480×640, orientation 처리 |
| `Decoding/SuperPointHeatmapDecoder.swift`, `DescriptorSampler.swift` | mlpackage raw 출력 후처리 |
| `Models/SuperPointFrame.swift` | 추출 결과 컨테이너 |
| `Models/LocalizationBundle.swift` | keyframe pack (Phase 3 응답 적재) |
| `__DebugOverlay__/` | keypoint 시각화, 프레임 dump 헬퍼 (production 배포 전 분리) |

### 2-5. 검증 결과 (LightGlue, 2026-05-08)

- mock keyframe 끼리 가까운 pair (~0.1m): matches **440~530**, score 0.84
- 클라 dump 2장 vs mock keyframe: matches > 168, best score 0.62~0.68
- Descriptor L2 norm 1.000, FP16 양자화 영향 미미 → place recognition 정상
- 결론: 단순 NN+ratio 매처 한계 확정. LightGlue 도입으로 클라 단독 측위 가능 입증.

---

## 미해결·향후 작업

- [ ] **추론 cadence 정책 정리** — 현재 `ARNavigationLogic` 안에 박힌 1~2s 타이머를 `InferenceCadenceController` 로 일원화.
- [ ] **디버그 dump 헬퍼 분리** — `__DebugOverlay__/SuperPointFrameDumper`, dump UI 버튼 production 빌드에서 제외.
- [ ] **Stub fallback 정책** — `SuperPointExtractorStub` 는 mlpackage 미가용 디바이스 fallback. 운영 배포 시 명시적 에러로 전환할지 결정.
- [ ] **schemaVersion 운영** — SuperPoint 가중치 변경 시 서버 keyframe descriptor 재구축 + 강제 업데이트 정책.

---

## 의존성

- 후속: Phase 3 (V3 localize 가 SuperPointFrame 4~5장 묶어 전송하지 않음 — V3 는 multipart 이미지 업로드. extractor 는 Phase 4 추적 매 tick 에서만 호출).
- 외부: 서버 keyframe descriptor 와 동일 SuperPoint 가중치 사용 보장.
