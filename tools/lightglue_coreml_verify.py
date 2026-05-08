"""LightGlueMatcher.mlpackage 정확도 검증 — mock keyframe pair 로 PyTorch 원본과 비교."""
from __future__ import annotations
import base64, json, sys
from pathlib import Path
import numpy as np
import torch
import coremltools as ct

sys.path.insert(0, str(Path(__file__).parent))
from lightglue_to_coreml import build_matcher, LightGlueWrapper

REPO = Path(__file__).resolve().parents[1]
MOCK = REPO / "IndoorNavigation-iOS/Tracking/MockData/mock_bundle.json"
MLMODEL = REPO / "mlmodels/LightGlueMatcher.mlpackage"
N = 1024


def kf_features(kf, image_size):
    kp = np.asarray(kf["keypoints"], dtype=np.float32)
    n = kp.shape[0]
    desc = np.frombuffer(base64.b64decode(kf["descriptors_b64"]), dtype=np.float16).reshape(n, 256).astype(np.float32)
    # pad to N
    if n < N:
        kp = np.concatenate([kp, np.zeros((N - n, 2), np.float32)], 0)
        desc = np.concatenate([desc, np.zeros((N - n, 256), np.float32)], 0)
    else:
        kp, desc = kp[:N], desc[:N]
    return kp[None], desc[None], np.array([list(image_size)], np.float32)


def main():
    bundle = json.loads(MOCK.read_text())
    intr = bundle["manifest"]["intrinsics"]
    sz = (int(intr["width"]), int(intr["height"]))
    kfs = bundle["keyframes"]

    print("[1/3] PyTorch wrapper …")
    matcher = build_matcher()
    wrapper = LightGlueWrapper(matcher)

    print("[2/3] Core ML 모델 로드 …")
    mlmodel = ct.models.MLModel(str(MLMODEL))

    print(f"[3/3] keyframe pair 매칭 비교 (N={N}, pad zero)\n")
    print(f"{'pair':>6} {'pt_valid':>9} {'ct_valid':>9} {'agree':>7}")
    print("-" * 36)
    pairs = [(0, 1), (0, 2), (1, 2), (3, 4), (0, 3)]
    for i, j in pairs:
        kp0, desc0, sz0 = kf_features(kfs[i], sz)
        kp1, desc1, sz1 = kf_features(kfs[j], sz)

        with torch.no_grad():
            m_pt, _ = wrapper(
                torch.from_numpy(kp0), torch.from_numpy(desc0),
                torch.from_numpy(kp1), torch.from_numpy(desc1),
                torch.from_numpy(sz0), torch.from_numpy(sz1),
            )
        pred = mlmodel.predict({
            "keypoints0": kp0, "descriptors0": desc0,
            "keypoints1": kp1, "descriptors1": desc1,
            "image_size0": sz0, "image_size1": sz1,
        })
        m_ct = pred["matches0"]

        pt_valid = int((m_pt[0] >= 0).sum())
        ct_valid = int((m_ct[0] >= 0).sum())
        common = (m_pt[0].numpy() >= 0) & (m_ct[0] >= 0)
        if common.sum() > 0:
            same = int((m_pt[0].numpy()[common] == m_ct[0][common]).sum())
            agree = f"{100*same/int(common.sum()):.1f}%"
        else:
            agree = "n/a"
        print(f"  ({i},{j}) {pt_valid:>9d} {ct_valid:>9d} {agree:>7}")


if __name__ == "__main__":
    main()
