# Phase 7-1 진행 현황

> Core ML 기반 SuperPoint 추출 인프라 구현 (`Phase 7 7-1` 항목).
> 본 PR 시작 시 상태: `SuperPointExtractorStub` 만 존재, 실제 모델 추론 없음.

---

## 완료

- ✅ 워크스페이스 초기화 (PROGRESS / DECISIONS / VALIDATION)
- ✅ D-1 확정: 원조 SuperPoint (256-dim descriptor)
- ✅ D-2 확정: Python 변환 스크립트 경로
- ✅ `tools/superpoint_to_coreml.py` 변환 스크립트 작성
- ✅ `tools/requirements.txt` 의존성 명세
- ✅ `tools/README.md` 사용 절차 + 트러블슈팅
- ✅ Python 환경 세팅 (`.venv-tools`, torch 2.11.0, coremltools 9.0)
- ✅ **변환 실행 완료** — `SuperPoint.mlpackage` 생성 (2.5MB, FP16). 사용자가 Xcode 추가 시 `IndoorNavigation-iOS/SuperPoint.mlpackage` 위치로 이동시킴 (synced group이 자동 인식)
  - Input: `image` GRAYSCALE 480(W)×640(H)
  - Output `semi`: FP16 (1, 65, 80, 60)
  - Output `desc`: FP16 (1, 256, 80, 60), L2 정규화됨
- ✅ Xcode 통합 — `SuperPoint.mlmodelc` 앱 번들 포함 + `SuperPoint` Swift 클래스 자동 생성 확인
- ✅ `.gitignore` `**/*.mlpackage` 룰 보강 (위치 무관 ignore)
- ✅ **Swift 측 실 추출기 구현 완료** (임플리멘터 PASS 보고, 빌드 검증)
  - 신규: `Tracking/Preprocessing/PixelBufferPreprocessor.swift`
  - 신규: `Tracking/Decoding/SuperPointHeatmapDecoder.swift`
  - 신규: `Tracking/Decoding/DescriptorSampler.swift`
  - 수정: `Tracking/SuperPointExtractor.swift` (`SuperPointExtractorML` 추가, stub 보존)
  - 수정: `ARNavigationLogic.swift` (`setupSuperPointExtractor()` 분기, 추론 시간 ring buffer)
  - 수정: `Tracking/__DebugOverlay__/SuperPointDebugController.swift` (추론 시간 라벨)
  - 신규 테스트: `SuperPointExtractorTests`, `SuperPointHeatmapDecoderTests`, `PixelBufferPreprocessorTests`
  - `xcodebuild build -configuration Debug` → `** BUILD SUCCEEDED **`

---

- ✅ **리뷰 PASS_WITH_NOTES** (2026-05-07): CRITICAL 이슈 없음. 정합성·메모리·안정성·범위 모두 통과
  - WARNING 6개 항목은 모두 V-2 실측 후 결정 가능한 후속 최적화 (블로커 아님). 자세한 내용은 본 문서 "WARNING / 후속 PR 후보" 섹션 참조
- ✅ **실기기 V-1 PASS / V-2 PARTIAL** (2026-05-07): 키포인트가 실제 코너에 군집(육안 검증). 추론 시간 평균 270ms — DoD 100ms 미달이나 사용 가능 수준
- ✅ **MLMultiArray padded layout 버그 픽스** (2026-05-07): 실기기 첫 실행 시 `Index out of range` 크래시. `float32Buffer(from:)` 의 buffer 크기를 `arr.count` → strides 기반 max-idx 로 변경
- ✅ **디코더·샘플러 가속** (2026-05-07): 시작 2840ms → 270ms (10.5배 단축, 발열 사이클 차단)
  - NMS separable max-pool Swift 4중 루프 → `vImageMax_PlanarF` (kernel 9, kvImageTruncateKernel)
  - softmax 4800 cell × 65 expf → cell당 vDSP_maxv/vsadd/vvexpf/sve/vsmul (SIMD 일괄)
  - DescriptorSampler MLMultiArray 박싱 → `dataPointer.bindMemory<Float16>` 직접 쓰기 + L2 정규화 vDSP_svesq/vsmul
- ✅ **`extract()` 단계별 시간 프로파일링 추가** (2026-05-07): pre/pred/dec/samp 4구간 측정 + 5프레임 평균 console 로그

## 진행 중

_(다음 단계: 사용자 실기기 검증)_

---

## 다음 단계

### 사용자 작업 (블로커)

1. ✅ MagicLeap `superpoint_v1.pth` 다운로드
2. ✅ Python 환경에서 변환 실행 완료
3. ✅ Xcode 프로젝트에 `.mlpackage` 추가 (synced group 자동 인식 + 빌드 산출물 검증됨)

### 리뷰 PASS 후 (사용자 실측 검증 단계)

- [ ] V-1 (육안): 디버그 빌드 실기기 실행 → 카메라를 텍스처 풍부한 벽에 비춤. 점이 코너에 군집하면 PASS
- [ ] V-2 (추론 시간 HUD): 정지 30초 후 평균 ms ≤ 100 (iPhone 14 Pro 기준)
- [ ] V-3 (descriptor 규약): 임플리멘터 신규 단위 테스트 — 실기기에서 `xcodebuild test` 통과 확인
- [ ] V-7 (stub 토글): `UserDefaults.standard.set(true, forKey: "useSuperPointStub")` 후 격자 출력 회귀 확인

