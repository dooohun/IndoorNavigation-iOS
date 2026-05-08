"""
LightGlue (cvg/LightGlue, SuperPoint variant) → Core ML 변환 시도 스크립트.

Phase 8 C 트랙 — 클라 단독 측위를 위해 LightGlue 매처를 iOS 단말에서 추론 가능하게 변환.

핵심 비활성화 (정적 그래프 보장):
- depth_confidence = -1  (early stop 끄기)
- width_confidence = -1  (pruning 끄기)
- flash = False          (flash attn → vanilla SDPA, Core ML 호환성)

입출력:
    Input:
        keypoints0  shape=(1, N, 2)  float32
        descriptors0 shape=(1, N, 256) float32
        keypoints1  shape=(1, N, 2)  float32
        descriptors1 shape=(1, N, 256) float32
        image_size0 shape=(1, 2) float32  (W, H)
        image_size1 shape=(1, 2) float32
    Output:
        matches0    shape=(1, N) int64  (각 keypoint0 의 매칭 keypoint1 idx, -1 = no match)
        scores0     shape=(1, N) float32

사용:
    python tools/lightglue_to_coreml.py --num-keypoints 1024 --output mlmodels/LightGlueMatcher.mlpackage
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import torch
import torch.nn as nn
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op

from lightglue import LightGlue


# coremltools 9.0 에 log_sigmoid op 가 없어서 composite 으로 등록.
# log(sigmoid(x)) = -softplus(-x)
@register_torch_op
def log_sigmoid(context, node):
    inputs = _get_inputs(context, node, expected=1)
    x = inputs[0]
    neg = mb.mul(x=x, y=-1.0)
    sp = mb.softplus(x=neg)
    res = mb.mul(x=sp, y=-1.0, name=node.name)
    context.add(res)


class LightGlueWrapper(nn.Module):
    """LightGlue 의 dict 입력/dict 출력 인터페이스를 tensor I/O 로 단순화."""

    def __init__(self, matcher: LightGlue) -> None:
        super().__init__()
        self.matcher = matcher

    def forward(
        self,
        kp0: torch.Tensor,
        desc0: torch.Tensor,
        kp1: torch.Tensor,
        desc1: torch.Tensor,
        image_size0: torch.Tensor,
        image_size1: torch.Tensor,
    ):
        data = {
            "image0": {
                "keypoints": kp0,
                "descriptors": desc0,
                "image_size": image_size0,
            },
            "image1": {
                "keypoints": kp1,
                "descriptors": desc1,
                "image_size": image_size1,
            },
        }
        out = self.matcher(data)
        return out["matches0"], out["matching_scores0"]


def make_example_inputs(n: int = 1024):
    torch.manual_seed(0)
    kp = torch.rand(1, n, 2) * torch.tensor([960.0, 540.0])
    desc = torch.randn(1, n, 256)
    desc = desc / desc.norm(dim=-1, keepdim=True)
    img_size = torch.tensor([[960.0, 540.0]])
    return kp, desc, img_size


def _patch_sigmoid_log_double_softmax() -> None:
    """`sigmoid_log_double_softmax` 의 b, m, n = sim.shape + 동적 padding 을
    cat 으로 재구성. `sim.shape` 추출이 aten::Int → coremltools 'int' op 차단."""
    import lightglue.lightglue as _lg
    import torch.nn.functional as F

    def patched(sim: torch.Tensor, z0: torch.Tensor, z1: torch.Tensor) -> torch.Tensor:
        # z0/z1 shape (B, M, 1) / (B, N, 1)
        certainties = F.logsigmoid(z0) + F.logsigmoid(z1).transpose(1, 2)
        scores0 = F.log_softmax(sim, 2)
        scores1 = F.log_softmax(sim.transpose(-1, -2).contiguous(), 2).transpose(-1, -2)
        inner = scores0 + scores1 + certainties                       # (B, M, N)
        last_col = F.logsigmoid(-z0)                                   # (B, M, 1)
        last_row = F.logsigmoid(-z1).transpose(1, 2)                   # (B, 1, N)
        row_block = torch.cat([inner, last_col], dim=-1)               # (B, M, N+1)
        corner = torch.zeros_like(last_row[:, :, :1])                  # (B, 1, 1)
        last_row_full = torch.cat([last_row, corner], dim=-1)          # (B, 1, N+1)
        scores = torch.cat([row_block, last_row_full], dim=1)          # (B, M+1, N+1)
        return scores

    _lg.sigmoid_log_double_softmax = patched


def _patch_filter_matches() -> None:
    """LightGlue.filter_matches 의 `torch.where(valid, m, -1)` → 명시적 텐서 -1.

    이유: PyTorch trace 시 Python int -1 가 aten::Int(tensor) 호출로 변환되어
    coremltools 'int' op (다차원 cast) 에서 차단됨. 의미상 동일.
    """
    import lightglue.lightglue as _lg

    def filter_matches_patched(scores: torch.Tensor, th: float):
        max0, max1 = scores[:, :-1, :-1].max(2), scores[:, :-1, :-1].max(1)
        m0, m1 = max0.indices, max1.indices
        indices0 = torch.arange(m0.shape[1], device=m0.device)[None]
        indices1 = torch.arange(m1.shape[1], device=m1.device)[None]
        mutual0 = indices0 == m1.gather(1, m0)
        mutual1 = indices1 == m0.gather(1, m1)
        max0_exp = max0.values.exp()
        zero = max0_exp.new_tensor(0)
        mscores0 = torch.where(mutual0, max0_exp, zero)
        mscores1 = torch.where(mutual1, mscores0.gather(1, m1), zero)
        valid0 = mutual0 & (mscores0 > th)
        valid1 = mutual1 & valid0.gather(1, m1)
        neg1_m0 = torch.full_like(m0, -1)
        neg1_m1 = torch.full_like(m1, -1)
        m0 = torch.where(valid0, m0, neg1_m0)
        m1 = torch.where(valid1, m1, neg1_m1)
        return m0, m1, mscores0, mscores1

    _lg.filter_matches = filter_matches_patched


def build_matcher() -> LightGlue:
    _patch_sigmoid_log_double_softmax()
    _patch_filter_matches()
    matcher = LightGlue(features="superpoint").eval()
    # 정적 그래프 보장
    matcher.conf.depth_confidence = -1
    matcher.conf.width_confidence = -1
    matcher.conf.flash = False
    matcher.conf.mp = False
    # internal flag 도 같이
    matcher.compile_ = False
    return matcher


def trace_wrapper(wrapper: LightGlueWrapper, n: int):
    kp0, desc0, img_size0 = make_example_inputs(n)
    kp1, desc1, img_size1 = make_example_inputs(n + 7)  # 일부러 다른 분포
    # 같은 N 으로 cropped (Core ML 입력 shape 고정)
    kp1 = kp1[:, :n]
    desc1 = desc1[:, :n]

    with torch.no_grad():
        # PyTorch 검증 — 변환 전에 wrapper 자체가 동작하는지
        m0, s0 = wrapper(kp0, desc0, kp1, desc1, img_size0, img_size1)
        print(f"[pre-trace eval] matches0 shape={tuple(m0.shape)}, "
              f"scores0 shape={tuple(s0.shape)}, valid matches={int((m0 >= 0).sum())}")

    print("[1/3] torch.jit.trace …")
    with torch.no_grad():
        traced = torch.jit.trace(
            wrapper,
            (kp0, desc0, kp1, desc1, img_size0, img_size1),
            strict=False,
        )
    return traced


def convert_to_coreml(traced, n: int, output_path: Path):
    print("[2/3] coremltools.convert …")
    inputs = [
        ct.TensorType(name="keypoints0", shape=(1, n, 2), dtype=float),
        ct.TensorType(name="descriptors0", shape=(1, n, 256), dtype=float),
        ct.TensorType(name="keypoints1", shape=(1, n, 2), dtype=float),
        ct.TensorType(name="descriptors1", shape=(1, n, 256), dtype=float),
        ct.TensorType(name="image_size0", shape=(1, 2), dtype=float),
        ct.TensorType(name="image_size1", shape=(1, 2), dtype=float),
    ]
    outputs = [
        ct.TensorType(name="matches0"),
        ct.TensorType(name="scores0"),
    ]
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        outputs=outputs,
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
    )
    mlmodel.short_description = (
        "LightGlue feature matcher (SuperPoint variant). Static N keypoints. "
        "depth_confidence/width_confidence/flash all disabled for static graph."
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        shutil.rmtree(output_path)
    mlmodel.save(str(output_path))
    print(f"[3/3] saved: {output_path}")
    return mlmodel


def verify(mlmodel, wrapper: LightGlueWrapper, n: int):
    print("\n=== 검증: PyTorch 원본 vs Core ML 모델 ===")
    kp0, desc0, img_size0 = make_example_inputs(n)
    kp1, desc1, img_size1 = make_example_inputs(n + 7)
    kp1 = kp1[:, :n]
    desc1 = desc1[:, :n]

    with torch.no_grad():
        m0_pt, s0_pt = wrapper(kp0, desc0, kp1, desc1, img_size0, img_size1)

    pred = mlmodel.predict({
        "keypoints0": kp0.numpy(),
        "descriptors0": desc0.numpy(),
        "keypoints1": kp1.numpy(),
        "descriptors1": desc1.numpy(),
        "image_size0": img_size0.numpy(),
        "image_size1": img_size1.numpy(),
    })
    m0_ct = pred["matches0"]
    s0_ct = pred["scores0"]

    valid_pt = int((m0_pt[0] >= 0).sum())
    valid_ct = int((m0_ct[0] >= 0).sum())
    print(f"  PyTorch valid matches: {valid_pt}")
    print(f"  CoreML  valid matches: {valid_ct}")

    # 둘 다 valid 인 keypoint 의 매칭 일치율
    common = (m0_pt[0] >= 0).numpy() & (m0_ct[0] >= 0)
    if common.sum() > 0:
        same = (m0_pt[0].numpy()[common] == m0_ct[0][common]).sum()
        print(f"  공통 valid kp 매칭 일치: {same}/{int(common.sum())} "
              f"({100*same/max(1,int(common.sum())):.1f}%)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--num-keypoints", "-n", type=int, default=1024,
                        help="고정 keypoint 수 (Core ML 입력 shape 고정)")
    parser.add_argument("--output", type=Path,
                        default=Path("mlmodels/LightGlueMatcher.mlpackage"))
    parser.add_argument("--skip-verify", action="store_true")
    args = parser.parse_args()

    print(f"=== LightGlue → Core ML 변환 (N={args.num_keypoints}) ===\n")
    matcher = build_matcher()
    wrapper = LightGlueWrapper(matcher)

    traced = trace_wrapper(wrapper, args.num_keypoints)
    mlmodel = convert_to_coreml(traced, args.num_keypoints, args.output)

    if not args.skip_verify:
        verify(mlmodel, wrapper, args.num_keypoints)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
