# Phase 7-1 검증 메모

> 추론 동작·정확도·성능을 단계적으로 검증한다.
> 각 항목: `목적`, `방법`, `합격 기준`, `결과(✅/❌/⏳)`.

---

## V-1. 디버그 오버레이 sanity (육안)

- **목적**: 키포인트가 격자가 아닌 실제 영상 특징(코너·텍스처)에 군집함을 확인.
- **방법**: 디버그 빌드에서 카메라를 텍스처 풍부한 벽 / 단색 천장에 번갈아 비추고 점 분포 비교.
- **합격 기준**:
  - 텍스처 풍부 영역 → 점 군집
  - 단색 영역 → 점 거의 없음
  - 카메라 회전 시 점이 같은 물리 코너를 따라 이동
- **결과**: ✅ PASS (2026-05-07, 실기기 측정)
  - 의자 메시 패턴, 책상 모서리, 천장 등기구 윤곽 → 점 군집 확인
  - 단색 책상 표면 / 흰 벽 → 점 상대적으로 적음 (미세한 노이즈성 점 일부 관찰 — score threshold 후속 튜닝 영역)
  - 격자 패턴 사라짐 — 실제 SuperPoint 추론 동작 확정

---

## V-2. 추론 시간 측정

- **목적**: Phase 7 DoD `평균 100ms 이하` 충족 여부.
- **방법**:
  - 디버그 HUD 에 직전 100프레임 평균 추론 시간(ms) 표시.
  - `extract()` 4구간 분리 프로파일링 (preprocess / prediction / decode / sample)을 console 로그로 출력 — 병목 식별용.
- **합격 기준**:
  - 평균 ≤ 100ms (iPhone 14 Pro)
  - p95 ≤ 150ms
- **결과**: ⚠️ PARTIAL (2026-05-07, 실기기 측정)
  - 평균 **270ms** (3.7Hz). DoD 100ms 미달, 현실적 사용 가능 수준 도달.
  - 단계별 평균: pre 4ms / pred 27ms / dec 195ms / samp 45ms
  - 발열 체감 없음 (이전 2840ms 시점에는 thermal throttling 누적 발열, 현재는 사이클 차단됨)
  - 이전 추세: 시작 2840ms → NMS vImage 가속 후 450ms → softmax+박싱 가속 후 270ms (10.5배 단축)

### V-2 미달 trade-off

본 PR은 **DoD 100ms 미달이지만 머지 가능**으로 판정. 사유:
- Phase 7-1 의 본질 목표 "추론 인프라 가동" 달성
- Phase 8 (서버 매칭) 정확도 측정 후 빈도 1-2Hz로 줄여도 충분할 가능성 → DoD 압박 자체가 사라질 수 있음
- 100ms 도달을 위한 BNNS Graph / Metal compute / 모델 입력 축소는 며칠 작업, Phase 8 결과 기반 의사결정 권장

---

## V-3. descriptor 규약 단위 테스트

- **목적**: `차원 256 / float16 / L2 정규화` 보장.
- **방법**: `IndoorNavigation-iOSTests/SuperPointExtractorTests.swift` 신규
  - 임의 픽셀 버퍼 입력 → `extract()` 결과 검사
  - `descriptors.shape == [N, 256]`
  - `descriptors.dataType == .float16`
  - 각 row 의 L2 norm 이 `1.0 ± 1e-3` 이내 (Float16 양자화 오차 고려 [0.997, 1.003] 사용)
- **합격 기준**: 위 3 조건 모두 통과.
- **결과**: ✅ 통과 (2026-05-07) — 임플리멘터 보고 + 리뷰어 코드 검증
  - `descriptorShape` / `descriptorDataType` / `descriptorL2Norm` / `emptyInputSafe` 4건 모두 통과
  - 추가: `SuperPointHeatmapDecoderTests` 4건(NMS·top-K·threshold·좌표 매핑) + `PixelBufferPreprocessorTests` 2건 모두 통과
  - 사용자 실기기에서 `xcodebuild test -scheme IndoorNavigation-iOS -destination ...` 으로 재실행 권장

---

## V-4. 정지 장면 repeatability

- **목적**: 동일 장면에서 키포인트가 안정적으로 같은 위치에 검출되는지.
- **방법**:
  - 카메라 고정 후 100프레임 추론
  - 첫 프레임 키포인트 기준, 이후 각 프레임에서 ±2px 이내에 동일 점이 검출된 비율 계산
- **합격 기준**: 60% 이상.
- **결과**: ⏳ 미실행

---

## V-5. descriptor 매칭 sanity

- **목적**: descriptor 가 실제로 의미 있는 표현인지 (모델이 살아있는지).
- **방법**:
  - 텍스처 풍부 정지 장면 2프레임 추출
  - 가장 가까운 keypoint 짝의 descriptor 코사인 유사도 ≥ 0.8
  - 무작위 다른 점 짝은 평균 < 0.5
- **합격 기준**: 위 두 조건.
- **결과**: ⏳ 미실행

---

## V-6. 워밍업 효과 측정

- **목적**: 첫 추론 지연 spike 가 사용자 진입 전에 흡수되는지.
- **방법**: 워밍업 ON/OFF 두 빌드에서 첫 ARFrame 도달 시점부터 첫 `extract()` 완료까지 시간 비교.
- **합격 기준**: 워밍업 ON 시 첫 추론도 평균 추론 시간 + 30ms 이내.
- **결과**: ⏳ 미실행

---

## V-7. 회귀: stub 호환

- **목적**: `SuperPointExtracting` 프로토콜 호환성 유지 — stub 으로 토글하면 기존 더미 동작 그대로.
- **방법**: DEBUG 토글로 stub 선택 후 기존 디버그 오버레이 출력이 격자 그대로 나오는지 확인.
- **합격 기준**: 출력 동일.
- **결과**: ⏳ 미실행

---

## 실행 환경 메모

| 항목 | 값 |
|------|----|
| 단말 | _(미정)_ |
| iOS 버전 | _(미정)_ |
| Xcode 버전 | _(미정)_ |
| 빌드 모드 | Debug |
| 모델 파일 | _(미통합)_ |

---

## 누적 실패 기록

_(아직 없음 — 모델 통합 후 갱신)_

---

## 변환 단계 검증 (2026-05-06)

### V-0. 변환 산출물 sanity (✅ 통과)

- 산출 파일: `IndoorNavigation-iOS/Resources/SuperPoint.mlpackage` (2.5MB)
- **입력**: `image` ImageType GRAYSCALE 480(W)×640(H), `scale=1/255`
- **출력 1**: `semi` FP16 (1, 65, 80, 60) ✓ — H/8=80, W/8=60 일치
- **출력 2**: `desc` FP16 (1, 256, 80, 60) ✓ — L2 정규화 모델 내부에 포함
- 메타데이터: shortDescription / author / version 정상 기록

### 변환 시 경고 메모

- `Torch version 2.11.0 has not been tested with coremltools` — 변환 자체는 성공. 추론 결과 이상이 발견되면 torch 2.7.0 다운그레이드 검토.
- `overflow encountered in cast` (L2 정규화 clamp 1e-12 부분 FP16 캐스팅) — FP16 표현 한계에 의한 정상 경고. 매칭 sanity (V-5) 단계에서 결과 영향 확인 예정.