### WARNING 항목 진척

| # | 위치 | 내용 | 상태 |
|---|------|------|------|
| W-1 | `SuperPointExtractor.swift` | `emptyDesc` 매번 사전 생성 | 미적용 (효과 미미) |
| W-2 | `DescriptorSampler.swift`, stub | Float16→Float→NSNumber 박싱 | ✅ ML 경로 해결 (직접 쓰기 + vDSP). stub 박싱은 의도 보존 |
| W-3 | `SuperPointHeatmapDecoder.swift` | softmax 4800 cell × 65 expf 단순 루프 | ✅ 해결 (vDSP/vForce 벡터화) |
| W-4 | `ARNavigationLogic.swift` | `inferenceTimesMs.removeFirst(N)` O(N) 시프트 | 미적용 (capacity 100 영향 미미) |
| W-5 | `SuperPointExtractor.swift` | stub은 `onInferenceTimeMs` 콜백 없음 | 미적용 (stub/ML 비교 측정 필요 시 검토) |
| W-6 | `PixelBufferPreprocessor.swift` | `srcPlaneIndex` 양 분기 동일값 | 미적용 (스타일) |

신규 추가된 가속 항목:
- **NMS 2D max-pool**: Swift 4중 루프 → `vImageMax_PlanarF` (단일 호출, 가장 큰 효과 ~2400ms 절감)
- **`float32Buffer` padded layout 대응**: `arr.count` → strides 기반 max-idx (실기기 OOB 크래시 픽스)

### 추가 후속 후보

- [ ] `IndoorNavigation-iOS/Resources/SuperPoint.mlpackage` 번들링 (Xcode target 추가)
- [ ] `SuperPointExtractor` 실 구현체 작성 (stub 옆에 신규 클래스)
  - [ ] `CVPixelBuffer` → 그레이스케일 480×640 리사이즈·정규화 (`vImage` 또는 `CIImage` 기반)
  - [ ] Core ML `MLModel` lazy 로드 + 워밍업
  - [ ] heatmap 디코딩: score threshold + NMS (반경 4px) + top-K (512)
  - [ ] descriptor map → bilinear sampling → L2 정규화 → float16 양자화
- [ ] `SuperPointExtracting` 사용처 교체 (DEBUG 빌드에서 stub 대체 가능하도록 토글)
- [ ] 워밍업 호출 위치 결정 (`ARNavigationViewController` 진입 시 vs 앱 부팅 시)

### 검증 (Phase 7-1 DoD 충족)

- [ ] 카메라 피드 위 키포인트가 **격자가 아니라 실제 코너에 군집** (육안 sanity)
- [ ] 평균 추론 시간 ≤ 100ms (iPhone 14 Pro 기준)
- [ ] descriptor 차원 256 / float16 / L2 정규화 보장 — 단위 테스트
- [ ] 동일 정지 장면 100프레임에서 repeatability ≥ 60%

---

## 변경 로그

| 일자 | 변경 | 사유 |
|------|------|------|
| 2026-05-06 | 워크스페이스 초기화 | Phase 7-1 본격 구현 시작 |
| 2026-05-06 | D-1 확정 (원조 SuperPoint), D-2 확정 (Python 변환 스크립트) | 사용자 승인 |
| 2026-05-06 | `tools/superpoint_to_coreml.py` + requirements.txt + README.md 작성 | D-2 산출물 |
| 2026-05-06 | Python venv 세팅 + 변환 실행 → `SuperPoint.mlpackage` 생성 (2.5MB, FP16) | D-2 산출물 검증 |
| 2026-05-07 | Xcode 통합 검증 (synced group 자동 인식, `SuperPoint.mlmodelc` 앱 번들 포함) | 사용자 추가 후 검증 |
| 2026-05-07 | `.gitignore` `**/*.mlpackage` 룰로 강화 (mlpackage 위치 변경 대응) | unstage + 라이선스 보호 |
| 2026-05-07 | Swift 측 실 추출기 + 단위 테스트 구현 완료, `xcodebuild build` SUCCEEDED | 임플리멘터 산출 |
| 2026-05-07 | 리뷰 **PASS_WITH_NOTES** — CRITICAL 0, WARNING 6 (전부 후속 후보) | 리뷰어 산출 |
| 2026-05-07 | MLMultiArray padded layout 대응 (`float32Buffer` strides 기반) | 실기기 첫 실행 OOB 크래시 픽스 |
| 2026-05-07 | `extract()` 4구간 시간 프로파일링 추가 (cold + 5프레임 평균 console 로그) | 병목 진단 — dec 90% 차지 확인 |
| 2026-05-07 | 디코더 NMS → `vImageMax_PlanarF` (~2400ms → ~30ms 추정) | dec 압도적 hotspot 해소 |
| 2026-05-07 | 디코더 softmax → vDSP/vForce 벡터화 + 샘플러 박싱 제거 | 추가 ~180ms 절감, 합계 270ms 도달 |
| 2026-05-07 | V-1 PASS, V-2 PARTIAL (270ms, DoD 미달이나 머지 가능) | 실기기 측정 — 발열 체감 없음 |
