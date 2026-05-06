---
name: api-integration
description: IndoorNavigation iOS 앱의 NetworkManager.swift 수정, 새 API 엔드포인트 추가, DTO 정의·수정 작업 시 참조하는 전문 스킬. ios-implementer 에이전트가 API 관련 코드 변경 시 이 스킬을 읽고 패턴을 따른다.
---

# API 연동 가이드

## 기본 정보

- **REST Base URL**: `http://218.150.183.198:8080/api/v1`
- **SLAM Base URL**: `http://218.150.183.198:8080/api/slam/v3` (로컬라이즈 전용)
- **인증**: 없음 (현재)
- **로깅**: 모든 요청/응답은 파일 상단 private `log(_:_:)` 헬퍼로 `[REQ]`/`[RES]`/`[ERR]` 태그를 찍는다

## 현재 엔드포인트

| # | 메서드 | 경로 | 함수 | 응답 DTO |
|---|-------|------|------|---------|
| 1 | POST | `/api/slam/v3/localize` | `localize(buildingId:mapId:images:)` | `SLAMLocalizeResponse` |
| 2 | POST | `/buildings/{bid}/floors/{fid}/routes/coordinates` | `findRouteByCoordinates(buildingId:floorId:request:)` | `FloorCoordinateRouteResponse` |
| 3 | GET | `/buildings?status=ACTIVE` | `fetchBuildings(status:)` | `[BuildingResponse]` |
| 4 | GET | `/buildings/{bid}` | `fetchBuildingDetail(buildingId:)` | `BuildingDetailResponse` |
| 5 | GET | `/buildings/{bid}/pois` | `fetchPOIs(buildingId:)` | `[POIResponse]` |
| 6 | GET | `/buildings/{bid}/pois/search?query=` | `searchPOIs(buildingId:query:)` | `[POIResponse]` |

`BuildingDetailResponse`는 `floors: [FloorResponse]`, `verticalPassages: [VerticalPassageResponse]`를 포함한다. 층 ID(`floorId`)가 필요한 경로 탐색의 출처.

## 모든 함수의 공통 시그니처

```swift
func {funcName}({params}, completion: @escaping (Result<{ResponseType}, Error>) -> Void)
```

- 동기 반환 없음 — completion handler로 전달
- 에러는 `Self.networkError(_:)`, `Self.httpError(statusCode:data:)`, `Self.makeError(_:)`로 정규화
- 응답 파싱은 `JSONDecoder().decode(...)`. snake_case 응답이 와도 현재 모든 DTO 필드는 camelCase 또는 서버 키와 일치하도록 정의되어 있어 별도 keyDecodingStrategy 미사용

## 새 GET 엔드포인트 추가 패턴

`fetchBuildings` 함수를 그대로 따른다:

```swift
// MARK: - N. {기능명}

func {funcName}({params}, completion: @escaping (Result<{ResponseType}, Error>) -> Void) {
    guard let url = URL(string: "\(baseURL)/...") else { return }

    log("REQ", "GET", url.absoluteString)

    URLSession.shared.dataTask(with: url) { data, response, error in
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

## 새 POST(JSON) 엔드포인트 추가 패턴

`findRouteByCoordinates`를 따른다. `URLRequest` 구성 + `JSONEncoder().encode(requestDto)` + 응답 본문 로깅:

```swift
guard let url = URL(string: "\(baseURL)/...") else { return }
var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.timeoutInterval = 30

do {
    let bodyData = try JSONEncoder().encode(requestDto)
    request.httpBody = bodyData
    log("REQ", "POST", url.absoluteString)
    log("REQ", "바디:", String(data: bodyData, encoding: .utf8) ?? "")
} catch {
    completion(.failure(error))
    return
}

URLSession.shared.dataTask(with: request) { data, response, error in
    // ... GET 패턴과 동일한 응답 처리. 단, 실패 시 응답 본문도 로깅 권장:
    let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(빈 응답)"
    log("RES", "바디:", responseBody)
    // 파싱 실패 시 makeError 메시지에 responseBody 포함 → 서버 응답 디버깅 용이
}.resume()
```

## Multipart 요청 패턴

`localize` 함수를 그대로 복사하여 사용한다. 핵심 구조:

```swift
let boundary = "Boundary-\(UUID().uuidString)"
request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

