# Phase 7: SuperPoint 추출 인프라 (온디바이스)

## 상태

**미구현** — [Phase 6 개요](phase6_superpoint_overview.md) 참조.

## 목표

ARFrame 이미지에서 SuperPoint keypoints + descriptors 를 온디바이스 Core ML 추론으로 추출하는 인프라를 마련한다. Phase 8 (서버 로컬라이즈), Phase 10 (PnP 추적) 의 입력원이 된다.

마일스톤: M1.

---

## 기능 목록

### 7-1. Core ML 모델 통합

- [ ] SuperPoint 가중치를 Core ML(.mlmodel/.mlpackage) 로 변환하여 `IndoorNavigation-iOS/Resources/SuperPoint.mlmodel` 로 번들링.
- [ ] 입력 텐서 사양 확정: 그레이스케일, 해상도(예: 480×640), 정규화 범위.
- [ ] 출력 텐서: heatmap (keypoint score) + descriptor map. 디코딩 단계(NMS, top-K) 클라이언트에서 구현.
- [ ] 앱 시작 시 lazy init, 첫 ARFrame 도달 전 워밍업 1~2회 추론으로 ANE 핫스타트.

### 7-2. SuperPointExtractor

```swift
protocol SuperPointExtracting {
    func extract(image: CVPixelBuffer, intrinsics: simd_float3x3, timestamp: TimeInterval) -> SuperPointFrame
}

struct SuperPointFrame {
    let intrinsics: simd_float3x3
    let timestamp: TimeInterval
    let keypoints: [SIMD3<Float>]   // (u, v, score)
    let descriptors: MLMultiArray   // N × 256, float16
}
```

- [ ] CVPixelBuffer 전처리 (그레이스케일, 리사이즈, 정규화)
- [ ] Core ML 추론 → heatmap → NMS → top-K (`maxKeypoints` 상한) → bilinear sampling 으로 descriptor 추출
- [ ] descriptor L2 정규화 후 float16 양자화

### 7-3. 추론 빈도 적응

| 상황 | Hz |
|------|-----|
| 정지 / 천천히 이동 (< 0.3 m/s) | 1~2 |
| 일반 보행 | 5 |
| 회전 중 또는 신뢰도 NG 직후 | 10 |

- [ ] ARKit camera transform 의 변위 + yaw 변화율 기반 상황 분류
- [ ] 디바이스 온도(`ProcessInfo.thermalState`) / 배터리 상태에 따라 상한 감쇠
- [ ] 호출자(Phase 10) 가 빈도를 override 할 수 있는 hint API 노출

### 7-4. 검증 시각화 (디버그 빌드)

- [ ] AR 카메라 프리뷰 위에 keypoint 점 오버레이 (디버그 토글)
- [ ] 평균 추론 시간(ms), keypoint 수를 화면에 HUD 로 표시
- [ ] 단일 정지 장면에서 100프레임 추론 후 평균 ms / σ 측정 로그

---

## 데이터 모델

`SuperPointFrame` (위 7-2 참조).

descriptor 규약 — Phase 8·9 와 일치 필요:
- 차원: 256
- 정밀도: float16 (저장·전송 모두)
- 정규화: L2

---

## 파라미터

| 이름 | 초기값 | 의미 |
|------|--------|------|
| `superpoint.maxKeypoints` | 512 | 프레임당 keypoint 상한 |
| `superpoint.scoreThreshold` | 0.005 | NMS 전 최소 score |
| `superpoint.nmsRadiusPx` | 4 | NMS 반경 |
| `superpoint.inferenceHzWalking` | 5 | 보행 중 추론 주파수 |
| `superpoint.inferenceHzTurning` | 10 | 회전·신뢰도 NG 직후 |
| `superpoint.inputSize` | 480×640 | 추론 해상도 |

---

## 완료 기준 (Definition of Done)

1. 디버그 빌드에서 카메라 프리뷰 위에 SuperPoint keypoint 오버레이가 표시된다.
2. 정지 상태 100프레임 평균 추론 시간이 단말 기준 100ms 이하 (iPhone 14 Pro 기준).
3. 보행 중 5Hz 안정 유지, 30분 사용 시 발열로 인한 자동 감쇠 동작 확인.
4. descriptor 차원 256·float16·L2 정규화 보장.

---

## 의존성

- 후속: Phase 8 (서버 로컬라이즈가 동일 descriptor 규약 사용), Phase 10 (PnP 매칭 입력)

---

## 미해결 이슈

- [ ] **SuperPoint 변종 선택**: 원조 SuperPoint vs LightGlue 매칭 vs XFeat 등 경량 대안. 추론 비용·매칭 정확도·라이선스 트레이드오프.
- [ ] **descriptor 정밀도**: float32 vs float16 vs int8 양자화. 메모리 ↔ 매칭 품질.
- [ ] **배터리·발열**: 5~10Hz Core ML 추론이 보행 30분 사용에서 견디는지 단말 실측.
- [ ] **프라이버시 검증**: descriptor 전송이 이미지 전송 대비 프라이버시 이점이 있다는 점을 고지/검증.
