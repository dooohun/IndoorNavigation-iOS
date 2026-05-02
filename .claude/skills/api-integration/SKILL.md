---
name: api-integration
description: IndoorNavigation iOS 앱의 NetworkManager.swift 수정, 새 API 엔드포인트 추가, DTO 정의·수정 작업 시 참조하는 전문 스킬. ios-implementer 에이전트가 API 관련 코드 변경 시 이 스킬을 읽고 패턴을 따른다.
---

# API 연동 가이드

## 기본 정보

- **Base URL**: `http://218.150.183.198:8080/api/v1`
- **인증**: 없음 (현재)
- **Content-Type**: GET은 없음, POST는 `application/json` 또는 `multipart/form-data`

## 현재 엔드포인트

| 메서드 | 경로 | 함수 |
|-------|------|------|
| GET | `/buildings?status=ACTIVE` | `fetchBuildings` |
| GET | `/buildings/{id}/pois` | `fetchPOIs` |
| GET | `/buildings/{id}/pois/search?query=` | `searchPOIs` |
| POST | `/buildings/{id}/localize` | `localize` (multipart) |
| POST | `/buildings/{id}/pathfinding` | `findPath` |

## 새 엔드포인트 추가 패턴

NetworkManager에 새 함수를 추가할 때 반드시 이 구조를 따른다:

```swift
// MARK: - N. {기능명}

func {funcName}({params}, completion: @escaping (Result<{ResponseType}, Error>) -> Void) {
    guard let url = URL(string: "\(baseURL)/...") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "GET" // 또는 "POST"
    request.timeoutInterval = 30

    log("REQ", "GET", url.absoluteString)

    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            log("ERR", "네트워크 오류:", error)
            completion(.failure(Self.networkError(error)))
            return
        }
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
        let data = data ?? Data()
        log("RES", "HTTP \(statusCode)")

        guard (200..<300).contains(statusCode) else {
            completion(.failure(Self.httpError(statusCode: statusCode, data: data)))
            return
        }
        do {
            let result = try JSONDecoder().decode({ResponseType}.self, from: data)
            completion(.success(result))
        } catch {
            log("ERR", "파싱 실패:", error)
            completion(.failure(Self.makeError("응답 파싱 실패")))
        }
    }.resume()
}
```

## DTO 추가 패턴

파일 상단 `// MARK: - Building / POI DTOs` 섹션에 추가한다:

```swift
struct {Name}Response: Codable {
    let fieldName: Type?  // 옵셔널로 방어적으로 선언
}
```

- 모든 필드는 `?` 옵셔널로 선언한다 (서버 응답 변경에 대한 방어)
- 필드명은 서버 응답 JSON 키와 일치해야 한다 (JSONDecoder 기본값은 camelCase)
- 서버가 snake_case를 반환하면 `decoder.keyDecodingStrategy = .convertFromSnakeCase` 추가

## POST JSON 요청 패턴

```swift
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")

do {
    let bodyData = try JSONEncoder().encode(requestDto)
    request.httpBody = bodyData
    log("REQ", "POST", url.absoluteString)
    log("REQ", "바디:", String(data: bodyData, encoding: .utf8) ?? "")
} catch {
    completion(.failure(error))
    return
}
```

## Multipart 요청 패턴

`localize` 함수의 패턴을 그대로 복사하여 사용한다.

## 호출 측 패턴 (ViewController)

```swift
NetworkManager.shared.{funcName}(...) { [weak self] result in
    DispatchQueue.main.async {
        switch result {
        case .success(let data):
            // UI 업데이트
        case .failure(let error):
            // 에러 처리
        }
    }
}
```

**주의**: 네트워크 응답은 background thread에서 오므로 UI 업데이트는 반드시 `DispatchQueue.main.async` 안에서 한다.
