"""
서버 lightglue SuperPoint 매핑 결과 npz → JSON mock bundle 변환 스크립트.

Phase 8 통합 테스트용. 서버 endpoint 가 결정되기 전 클라가 동일 형식의
mock JSON 으로 파싱·매칭 흐름을 미리 검증한다.

사용법:
    python tools/npz_to_json.py \\
        --input ~/Downloads/route_bundle_3f_to_301.npz \\
        --output IndoorNavigation-iOS/Tracking/MockData/mock_bundle.json \\
        --limit 5

출력 JSON 구조:
{
  "manifest": { ...원본 manifest 그대로... },
  "keyframes": [
    {
      "index": 0,
      "pose_4x4": [[..4x4..]],
      "keypoints": [[u, v], ...],            // (N, 2) float
      "descriptors_b64": "...",              // base64 FP16 row-major (N, 256)
      "world_3d": [[x, y, z] | null, ...],   // (N, 3), NaN → null
      "global_descriptor_b64": "..."         // base64 FP16 (384,)
    },
    ...
  ]
}

descriptors / global_descriptor 는 FP16 raw bytes 를 base64 인코딩 (little-endian).
world_3d 의 NaN 은 JSON null 로 변환되어 클라가 valid 만 PnP 에 사용 가능.
"""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path

import numpy as np


def keyframe_to_dict(data: np.lib.npyio.NpzFile, i: int) -> dict:
    kp = data["keypoints"][i]                # (N, 2) float32
    desc = data["descriptors"][i]            # (N, 256) float16
    w3d = data["world_3d"][i]                # (N, 3) float32, NaN 가능
    pose = np.array(data["poses"][i], dtype=np.float64)
    gd = data["global_descriptors"][i]       # (384,) float16

    # NaN → null (PnP 에서 사용 불가능한 점 표시)
    world_3d_list: list = []
    for row in w3d:
        if np.isnan(row[0]):
            world_3d_list.append(None)
        else:
            world_3d_list.append([float(row[0]), float(row[1]), float(row[2])])

    return {
        "index": int(i),
        "pose_4x4": pose.tolist(),
        "keypoints": [[float(p[0]), float(p[1])] for p in kp],
        "descriptors_b64": base64.b64encode(desc.tobytes()).decode("ascii"),
        "world_3d": world_3d_list,
        "global_descriptor_b64": base64.b64encode(gd.tobytes()).decode("ascii"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, required=True, help="route_bundle_*.npz 경로")
    parser.add_argument("--output", type=Path, required=True, help="출력 JSON 경로")
    parser.add_argument("--limit", type=int, default=None, help="포함할 keyframe 수 (기본: 전체)")
    parser.add_argument("--pretty", action="store_true", help="들여쓰기 포함 (기본 minified)")
    args = parser.parse_args()

    if not args.input.exists():
        raise FileNotFoundError(f"입력 파일 없음: {args.input}")

    print(f"[1/3] npz 로드: {args.input}")
    data = np.load(args.input, allow_pickle=True)
    manifest = json.loads(str(data["manifest"]))
    n_total = int(data["keypoints"].shape[0])
    n = n_total if args.limit is None else min(args.limit, n_total)
    print(f"      총 {n_total} keyframe 중 {n} 개 사용")

    print("[2/3] keyframe 변환 + base64 인코딩")
    keyframes = [keyframe_to_dict(data, i) for i in range(n)]

    bundle = {
        "manifest": manifest,
        "keyframes": keyframes,
    }

    print(f"[3/3] 출력 저장: {args.output}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as f:
        if args.pretty:
            json.dump(bundle, f, ensure_ascii=False, indent=2)
        else:
            json.dump(bundle, f, ensure_ascii=False, separators=(",", ":"))

    size_mb = args.output.stat().st_size / (1024 * 1024)
    print(f"      완료. {size_mb:.2f} MB")


if __name__ == "__main__":
    main()
