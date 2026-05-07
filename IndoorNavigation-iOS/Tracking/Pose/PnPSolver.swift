import Foundation
import Accelerate
import simd

/// PnP (Perspective-n-Point) — 2D-3D 점 쌍 + 카메라 intrinsics 로 6DoF pose 추정.
protocol PnPSolving {
    func solve(
        objectPoints: [SIMD3<Float>],
        imagePoints: [SIMD2<Float>],
        intrinsics: simd_float3x3
    ) -> PoseEstimate?
}

/// Direct Linear Transform 기반 PnP. 알고리즘:
/// 1. K^-1 로 image points 정규화 (camera ray)
/// 2. (2N × 12) 행렬 A 구성 (각 점마다 2 행)
/// 3. SVD(A) → null vector p (smallest right singular vector)
/// 4. p 를 [R_raw | t_raw] (3×4) 로 reshape
/// 5. SVD(R_raw) 로 R orthogonalize (closest rotation)
/// 6. 평균 singular value 로 scale 보정 (t = t_raw / avg_σ)
/// 7. Cheirality (점이 카메라 앞 z>0) 위반 시 부호 보정
/// 8. 재투영 오차 계산
///
/// 한계: outlier 에 매우 민감 (단순 LS). 본 PR 은 단순 검증용. 운영용은 RANSAC 필요 (단계 3).
final class DLTPnPSolver: PnPSolving {

    func solve(
        objectPoints: [SIMD3<Float>],
        imagePoints: [SIMD2<Float>],
        intrinsics: simd_float3x3
    ) -> PoseEstimate? {
        guard objectPoints.count >= 6,
              objectPoints.count == imagePoints.count else { return nil }
        let n = objectPoints.count

        // 1. K^-1 로 image points 정규화
        let invK = intrinsics.inverse
        var normIm = [SIMD2<Float>]()
        normIm.reserveCapacity(n)
        for ip in imagePoints {
            let h = invK * SIMD3<Float>(ip.x, ip.y, 1)
            guard abs(h.z) > 1e-8 else { return nil }
            normIm.append(SIMD2<Float>(h.x / h.z, h.y / h.z))
        }

        // 2. A 행렬 (2N × 12) row-major
        var A = [Double](repeating: 0, count: 2 * n * 12)
        for i in 0..<n {
            let X = Double(objectPoints[i].x)
            let Y = Double(objectPoints[i].y)
            let Z = Double(objectPoints[i].z)
            let x = Double(normIm[i].x)
            let y = Double(normIm[i].y)
            let r1 = i * 2 * 12
            let r2 = r1 + 12
            // Row 1: x·(p3·X) - p1·X = 0
            A[r1 + 0] = -X; A[r1 + 1] = -Y; A[r1 + 2] = -Z; A[r1 + 3] = -1
            A[r1 + 8] = x * X; A[r1 + 9] = x * Y; A[r1 + 10] = x * Z; A[r1 + 11] = x
            // Row 2: y·(p3·X) - p2·X = 0
            A[r2 + 4] = -X; A[r2 + 5] = -Y; A[r2 + 6] = -Z; A[r2 + 7] = -1
            A[r2 + 8] = y * X; A[r2 + 9] = y * Y; A[r2 + 10] = y * Z; A[r2 + 11] = y
        }

        // 3. SVD null vector (12 elements)
        guard let p = LapackSVD.nullVector(matrix: A, rows: 2 * n, cols: 12) else { return nil }
        // p = [r11, r12, r13, t1, r21, r22, r23, t2, r31, r32, r33, t3]^T

        var R_raw_double: [Double] = [
            p[0], p[1], p[2],
            p[4], p[5], p[6],
            p[8], p[9], p[10],
        ]
        var t_raw = SIMD3<Float>(Float(p[3]), Float(p[7]), Float(p[11]))

        // 4. SVD(R_raw) 로 orthogonalize + scale
        guard let svdR = LapackSVD.decompose(matrix: R_raw_double, rows: 3, cols: 3) else { return nil }
        // U·V^T 가 closest orthogonal. det(U·V^T) 가 -1 이면 V 의 last column 부호 뒤집기.
        var R_ortho = computeOrthogonalRotation(U: svdR.U, VT: svdR.VT)
        let avgSigma = (svdR.S[0] + svdR.S[1] + svdR.S[2]) / 3.0
        guard avgSigma > 1e-8 else { return nil }
        var t = t_raw / Float(avgSigma)

        // 5. Cheirality — 첫 점이 카메라 앞 (z > 0) 이어야. 위반 시 p 전체 부호 뒤집기.
        let X_cam0 = R_ortho * objectPoints[0] + t
        if X_cam0.z < 0 {
            // p → -p 와 동등: R_raw 부호 뒤집어 SVD 재계산. 단순화: R_ortho, t 부호 뒤집음.
            // 단 R_ortho 부호만 뒤집으면 det 가 -1 이 되니, last column 도 한 번 더 뒤집어 det=+1 보장.
            R_raw_double = R_raw_double.map { -$0 }
            t_raw = -t_raw
            guard let svdR2 = LapackSVD.decompose(matrix: R_raw_double, rows: 3, cols: 3) else { return nil }
            R_ortho = computeOrthogonalRotation(U: svdR2.U, VT: svdR2.VT)
            let avgSigma2 = (svdR2.S[0] + svdR2.S[1] + svdR2.S[2]) / 3.0
            guard avgSigma2 > 1e-8 else { return nil }
            t = t_raw / Float(avgSigma2)
        }

        // 6. 재투영 오차 (픽셀 단위, 평균)
        var totalErr: Float = 0
        var validCount: Int = 0
        for i in 0..<n {
            let Xc = R_ortho * objectPoints[i] + t
            if Xc.z <= 1e-6 { continue }
            let projNorm = SIMD2<Float>(Xc.x / Xc.z, Xc.y / Xc.z)
            let projHom = intrinsics * SIMD3<Float>(projNorm.x, projNorm.y, 1)
            guard abs(projHom.z) > 1e-8 else { continue }
            let projPx = SIMD2<Float>(projHom.x / projHom.z, projHom.y / projHom.z)
            totalErr += simd_distance(projPx, imagePoints[i])
            validCount += 1
        }
        let avgErr = validCount > 0 ? (totalErr / Float(validCount)) : .infinity

        return PoseEstimate(
            rotation: R_ortho,
            translation: t,
            pointCount: n,
            reprojectionError: avgErr
        )
    }

