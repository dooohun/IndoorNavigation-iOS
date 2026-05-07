"""
SuperPoint PyTorch (MagicLeap, 2018) → Core ML 변환 스크립트.

원조 SuperPoint 가중치(`superpoint_v1.pth`) 를 받아 iOS 측에서 추론 가능한
`.mlpackage` 로 변환한다. Phase 7-1 의 `7-1. Core ML 모델 통합` 산출물.

사용법:
    python tools/superpoint_to_coreml.py \\
        --weights /path/to/superpoint_v1.pth \\
        --output IndoorNavigation-iOS/Resources/SuperPoint.mlpackage \\
        --width 480 --height 640

요구 사항:
    pip install -r tools/requirements.txt

입출력 사양 (iOS 측 디코더는 본 사양을 따라 작성):
    Input:
        name=image, type=ImageType(GRAYSCALE), shape=(1, 1, H, W)
        scale=1/255.0, bias=0.0  → 모델 내부에서 0~1 범위로 받음
    Output 1:
        name=semi, shape=(1, 65, H/8, W/8), dtype=float16
        - detector head logits. softmax 후 마지막(64) 채널은 dustbin 으로 버린다.
        - 64 채널을 8×8 subpixel 로 reshape 하면 (H, W) 점수 맵 복원.
    Output 2:
        name=desc, shape=(1, 256, H/8, W/8), dtype=float16
        - 채널 방향 L2 정규화 완료 (Swift 측 추가 정규화 불필요).
        - 키포인트 위치 (u, v) 에서 bilinear sampling 으로 256-d descriptor 추출.

확정 결정 (DECISIONS.md 참조):
    D-1: 원조 SuperPoint
    D-2: 본 변환 스크립트 경로
    D-4: 그레이스케일/정규화는 Core ML 입력에 통합
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import torch
import torch.nn as nn
import coremltools as ct


class SuperPointNet(nn.Module):
    """원조 SuperPoint 아키텍처 (MagicLeap 공식 저장소 'demo_superpoint.py' 와 동일)."""

    def __init__(self) -> None:
        super().__init__()
        c1, c2, c3, c4, c5, d1 = 64, 64, 128, 128, 256, 256
        self.relu = nn.ReLU(inplace=True)
        self.pool = nn.MaxPool2d(kernel_size=2, stride=2)

        # Shared encoder (4 conv blocks, /8 spatial reduction)
        self.conv1a = nn.Conv2d(1, c1, kernel_size=3, stride=1, padding=1)
        self.conv1b = nn.Conv2d(c1, c1, kernel_size=3, stride=1, padding=1)
        self.conv2a = nn.Conv2d(c1, c2, kernel_size=3, stride=1, padding=1)
        self.conv2b = nn.Conv2d(c2, c2, kernel_size=3, stride=1, padding=1)
        self.conv3a = nn.Conv2d(c2, c3, kernel_size=3, stride=1, padding=1)
        self.conv3b = nn.Conv2d(c3, c3, kernel_size=3, stride=1, padding=1)
        self.conv4a = nn.Conv2d(c3, c4, kernel_size=3, stride=1, padding=1)
        self.conv4b = nn.Conv2d(c4, c4, kernel_size=3, stride=1, padding=1)

        # Detector head: 65 = 64 cells + 1 dustbin
        self.convPa = nn.Conv2d(c4, c5, kernel_size=3, stride=1, padding=1)
        self.convPb = nn.Conv2d(c5, 65, kernel_size=1, stride=1, padding=0)

        # Descriptor head: 256-dim, L2 normalized along channel dim
        self.convDa = nn.Conv2d(c4, c5, kernel_size=3, stride=1, padding=1)
        self.convDb = nn.Conv2d(c5, d1, kernel_size=1, stride=1, padding=0)

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        x = self.relu(self.conv1a(x))
        x = self.relu(self.conv1b(x))
        x = self.pool(x)
        x = self.relu(self.conv2a(x))
        x = self.relu(self.conv2b(x))
        x = self.pool(x)
        x = self.relu(self.conv3a(x))
        x = self.relu(self.conv3b(x))
        x = self.pool(x)
        x = self.relu(self.conv4a(x))
        x = self.relu(self.conv4b(x))

        cPa = self.relu(self.convPa(x))
        semi = self.convPb(cPa)

        cDa = self.relu(self.convDa(x))
        desc = self.convDb(cDa)
        dn = torch.norm(desc, p=2, dim=1, keepdim=True)
        desc = desc.div(torch.clamp(dn, min=1e-12))
        return semi, desc


def load_weights(model: SuperPointNet, weights_path: Path) -> None:
    state = torch.load(weights_path, map_location="cpu", weights_only=True)
    if isinstance(state, dict) and "state_dict" in state:
        state = state["state_dict"]
    model.load_state_dict(state)
    model.eval()


def convert(model: SuperPointNet, height: int, width: int, output_path: Path) -> None:
    if height % 8 != 0 or width % 8 != 0:
        raise ValueError(f"height/width 는 8의 배수여야 함 (입력: {width}×{height})")

    example = torch.zeros(1, 1, height, width)
    with torch.no_grad():
        traced = torch.jit.trace(model, example, strict=False)

    image_input = ct.ImageType(
        name="image",
        shape=(1, 1, height, width),
        color_layout=ct.colorlayout.GRAYSCALE,
        scale=1.0 / 255.0,
        bias=[0.0],
    )

    mlmodel = ct.convert(
        traced,
        inputs=[image_input],
        outputs=[
            ct.TensorType(name="semi"),
            ct.TensorType(name="desc"),
        ],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
    )

    mlmodel.short_description = (
        "SuperPoint keypoint + descriptor extractor (MagicLeap, 2018). "
        "Outputs: semi (1×65×H/8×W/8 logits, last channel is dustbin), "
        "desc (1×256×H/8×W/8, L2-normalized along channel)."
    )
    mlmodel.author = "MagicLeap (original weights) / IndoorNavigation-iOS (Core ML conversion)"
    mlmodel.license = "MIT (architecture) / Non-commercial research (pretrained weights)"
    mlmodel.version = "1.0.0"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        # .mlpackage 는 디렉토리이므로 덮어쓰기 전 삭제
        shutil.rmtree(output_path)
    mlmodel.save(str(output_path))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--weights", type=Path, required=True, help="superpoint_v1.pth 경로")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("IndoorNavigation-iOS/Resources/SuperPoint.mlpackage"),
        help="출력 .mlpackage 경로 (기본: IndoorNavigation-iOS/Resources/SuperPoint.mlpackage)",
    )
    parser.add_argument("--width", type=int, default=480, help="입력 너비 (8의 배수, 기본 480)")
    parser.add_argument("--height", type=int, default=640, help="입력 높이 (8의 배수, 기본 640)")
    args = parser.parse_args()

    if not args.weights.exists():
        raise FileNotFoundError(f"weights 파일을 찾을 수 없음: {args.weights}")

    print(f"[1/3] 모델 초기화 + 가중치 로드: {args.weights}")
    model = SuperPointNet()
    load_weights(model, args.weights)

    print(f"[2/3] Core ML 변환 — 입력 {args.width}(W) × {args.height}(H), FP16, iOS16+")
    convert(model, height=args.height, width=args.width, output_path=args.output)

    print(f"[3/3] 저장 완료: {args.output}")
    print(
        "\n다음 단계:\n"
        f"  1. Xcode 에서 {args.output} 를 프로젝트 네비게이터로 드래그\n"
        "  2. Target Membership 에 'IndoorNavigation-iOS' 체크\n"
        "  3. Swift 측 SuperPointExtractor (실 구현체) 통합 진행"
    )


if __name__ == "__main__":
    main()
