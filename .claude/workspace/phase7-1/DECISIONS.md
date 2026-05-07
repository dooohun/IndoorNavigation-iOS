# Phase 7-1 설계 결정 로그

> 본 문서는 Phase 7-1 구현 과정에서 내린 **선택의 이유**를 기록한다.
> 각 결정은 `상태(제안 / 확정 / 폐기)`, `대안`, `사유`, `결과적 영향`을 포함한다.

---

## D-1. SuperPoint 변종 선택

- **상태**: ✅ 확정 (2026-05-06, 사용자 승인)
- **선택**: **(A) 원조 SuperPoint** (MagicLeap, 2018)
- **대안**:
  - (B) XFeat (2024) — 더 가볍지만 64-dim descriptor 라 Phase 6/7 규약 변경 필요. 폐기.
  - (C) DISK / ALIKED — 모바일 변환 사례 적음. 폐기.
- **사유**:
  - Phase 6/7 데이터 모델(`descriptor 차원 256 / float16 / L2 정규화`)과 자연스럽게 일치.
  - 가중치·변환 사례·논문 모두 공개. 라이선스는 MIT (가중치는 비상업 연구용 — 본 프로젝트는 학사 연구 범주).
- **재검토 트리거**: 보행 30분 실측에서 발열 throttling 으로 5Hz 미달 → XFeat 재검토.

---

## D-2. 모델 자산 확보 경로

- **상태**: ✅ 확정 (2026-05-06, 사용자 승인)
- **선택**: **(B) Python 변환 스크립트 작성** → PyTorch 가중치 → coremltools → `.mlpackage`
- **산출물**:
  - `tools/superpoint_to_coreml.py` — 변환 실행 스크립트
  - `tools/README.md` — 사용 절차 (가중치 다운로드 → Python 환경 → 실행 → 결과물 위치)
  - 변환 산출물 `IndoorNavigation-iOS/Resources/SuperPoint.mlpackage` 는 사용자가 스크립트 실행 후 커밋
- **사유**:
  - 입출력 텐서 형태를 클라이언트 디코딩(NMS, top-K, descriptor sampling)과 정확히 정합 가능.
  - 추후 입력 해상도·정규화 범위 튜닝 시 재변환만 하면 됨.
  - 외부 자산 의존성·라이선스 검증 부담 회피.
- **사용자 작업 범위**:
  1. MagicLeap 공식 저장소에서 `superpoint_v1.pth` 다운로드
  2. Python 가상환경 생성 후 `pip install -r tools/requirements.txt`
  3. `python tools/superpoint_to_coreml.py --weights superpoint_v1.pth` 실행
  4. 생성된 `.mlpackage` 를 Xcode 프로젝트에 추가

---

## D-3. 모델 번들링 방식

- **상태**: 미결정
- **대안**:
  - (A) 앱 바이너리에 직접 번들 (Xcode target 리소스)
  - (B) 첫 실행 시 원격 다운로드 + 캐시
- **고려 요소**:
  - SuperPoint 가중치 ~5MB 수준 → 앱 크기 영향 미미
  - 오프라인 안정성 / 콜드 스타트 시간 → (A) 유리
  - 추후 모델 업데이트 배포 → (B) 유리하지만 Phase 9 청크 다운로더와 별도로 굳이 분리할 이유 부족
- **잠정**: **(A) 직접 번들**. Phase 9 청크는 별개 영역이므로 본 모델은 단순 번들로 둔다.
- **확정 조건**: 모델 자산 확보 후 즉시 적용.

---

## D-4. 입력 전처리 라이브러리

- **상태**: ✅ 확정 (2026-05-07, 본 PR)
- **선택**: **하이브리드** — Core ML 입력에 `scale=1/255` 정규화 통합 (C), Swift 측은 vImage 로 그레이스케일 추출 + 480×640 리사이즈 (A)
- **이유**:
  - 모델 변환 시 ImageType + scale=1/255 가 모델 안에 통합되어 Swift 측 정규화는 제거됨 (간결성 +)
  - ARFrame 은 YUV biplanar 라 Y plane 추출 + vImageScale_Planar8 단일 호출이 가장 효율적 (CIImage 보다 결정적·낮은 latency)
  - `CVPixelBufferPool` 사전 생성으로 매 호출 alloc 회피