    // MARK: - Helpers

    /// SVD 결과 (U, V^T) 로부터 closest orthogonal rotation (det=+1) 계산.
    /// U, VT 모두 column-major 3×3.
    private func computeOrthogonalRotation(U: [Double], VT: [Double]) -> simd_float3x3 {
        // U · V^T (둘 다 3×3 column-major)
        var Mflat = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                var sum: Double = 0
                for k in 0..<3 {
                    // U[i, k] (column-major) = U[k * 3 + i]
                    // VT[k, j] (column-major) = VT[j * 3 + k]
                    sum += U[k * 3 + i] * VT[j * 3 + k]
                }
                Mflat[i * 3 + j] = sum  // row-major 임시 저장
            }
        }
        // det 계산
        let det = Mflat[0] * (Mflat[4] * Mflat[8] - Mflat[5] * Mflat[7])
                - Mflat[1] * (Mflat[3] * Mflat[8] - Mflat[5] * Mflat[6])
                + Mflat[2] * (Mflat[3] * Mflat[7] - Mflat[4] * Mflat[6])

        if det < 0 {
            // V 의 last column 부호 뒤집기 = VT 의 last row 부호 뒤집기.
            // VT (column-major) 의 row=2 (last) → vt[col*3 + 2] 부호 반전.
            var VTadj = VT
            for col in 0..<3 {
                VTadj[col * 3 + 2] = -VTadj[col * 3 + 2]
            }
            for i in 0..<3 {
                for j in 0..<3 {
                    var sum: Double = 0
                    for k in 0..<3 {
                        sum += U[k * 3 + i] * VTadj[j * 3 + k]
                    }
                    Mflat[i * 3 + j] = sum
                }
            }
        }

        // simd_float3x3 (column-major) 로 변환. R[col, row] → simd 의 column 인덱스로.
        // simd_float3x3.init(columns:) 는 columns 가 row vector?  simd 의 컨벤션:
        // simd_float3x3.columns 는 (col0, col1, col2). element[i, j] 는 columns[i][j]
        // 즉 simd_float3x3 element index 는 [column][row].
        // Mflat 는 row-major (Mflat[r * 3 + c]). 그래서 columns[c] = (M[0,c], M[1,c], M[2,c]).
        let c0 = SIMD3<Float>(Float(Mflat[0]), Float(Mflat[3]), Float(Mflat[6]))
        let c1 = SIMD3<Float>(Float(Mflat[1]), Float(Mflat[4]), Float(Mflat[7]))
        let c2 = SIMD3<Float>(Float(Mflat[2]), Float(Mflat[5]), Float(Mflat[8]))
        return simd_float3x3(columns: (c0, c1, c2))
    }
}

