"""
mock_bundle.json keyframe descriptor 끼리 LightGlue 매칭 baseline.

목적:
- 클라 단순 NN 매칭의 false positive 폭증이 매처 한계인지, descriptor 자체 문제인지 분리 진단.
- 같은 mock 데이터 (서버 SuperPoint 출력) 끼리 LightGlue 매칭이 잘 되면 → descriptor 정상, 매처 한계.
- 안 되면 → descriptor/추출 자체 의심.

사용:
    python tools/lightglue_baseline.py
"""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

import numpy as np
import torch

from lightglue import LightGlue


REPO_ROOT = Path(__file__).resolve().parents[1]
MOCK_PATH = REPO_ROOT / "IndoorNavigation-iOS" / "Tracking" / "MockData" / "mock_bundle.json"


def decode_descriptors(b64: str, n: int, dim: int = 256) -> np.ndarray:
    raw = base64.b64decode(b64)
    arr = np.frombuffer(raw, dtype=np.float16).reshape(n, dim).astype(np.float32)
    return arr


def decode_world3d(b64: str, n: int) -> np.ndarray:
    raw = base64.b64decode(b64)
    return np.frombuffer(raw, dtype=np.float32).reshape(n, 3)


def load_keyframe_features(kf: dict, image_size_wh: tuple[int, int]) -> dict:
    keypoints = np.asarray(kf["keypoints"], dtype=np.float32)  # (N, 2)
    n = keypoints.shape[0]
    descriptors = decode_descriptors(kf["descriptors_b64"], n=n, dim=256)  # (N, 256)
    return {
        "keypoints": torch.from_numpy(keypoints).unsqueeze(0),                  # (1, N, 2)
        "descriptors": torch.from_numpy(descriptors).unsqueeze(0),              # (1, N, 256)
        "image_size": torch.tensor([list(image_size_wh)], dtype=torch.float32), # (1, 2)
    }


def main() -> int:
    if not MOCK_PATH.exists():
        print(f"❌ not found: {MOCK_PATH}")
        return 1

    print(f"📦 loading {MOCK_PATH.name} …")
    with open(MOCK_PATH) as f:
        bundle = json.load(f)

    intr = bundle["manifest"]["intrinsics"]
    image_size = (int(intr["width"]), int(intr["height"]))
    keyframes = bundle["keyframes"]
    print(f"   keyframes: {len(keyframes)}, image_size: {image_size}")

    # descriptor sanity
    kp0 = np.asarray(keyframes[0]["keypoints"], dtype=np.float32)
    desc0 = decode_descriptors(keyframes[0]["descriptors_b64"], n=kp0.shape[0])
    norms = np.linalg.norm(desc0, axis=1)
    print(f"   kf[0] keypoints={kp0.shape[0]}, desc shape={desc0.shape}, "
          f"L2 norm mean={norms.mean():.3f} std={norms.std():.3f} "
          f"(SuperPoint output 은 unit-norm 이어야 함)")

    # LightGlue matcher
    print("🔧 loading LightGlue (superpoint) matcher …")
    matcher = LightGlue(features="superpoint").eval()
    if torch.cuda.is_available():
        matcher = matcher.cuda()
    print(f"   device: {next(matcher.parameters()).device}")

    # all pairs
    pairs = [(i, j) for i in range(len(keyframes)) for j in range(i + 1, len(keyframes))]
    print(f"\n=== keyframe pair 매칭 ({len(pairs)} 쌍) ===")
    print(f"{'pair':>6} {'matches':>8} {'mean_score':>11} {'min_dist_m':>11}")
    print("-" * 42)

    for i, j in pairs:
        feats_i = load_keyframe_features(keyframes[i], image_size)
        feats_j = load_keyframe_features(keyframes[j], image_size)
        if torch.cuda.is_available():
            feats_i = {k: v.cuda() for k, v in feats_i.items()}
            feats_j = {k: v.cuda() for k, v in feats_j.items()}

        with torch.no_grad():
            out = matcher({"image0": feats_i, "image1": feats_j})

        matches = out["matches"][0]      # (K, 2)
        scores = out["scores"][0]        # (K,)
        n_matches = int(matches.shape[0])
        mean_score = float(scores.mean()) if n_matches > 0 else 0.0

        # 두 keyframe pose 거리 (참고용)
        pose_i = np.asarray(keyframes[i]["pose_4x4"], dtype=np.float32)
        pose_j = np.asarray(keyframes[j]["pose_4x4"], dtype=np.float32)
        dist = float(np.linalg.norm(pose_i[:3, 3] - pose_j[:3, 3]))

        print(f"  ({i},{j}) {n_matches:>8d}   {mean_score:>10.3f}   {dist:>10.2f}")

    print("\n해석:")
    print("  - mean_score > 0.5 + matches > 100 이면 descriptor 정상 → 클라 매처(NN+ratio)가 한계")
    print("  - matches < 30 또는 score < 0.2 이면 descriptor/추출 자체 의심")
    return 0


if __name__ == "__main__":
    sys.exit(main())
