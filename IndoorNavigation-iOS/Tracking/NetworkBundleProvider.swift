//
//  NetworkBundleProvider.swift
//  IndoorNavigation-iOS
//
//  Phase 8 S2 — `BundleProviding` 의 운영용 구현.
//  서버 `feature-points/lookup` (B2) 결과를 `LocalizationBundle` 로 어댑팅 후 캐싱.
//
//  토글: ARNavigationLogic.setupSuperPointExtractor 에서 UserDefaults `useNetworkBundle`
//  로 분기. 실패 시 `MockBundleProvider` 폴백.
//

import Foundation
import simd

/// 서버 lookup 응답을 기반으로 `LocalizationBundle` 을 공급.
/// 호출 흐름: `fetch(...)` 비동기 로드 → 성공 시 내부 캐시 → 이후 `loadBundle()` 동기 반환.
final class NetworkBundleProvider: BundleProviding {

    // MARK: - 에러

    enum NetworkBundleError: Error, CustomStringConvertible {
        /// `loadBundle()` 호출 시 아직 fetch 가 성공하지 않음.
        case notLoaded
        /// 서버 응답에 keyframe 이 0개.
        case emptyResponse
        /// `LookupResponse → LocalizationBundle` 변환 실패.
        case adaptationFailed(reason: String)
        /// 네트워크/디코딩 등 하부 오류 래핑.
        case underlying(Error)

        var description: String {
            switch self {
            case .notLoaded:                       return "번들 미로드: fetch() 선행 필요"
            case .emptyResponse:                   return "lookup 응답 keyframes 비어있음"
            case .adaptationFailed(let reason):    return "어댑팅 실패: \(reason)"
            case .underlying(let err):             return "하부 오류: \(err)"
            }
        }
    }

    // MARK: - 의존성 / 상태

    /// 단일 lookup query 입력. floorLevel + (x, y, z) 좌표.
    struct QueryPoint {
        let floorLevel: Int
        let x: Double
        let y: Double
        let z: Double
    }

    private let buildingId: String
    private let queryPoints: [QueryPoint]
    private let radiusM: Double
    private let maxKeyframesPerQuery: Int
    private let networkManager: NetworkManager
    private var cached: LocalizationBundle?
    private let queue = DispatchQueue(label: "NetworkBundleProvider.cache")

    // MARK: - init

    /// - Parameters:
    ///   - buildingId: lookup endpoint path 의 buildingId (UUID)
    ///   - queryPoints: 다수 query 좌표 (경로 따라 N개 보내면 dedup 해서 영역 keyframe 묶어옴)
    ///   - radiusM: keyframe 검색 반경 (기본 5m, multi-query 라 작게). TODO(서버답): 실측 byteSize 보고 조정
    ///   - maxKeyframesPerQuery: query 당 최대 keyframe (서버 cap 16). 기본 5.
    ///   - networkManager: 의존성 주입
    init(buildingId: String,
         queryPoints: [QueryPoint],
         radiusM: Double = 5.0,
         maxKeyframesPerQuery: Int = 5,
         networkManager: NetworkManager = .shared) {
        self.buildingId = buildingId
        self.queryPoints = queryPoints
        self.radiusM = radiusM
        self.maxKeyframesPerQuery = maxKeyframesPerQuery
        self.networkManager = networkManager
    }

    // MARK: - fetch (비동기)

    /// 서버 lookup 호출 → 어댑팅 → 캐시 저장. completion 은 main 스레드.
    func fetch(completion: @escaping (Result<LocalizationBundle, Error>) -> Void) {
        let queries = queryPoints.map {
            LookupQuery(floorLevel: $0.floorLevel, x: $0.x, y: $0.y, z: $0.z, viewDirection: nil)
        }
        let options = LookupOptions(
            radiusM: radiusM,
            maxKeyframesPerQuery: maxKeyframesPerQuery,
            viewConeDeg: nil,
            format: "json_b64"
        )
        let req = LookupRequest(queries: queries, options: options)

        networkManager.featurePointsLookup(buildingId: buildingId, request: req) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    guard !resp.keyframes.isEmpty else {
                        completion(.failure(NetworkBundleError.emptyResponse))
                        return
                    }
                    do {
                        let bundle = try resp.toLocalizationBundle(destination: "")
                        self.queue.sync { self.cached = bundle }
                        completion(.success(bundle))
                    } catch let LookupAdaptationError.adaptationFailed(reason) {
                        completion(.failure(NetworkBundleError.adaptationFailed(reason: reason)))
                    } catch {
                        completion(.failure(NetworkBundleError.underlying(error)))
                    }
                case .failure(let err):
                    completion(.failure(NetworkBundleError.underlying(err)))
                }
            }
        }
    }

    // MARK: - BundleProviding (동기 — 캐시 폴백)

    /// 캐시된 번들 반환. fetch 미완료 시 `notLoaded` throw.
    /// `MockBundleProvider.loadBundle()` 시그니처와 호환되어 토글 분기에서 동일하게 사용 가능.
    func loadBundle() throws -> LocalizationBundle {
        return try queue.sync {
            guard let bundle = cached else {
                throw NetworkBundleError.notLoaded
            }
            return bundle
        }
    }
}