// MARK: - LAPACK SVD wrapper

struct SVDResult {
    /// m × m, column-major
    let U: [Double]
    /// min(m, n) singular values (descending)
    let S: [Double]
    /// n × n, column-major (V transposed)
    let VT: [Double]
}

/// Accelerate (LAPACK) 의 dgesvd_ 를 호출하는 얇은 wrapper.
enum LapackSVD {

    /// 일반 m × n 행렬의 full SVD: A = U · Σ · V^T.
    /// 입력 matrix 는 row-major. 결과 U, VT 는 column-major (LAPACK 표준).
    static func decompose(matrix: [Double], rows m: Int, cols n: Int) -> SVDResult? {
        precondition(matrix.count == m * n, "matrix size mismatch")
        guard m > 0, n > 0 else { return nil }

        // row-major → column-major
        var aCol = [Double](repeating: 0, count: m * n)
        for i in 0..<m {
            for j in 0..<n {
                aCol[j * m + i] = matrix[i * n + j]
            }
        }

        var jobu: Int8 = 0x41   // 'A' — full U
        var jobvt: Int8 = 0x41  // 'A' — full V^T
        var mP = Int32(m)
        var nP = Int32(n)
        var lda = Int32(m)
        let minMN = min(m, n)
        var s = [Double](repeating: 0, count: minMN)
        var u = [Double](repeating: 0, count: m * m)
        var ldu = Int32(m)
        var vt = [Double](repeating: 0, count: n * n)
        var ldvt = Int32(n)
        var info: Int32 = 0

        // 1) workspace query
        var lwork: Int32 = -1
        var workQuery = [Double](repeating: 0, count: 1)
        dgesvd_(&jobu, &jobvt, &mP, &nP, &aCol, &lda, &s,
                &u, &ldu, &vt, &ldvt, &workQuery, &lwork, &info)
        guard info == 0 else { return nil }

        let optLwork = max(1, Int(workQuery[0]))
        lwork = Int32(optLwork)
        var work = [Double](repeating: 0, count: optLwork)

        // 2) actual SVD
        dgesvd_(&jobu, &jobvt, &mP, &nP, &aCol, &lda, &s,
                &u, &ldu, &vt, &ldvt, &work, &lwork, &info)
        guard info == 0 else { return nil }

        return SVDResult(U: u, S: s, VT: vt)
    }

    /// A 의 right-null-space vector — A·x ≈ 0 의 unit-norm x (smallest right singular vector).
    /// = V 의 마지막 column = V^T 의 마지막 row.
    static func nullVector(matrix: [Double], rows m: Int, cols n: Int) -> [Double]? {
        guard let svd = decompose(matrix: matrix, rows: m, cols: n) else { return nil }
        // VT 는 n × n column-major. row=(n-1) 의 모든 column → VT[col * n + (n-1)]
        var v = [Double](repeating: 0, count: n)
        for col in 0..<n {
            v[col] = svd.VT[col * n + (n - 1)]
        }
        return v
    }
}