var body = Data()
func appendField(_ name: String, _ value: String) {
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
    body.append(value.data(using: .utf8)!)
    body.append("\r\n".data(using: .utf8)!)
}
// 텍스트 필드 (snake_case 사용 — 서버 스펙과 일치)
if let bid = buildingId { appendField("building_id", bid) }
// 이미지 필드 (jpegData(compressionQuality: 0.5))
for (i, image) in images.enumerated() {
    guard let data = image.jpegData(compressionQuality: 0.5) else { continue }
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"images\"; filename=\"image\(i).jpg\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
    body.append(data)
    body.append("\r\n".data(using: .utf8)!)
}
body.append("--\(boundary)--\r\n".data(using: .utf8)!)
request.httpBody = body
```

**주의**: 멀티파트 텍스트 필드명은 서버 스펙에 맞춰 snake_case (`building_id`, `map_id`)를 쓴다. JSON 바디는 Codable이 처리하므로 DTO 필드 그대로.

## DTO 추가 패턴

파일 상단의 영역별 `// MARK:` 섹션에 추가한다:
- `// MARK: - Building / POI DTOs` — 건물·층·POI 관련
- `// MARK: - Localize / Coordinate Route DTOs` — 측위·경로 관련
- `// MARK: - 내부 경로 렌더링 모델` — 서버 응답을 AR 렌더링용으로 어댑트하는 중간 모델 (`PathStep`, `Position`)
- `// MARK: - 에러 모델` — `private`로 선언된 응답 에러 디코딩용

```swift
struct {Name}Response: Codable {
    let fieldName: Type?  // 옵셔널로 방어적으로 선언
}
```

- 모든 외부 응답 필드는 `?` 옵셔널로 선언한다 (서버 응답 변경 방어)
- 키 이름은 서버 응답 JSON 키와 일치 (DTO 대부분이 camelCase 그대로 들어옴)
- 단순 좌표는 기존 `Coordinate(x:y:z:)` (z 옵셔널) 또는 `Position(x:y:z:)` (모두 필수, 내부 모델) 재사용 검토

## 서버 응답 어댑팅

서버 응답을 AR 렌더링용 내부 모델로 변환할 때는 `ARNavigationLogic.adaptRouteResponseToSteps(response:)` 패턴을 따른다:

- `FloorCoordinateRouteResponse.pathGeometry.coordinates: [[Double]]?` → `[PathStep]`
- 좌표 배열 길이 < 2면 빈 배열, < 3이면 z=0 기본값
- `floorLevel`은 로컬라이즈 응답의 `floorLevel`을 캐싱하여 주입 (서버 좌표 응답에는 층 정보 없음)

API 호출 함수 자체는 raw DTO만 반환하고, 어댑팅은 호출 측(현재는 `ARNavigationLogic`)에서 수행한다.

## 호출 측 패턴 (ViewController / Logic)

```swift
NetworkManager.shared.{funcName}(...) { [weak self] result in
    DispatchQueue.main.async {
        guard let self = self else { return }
        switch result {
        case .success(let data):
            // UI 업데이트 또는 후속 호출
        case .failure(let error):
            // self.delegate?.showScanFailed(...) 등
        }
    }
}
```

- 네트워크 응답은 background thread로 들어옴 → UI 업데이트는 반드시 `DispatchQueue.main.async`
- `[weak self]` + `guard let self = self else { return }` 캡처 패턴을 일관되게 적용 (retain cycle 방지)
- 후속 네트워크 호출이 필요하면 `main.async` 블록 안에서 다시 호출해도 무방 (URLSession은 자체 스레드 풀 사용)

## 에러 헬퍼 활용

`NetworkManager` 내부에 정의된 private static 메서드를 사용한다 — 새로 만들지 말 것:

| 헬퍼 | 용도 |
|------|------|
| `Self.networkError(_:)` | URLError 등 시스템 네트워크 오류 (코드, localizedDescription 포함) |
| `Self.httpError(statusCode:data:)` | non-2xx HTTP 응답. `V1ErrorResponse` / `HTTPValidationError` 자동 디코딩 시도 |
| `Self.makeError(_:)` | 임의 메시지로 NSError 생성 (도메인: "NetworkManager") |

파싱 실패 시에는 응답 본문을 메시지에 포함시켜 `Self.makeError("응답 파싱 실패\n\(responseBody)")` 형태로 전달하면 디버깅이 쉽다.
