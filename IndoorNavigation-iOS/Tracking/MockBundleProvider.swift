import Foundation

/// `LocalizationBundle` 공급자 인터페이스.
/// mock(`MockBundleProvider`) 또는 운영(`NetworkBundleProvider`, Phase 8) 구현이 따른다.
protocol BundleProviding {
    func loadBundle() throws -> LocalizationBundle
}

enum BundleProviderError: Error, CustomStringConvertible {
    case resourceNotFound(name: String)
    case decodingFailed(underlying: Error)

    var description: String {
        switch self {
        case .resourceNotFound(let name): return "리소스 없음: \(name).json"
        case .decodingFailed(let err):    return "JSON 디코딩 실패: \(err)"
        }
    }
}

/// 앱 번들에 포함된 `mock_bundle.json` 을 로드. Phase 8 서버 endpoint 가 결정되기
/// 전 클라 매칭·PnP 흐름을 검증하기 위한 임시 공급자.
///
/// 운영 단계에서는 `NetworkBundleProvider` 로 교체. JSON 구조가 동일하므로
/// 디코더·소비자 코드는 그대로 재사용.
final class MockBundleProvider: BundleProviding {

    static let defaultResourceName = "mock_bundle"

    private let resourceName: String
    private let bundle: Foundation.Bundle

    init(resourceName: String = MockBundleProvider.defaultResourceName,
         bundle: Foundation.Bundle = .main) {
        self.resourceName = resourceName
        self.bundle = bundle
    }

    func loadBundle() throws -> LocalizationBundle {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw BundleProviderError.resourceNotFound(name: resourceName)
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(LocalizationBundle.self, from: data)
        } catch {
            throw BundleProviderError.decodingFailed(underlying: error)
        }
    }
}