- **구현**: `Tracking/Preprocessing/PixelBufferPreprocessor.swift`
- **범위 제외**: 회전 보정 (ARFrame portrait 가정 stretch). V-1 결과 보고 후속 PR.

---

## D-5. NMS · top-K 구현 위치

- **상태**: ✅ 확정 (2026-05-07, 본 PR)
- **선택**: **Swift `SuperPointHeatmapDecoder` 단일 클래스** — softmax + dustbin 제거 + 8×8 depth-to-space + threshold + separable max-pool NMS + top-K 정렬
- **파라미터**: `scoreThreshold=0.005`, `nmsRadiusPx=4`, `maxKeypoints=512` (Phase 7 표 그대로)
- **구현 디테일**:
  - Float16 → Float32 일괄 변환만 vImage(`vImageConvert_Planar16FtoPlanarF`) 활용
  - separable horizontal max → vertical max 후 본인 == max 픽셀 후보 → score 내림차순 sort 후 prefix(512)
  - Accelerate vDSP 활용은 V-2 측정 후 hot path 확인되면 후속 PR
- **위험**: Phase 7 DoD #2 "평균 추론 시간 ≤ 100ms" 충족은 V-2 단계에서 검증. 미달 시 BNNS / Metal compute 마이그레이션 검토.

---

## D-6. stub 처리

- **상태**: ✅ 확정 (2026-05-07, 본 PR)
- **선택**: `SuperPointExtractorStub` 보존 + **`#if DEBUG` 컴파일 가드 + UserDefaults `useSuperPointStub` 런타임 토글**
- **분기 위치**: `ARNavigationLogic.setupSuperPointExtractor()`
  - DEBUG 빌드 + UserDefaults true → stub 강제
  - 그 외: ML 시도 → init 실패 시 stub 폴백
- **release 빌드 동작**: ML init 실패 시도 stub 폴백 유지 (안전 우선). 운영 silent degradation 우려 있어 후속 PR에서 fatalError 또는 텔레메트리 추가 검토.
- **토글 사용법**: Xcode console 에서 `defaults write com.<bundle> useSuperPointStub -bool YES` 후 앱 재시작.

---

## D-7. 추론 빈도 (Phase 7-3 와의 경계)

- **상태**: ✅ 확정 (2026-05-07, 본 PR)
- **선택**: **`InferenceCadenceController` 변경 없음** — 기존 walking 5Hz / stationary 1.5Hz / turning 10Hz 그대로
- **사유**: Phase 7-3 빈도 적응이 이미 일부 구현된 상태였고, 본 PR은 추출기 교체만 — cadence 모듈 스코프 유지
- **검증**: `InferenceCadenceControllerTests` 회귀 통과 (변경 없음)
- **후속**: 빈도 최적화는 V-2 추론 시간 측정 결과 기반 후속 PR.

---

## D-8. `.mlpackage` 저장소 커밋 여부

- **상태**: ✅ 확정 (2026-05-06, 사용자 승인)
- **선택**: **Git ignore** — `IndoorNavigation-iOS/Resources/*.mlpackage` 를 `.gitignore` 에 추가
- **사유**:
  - 가중치 라이선스가 비상업 연구용이라 저장소 공개 시 전파 우려 회피
  - 변환은 결정적 — `tools/superpoint_to_coreml.py` 로 누구나 동일 산출물 재현 가능
  - 산출물 2.5MB 라 저장소 부담은 작지만, 가중치 라이선스가 더 큰 결정 요인
- **영향**:
  - 새 개발 환경 셋업 시 `tools/README.md` 절차 1회 실행 필요
  - Phase 9 (청크 다운로더)와 별개로 모델 자체는 빌드 시 앱 번들에 포함됨 (D-3 그대로)
- **함께 ignore**: `.venv-tools/`, `.venv/`, `__pycache__/` 등 Python 도구 부산물

---

## 폐기된 안

_(없음)_
