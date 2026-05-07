# tools/

Phase 7-1 (`Core ML SuperPoint 통합`) 의 모델 변환 산출물.

## superpoint_to_coreml.py

원조 SuperPoint(MagicLeap, 2018) PyTorch 가중치를 iOS 측에서 추론 가능한 `.mlpackage` 로 변환한다.

### 1. 사전 준비

#### 가중치 다운로드

MagicLeap 공식 저장소에서 `superpoint_v1.pth` 를 받는다:

```
https://github.com/magicleap/SuperPointPretrainedNetwork
```

저장소의 `superpoint_v1.pth` 파일을 임의 경로(예: `~/Downloads/superpoint_v1.pth`) 에 둔다.

> 라이선스 주의: 가중치는 비상업 연구 용도. 학사 연구 프로젝트 범주에서만 사용한다.

#### Python 환경

```bash
# 프로젝트 루트에서
python3 -m venv .venv-tools
source .venv-tools/bin/activate
pip install -r tools/requirements.txt
```

### 2. 변환 실행

```bash
python tools/superpoint_to_coreml.py \
  --weights ~/Downloads/superpoint_v1.pth \
  --output IndoorNavigation-iOS/Resources/SuperPoint.mlpackage \
  --width 480 --height 640
```

성공 시:
- `IndoorNavigation-iOS/Resources/SuperPoint.mlpackage` 생성 (FP16, iOS 16+ 타겟)
- 입력: 그레이스케일 이미지 (1, 1, 640, 480), `[0, 255]` → 자동 `[0, 1]` 정규화
- 출력 1 `semi`: (1, 65, 80, 60), detector logits (마지막 채널은 dustbin)
- 출력 2 `desc`: (1, 256, 80, 60), 채널 방향 L2 정규화 완료

### 3. Xcode 통합

1. 생성된 `SuperPoint.mlpackage` 를 Xcode 의 프로젝트 네비게이터로 드래그
2. **Target Membership** 패널에서 `IndoorNavigation-iOS` 체크
3. Build Phases > Copy Bundle Resources 에 자동 포함되었는지 확인

### 입출력 사양 (iOS 디코더 작성 시 참조)

```
Input  image: GRAYSCALE Image  (1, 1, H, W)   [0, 255] → /255
Output semi : MLMultiArray FP16 (1, 65, H/8, W/8)
Output desc : MLMultiArray FP16 (1, 256, H/8, W/8)  L2 정규화됨
```

iOS 측 디코딩 절차:
1. `semi` 에 channel-wise softmax → 마지막 65번째 채널 제거 (dustbin)
2. 64 채널을 `(8×8)` subpixel 로 reshape → `(1, 1, H, W)` heatmap
3. score threshold (`0.005`) → NMS (반경 4px, max-pooling 기반) → top-K (`512`)
4. 각 keypoint `(u, v)` 에서 `desc` 를 `(u/8, v/8)` 좌표로 bilinear sampling → 256-d
5. 최종 단계에서 float16 양자화 (이미 FP16 모델이지만 Swift 측 표현형 변환 필요)

### 트러블슈팅

| 증상 | 원인 / 조치 |
|------|------------|
| `coremltools` 가 PyTorch 트레이스를 거부 | torch 버전 확인 (`>=2.1`). `tools/requirements.txt` 의 핀 버전 사용 |
| `weights_only=True` 로드 실패 | torch 1.x 가중치라서 그럼. `weights_only=False` 로 임시 변경 후 재시도 |
| `.mlpackage` 가 Xcode 에서 열리지 않음 | Xcode 14+ 필요. mlprogram 형식은 구버전 미지원 |
| 변환은 되는데 추론 결과가 이상 | input scale/bias 불일치. 본 스크립트는 `scale=1/255` 사용 — 모델 학습 정규화와 일치하는지 확인 |

### 재변환 시점

- 입력 해상도 변경 (`superpoint.inputSize` 파라미터 변경 시)
- 가중치 교체 (다른 SuperPoint variant 실험 시)
- iOS 최소 지원 버전 변경 (`minimum_deployment_target` 조정)
