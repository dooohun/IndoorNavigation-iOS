"""
클라이언트 dump (SuperPointFrameDumper 출력) vs mock_bundle keyframe LightGlue 매칭.

목적:
- baseline (lightglue_baseline.py) 은 mock 끼리 매칭 — descriptor 자체가 정상임을 확인.
- 본 스크립트는 클라가 추출한 SuperPoint descriptor 가 서버 추출과 같은 분포인지 (FP16 양자화·전처리
  차이 누적이 매칭 결과에 영향을 주는지) 검증.

사용:
    python tools/lightglue_client_check.py path/to/dump-YYYYMMDD-HHMMSS.json
    # 옵션: --top N (best N keyframe 만 표시), --all (모든 keyframe 결과 표시)
"""

from __future__ import annotations

import argparse
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


def load_mock_keyframe_features(kf: dict, image_size_wh: tuple[int, int]) -> dict:
    keypoints = np.asarray(kf["keypoints"], dtype=np.float32)  # (N, 2)
    n = keypoints.shape[0]
    descriptors = decode_descriptors(kf["descriptors_b64"], n=n, dim=256)
    return {
        "keypoints": torch.from_numpy(keypoints).unsqueeze(0),
        "descriptors": torch.from_numpy(descriptors).unsqueeze(0),
        "image_size": torch.tensor([list(image_size_wh)], dtype=torch.float32),
    }


def load_client_dump_features(dump: dict) -> tuple[dict, tuple[int, int]]:
    intr = dump["intrinsics"]
    image_size = (int(intr["width"]), int(intr["height"]))
    keypoints = np.asarray(dump["keypoints"], dtype=np.float32)
    n = keypoints.shape[0]
    descriptors = decode_descriptors(dump["descriptors_b64"], n=n, dim=256)
    feats = {
        "keypoints": torch.from_numpy(keypoints).unsqueeze(0),
        "descriptors": torch.from_numpy(descriptors).unsqueeze(0),
        "image_size": torch.tensor([list(image_size)], dtype=torch.float32),
    }
    return feats, image_size


def descriptor_stats(desc: np.ndarray, label: str) -> None:
    norms = np.linalg.norm(desc, axis=1)
    print(f"   {label}: shape={desc.shape}, "
          f"L2 norm mean={norms.mean():.3f} std={norms.std():.3f}, "
          f"value range [{desc.min():.3f}, {desc.max():.3f}]")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dump_path", type=Path, help="클라이언트 dump JSON (Documents/superpoint_dumps/dump-*.json)")
    parser.add_argument("--top", type=int, default=0, help="best N keyframe 만 표시 (0=전체)")
    args = parser.parse_args()

    if not args.dump_path.exists():
        print(f"❌ dump file not found: {args.dump_path}")
        return 1
    if not MOCK_PATH.exists():
        print(f"❌ mock_bundle.json not found: {MOCK_PATH}")
        return 1

    print(f"📦 client dump: {args.dump_path}")
    with open(args.dump_path) as f:
        dump = json.load(f)
    print(f"   captured_at: {dump.get('captured_at', '?')}")
    print(f"   orientation: {dump.get('device_orientation', '?')}")
    client_feats, client_size = load_client_dump_features(dump)
    n_client = client_feats["keypoints"].shape[1]
    desc_client = client_feats["descriptors"][0].cpu().numpy()
    descriptor_stats(desc_client, f"client (N={n_client}, size={client_size})")

    print(f"\n📦 mock_bundle: {MOCK_PATH.name}")
    with open(MOCK_PATH) as f:
        bundle = json.load(f)
    intr = bundle["manifest"]["intrinsics"]
    mock_size = (int(intr["width"]), int(intr["height"]))
    keyframes = bundle["keyframes"]
    print(f"   keyframes: {len(keyframes)}, intrinsics_size: {mock_size}")

    desc_mock_first = decode_descriptors(
        keyframes[0]["descriptors_b64"],
        n=len(keyframes[0]["keypoints"]),
    )
    descriptor_stats(desc_mock_first, "mock kf[0]")

    if client_size != mock_size:
        print(f"⚠️  image_size 불일치 — client {client_size} vs mock {mock_size}. LightGlue 가 이를"
              f" position encoding 정규화에 사용하므로 매칭 quality 가 영향받을 수 있음.")

    # LightGlue
    print("\n🔧 loading LightGlue (superpoint) …")
    matcher = LightGlue(features="superpoint").eval()
    if torch.cuda.is_available():
        matcher = matcher.cuda()
        client_feats = {k: v.cuda() for k, v in client_feats.items()}
    print(f"   device: {next(matcher.parameters()).device}")

    print(f"\n=== client dump vs mock keyframe ({len(keyframes)} 쌍) ===")
    print(f"{'kf':>4} {'kp_mock':>8} {'matches':>8} {'mean_score':>11}")
    print("-" * 36)

    results = []
    for i, kf in enumerate(keyframes):
        mock_feats = load_mock_keyframe_features(kf, mock_size)
        if torch.cuda.is_available():
            mock_feats = {k: v.cuda() for k, v in mock_feats.items()}
        with torch.no_grad():
            out = matcher({"image0": client_feats, "image1": mock_feats})
        matches = out["matches"][0]
        scores = out["scores"][0]
        n_matches = int(matches.shape[0])
        mean_score = float(scores.mean()) if n_matches > 0 else 0.0
        results.append((i, mock_feats["keypoints"].shape[1], n_matches, mean_score))

    if args.top > 0:
        results.sort(key=lambda r: r[2], reverse=True)
        results = results[: args.top]

    for i, n_kp, n_matches, mean_score in results:
        print(f"  {i:>2d} {n_kp:>8d} {n_matches:>8d}   {mean_score:>10.3f}")

    print("\n해석:")
    print("  - matches > 100 + score > 0.4 인 keyframe 이 1+ 있으면 클라 descriptor 유효 → LightGlue iOS 도입 정당")
    print("  - 모든 keyframe 이 matches < 30 또는 score < 0.2 면 클라 추출 자체 의심 (FP16 양자화/전처리/입력 파이프라인)")
    print("  - mock 끼리 baseline 결과 (lightglue_baseline.py) 와 비교: 비슷한 score 범위면 클라 추출 ≈ 서버 추출")
    return 0


if __name__ == "__main__":
    sys.exit(main())
