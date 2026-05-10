# Phase 6 — AR 내비게이션 UI 전면 재설계

## 상태
미구현

## 목표
사용자가 "어디로 어떻게 가야 하는지"를 한눈에 알 수 있도록 AR 내비게이션 화면 HUD 를 단계(step) 기반 카드 UX 로 전면 재설계한다.

기존 화면은 상단 목적지 pill + 하단 instruction 카드만 보여 주어 (1) 다음 동작이 무엇인지, (2) 다음 동작까지 거리/걸음 수가 얼마인지, (3) 그 이후에 어떤 단계가 남았는지 사용자가 즉시 파악하기 어려웠다. 새 UI 는 현재 step 의 동작 + 거리 + 걸음 수를 강조하고, 하단에는 전체 잔여 거리/시간을, 우측에는 남은 추가 단계 수와 펼침 버튼을 노출한다.

## UI 구성 (목업 기반)

화면 좌표는 portrait 기준. SafeArea 기준 상대 배치.

### 1. 좌상단 — 닫기 버튼 (CloseButton)
- 위치: `safeArea.top + 12`, `safeArea.leading + 16`
- 형태: 원형 버튼, 직경 44pt
- 배경: `UIColor(white: 0.0, alpha: 0.45)` + blur
- 아이콘: SF Symbol `xmark`, `tintColor: .white`, 18pt semibold
- 동작: 기존 `onCloseButtonTapped()` 그대로 (pop / dismiss)

### 2. 상단 중앙 — 목적지 pill (DestinationPill)
- 위치: 화면 상단, `closeButton` 우측
- 형태: 캡슐(높이 56pt), `cornerRadius = height/2`
- 배경: `UIColor(white: 0.0, alpha: 0.55)` + blur
- 좌측 아이콘 원: 직경 36pt, `systemBlue` 배경, SF Symbol `flag.fill` 화이트
- 텍스트:
  - 1행: `3F · 목적지` — 12pt, `.white.alpha(0.7)`
  - 2행: `회의실 A-301` (POI 이름) — 16pt semibold, `.white`

### 3. 현재 스텝 카드 (CurrentStepCard) — 메인 강조
- 위치: 목적지 pill 아래 16pt, 화면 우측 정렬, 좌우 마진 16pt
- 배경: `systemBlue`, `cornerRadius = 20`, shadow `(0,4,12, alpha 0.25)`
- 좌측 아이콘 박스: 직경 56pt, `UIColor.white.alpha(0.18)`, `cornerRadius = 16`
  - 내부 SF Symbol: 방향에 따라 `arrow.up` / `arrow.turn.up.right` / `arrow.turn.up.left` / `figure.stairs` 등
  - 화이트, 28pt bold
- 우측 텍스트 (3행):
  - 1행: 동작 단어 — `직진` / `우회전` / `좌회전` / `계단` / `엘리베이터` — 14pt regular, `.white.alpha(0.85)`
  - 2행: 큰 거리 숫자 + `m` 단위 — 28pt heavy, `.white`. 숫자만 heavy, `m` 은 16pt regular
  - 3행: `약 N걸음` — 13pt regular, `.white.alpha(0.85)`

### 4. 추가 단계 펼침 버튼 (RemainingStepsToggle)
- 위치: CurrentStepCard 아래 8pt, 우측 정렬
- 형태: 캡슐(높이 36pt), 좌우 패딩 14pt
- 배경: `.white.alpha(0.12)`, blur
- 텍스트: `+N단계` (N = 잔여 step 수 - 1) — 13pt semibold, `.white`
- 우측 chevron: SF Symbol `chevron.down`, 12pt semibold
- 동작: 탭 시 잔여 step 리스트 시트(BottomSheet)를 노출. **이번 phase 에서는 시트 스텁(빈 sheet)만 띄우고, 풍부한 step 리스트 UI 는 후속 phase 에서 작업한다.**
- 잔여 step 이 1개 이하면 isHidden = true.

### 5. 하단 거리/시간 캡슐 (RemainingDistanceCapsule)
- 위치: 화면 하단, `재측정 버튼` 위 16pt
- 형태: 캡슐(높이 44pt), 좌우 패딩 18pt
- 배경: `.black.alpha(0.55)` + blur
- 텍스트: `남은 거리 ` (15pt regular, `.white`) + `84m` (16pt heavy, `systemBlue`) + ` | ` (15pt regular, `.white.alpha(0.5)`) + `약 2분` (15pt regular, `.white`)

### 6. 재측정 버튼 (RelocalizeButton)
- 위치: `safeArea.bottom - 16`, 화면 가운데
- 형태: 캡슐(높이 52pt), 좌우 패딩 22pt
- 배경: `.black.alpha(0.55)` + blur, 1pt `.white.alpha(0.2)` 테두리
- 좌측 SF Symbol `viewfinder` (16pt)
- 텍스트: `재측정` — 16pt semibold, `.white`
- 동작: 기존 `onLocateButtonTapped()` 와 동일 (= 재측위 트리거).
- 기존 `locateButton` 을 그대로 재사용·재배치한다 (별도 인스턴스 X).

### 7. AR 콘텐츠 영역
- 기존 `sceneView` 는 그대로 — 변경 없음.
- 기존 chevron / 경로 시각화 노드도 변경 없음.
- 모든 신규 HUD 는 `hudContainerView` 안쪽에 추가하여 `setHUDVisible(_:)` 와 함께 토글된다.

## 데이터 모델 — `NavigationStepViewModel`

UI 가 step 정보를 받아 렌더링하기 위해 ViewController 에 다음 모델을 도입한다:

```swift
enum NavigationActionKind {
    case straight
    case turnLeft
    case turnRight
    case turnSlightLeft
    case turnSlightRight
    case uturn
    case stairsUp
    case stairsDown
    case elevator
    case arrive
    case unknown
}

struct NavigationStepViewModel {
    let action: NavigationActionKind
    let distanceMeters: Double          // 다음 step 까지 (또는 잔여) 미터
    let approxSteps: Int                // 약 N걸음 — distance / 0.7 round
    let remainingTotalMeters: Double    // 전체 남은 거리
    let remainingMinutes: Int           // 전체 남은 시간 (걷기 1.2 m/s 기준 round)
    let remainingExtraStepsCount: Int   // 잔여 step 수 - 1 (현재 표시중 제외)
    let destinationFloorLevel: Int?
    let destinationName: String
}
```

## delegate 메서드 갱신

`ARNavigationLogicDelegate` 에 새 메서드 추가:

```swift
func updateNavigationStep(_ vm: NavigationStepViewModel)
```

기존 `updateHUD(destinationName:remainingDistance:instruction:)` 는 **dead path 화하지 않고** 일단 유지(구) → ARNavigationLogic 에서 신규 메서드를 추가 호출하여 단계적으로 신규 HUD 가 채워지게 한다. 단, ViewController 의 신규 HUD 가 화면을 점유하므로 기존 instructionLabel/remainingDistanceLabel 은 더 이상 추가하지 않는다.

### Action 매핑 규칙
`PathStep.instruction` 문자열을 `NavigationActionKind` 로 매핑하는 헬퍼 `NavigationActionKind.from(instruction:)` 를 ARNavigationLogic 안 private 으로 추가한다.

| 키워드 | 매핑 |
|--------|------|
| `STRAIGHT`, `직진`, `GO_STRAIGHT` | `.straight` |
| `TURN_LEFT`, `좌회전` | `.turnLeft` |
| `TURN_RIGHT`, `우회전` | `.turnRight` |
| `SLIGHT_LEFT` | `.turnSlightLeft` |
| `SLIGHT_RIGHT` | `.turnSlightRight` |
| `UTURN`, `유턴` | `.uturn` |
| `STAIRS_UP`, `계단(상)` 키워드 + 다음 floorLevel 증가 | `.stairsUp` |
| `STAIRS_DOWN`, `계단(하)` 키워드 + 다음 floorLevel 감소 | `.stairsDown` |
| `ELEVATOR`, `엘리베이터` | `.elevator` |
| `ARRIVE`, `도착` | `.arrive` |
| 그 외 | `.unknown` (icon: `arrow.up`, label: `진행`) |

### 거리·걸음·시간 계산
- `approxSteps = max(1, Int(round(distanceMeters / 0.7)))`
- `remainingMinutes = max(1, Int(round(remainingTotalMeters / 1.2 / 60)))` — 1.2 m/s 보행 가정
- 보행 속도/보폭 상수는 `ARNavigationLogic` 의 private static let 으로 두어 매직 넘버 회피.

## ARNavigationLogic 변경 사항
1. `currentStepIndex: Int` 멤버 추가 (기본 0). 위치 갱신 tick 마다 가장 가까운 step 으로 갱신 — **이번 phase 에서는 단순 구현: 마지막 측위된 카메라 위치와 각 step.position 의 거리(같은 floorLevel) 중 최소값의 인덱스로 결정**. PnP 영향 별도 고려하지 않는다.
2. `lastPathSteps` 와 `currentStepIndex` 로부터 `NavigationStepViewModel` 을 만들어 `delegate.updateNavigationStep(_:)` 호출.
3. 호출 시점:
   - 경로 첫 그려질 때 (`drawPathFromSteps(_:)` 끝부분).
   - tracking tick 에서 위치 갱신 후.
   - 층 전환 종료 후 `restartFromFloorTransition()` 끝부분.

## ARNavigationViewController 변경 사항

### 신규 멤버
```swift
private var newCloseButton: UIButton!         // 좌상단 원형 X (구 closeButton 재구성/대체)
private var destinationPillView: UIView!      // (기존 pill 재구성)
private var destinationIconCircle: UIView!
private var destinationFloorLabel: UILabel!
private var destinationNameLabel: UILabel!

private var currentStepCardView: UIView!
private var currentStepIconBox: UIView!
private var currentStepIconView: UIImageView!
private var currentStepActionLabel: UILabel!
private var currentStepDistanceLabel: UILabel!  // attributed: "12" + "m"
private var currentStepWalkLabel: UILabel!      // "약 4걸음"

private var remainingStepsToggleButton: UIButton!  // "+N단계 ⌄"

private var remainingCapsuleView: UIView!
private var remainingCapsuleLabel: UILabel!  // attributed: "남은 거리 84m | 약 2분"
```

### 신규 setup 함수 (모두 setupHUD 분해)
- `setupCloseButton()` — 기존 갱신 (좌상단 원형 + blur)
- `setupDestinationPill()`
- `setupCurrentStepCard()`
- `setupRemainingStepsToggle()`
- `setupRemainingCapsule()`
- `setupRelocalizeButton()` — 기존 `setupLocateButton` 갱신/재배치

기존 `setupHUD()` 는 폐기하고 위 5개 함수를 `viewDidLoad()` 흐름에서 차례로 호출. `instructionCardView` 는 더 이상 화면에 추가하지 않는다 (멤버 변수 자체는 일단 보존하고 dead code 제거는 후속 phase).

### `updateNavigationStep(_:)` 구현
1. 메인 스레드 보장.
2. `destinationFloorLabel.text = "\(vm.destinationFloorLevel ?? 0)F · 목적지"`
3. `destinationNameLabel.text = vm.destinationName`
4. `currentStepIconView.image` 를 action 별 SF Symbol 로 설정.
5. `currentStepActionLabel.text` 를 action 한국어 텍스트로 (`.straight → "직진"` 등).
6. `currentStepDistanceLabel.attributedText` = "12" 28pt heavy + "m" 16pt regular.
7. `currentStepWalkLabel.text = "약 \(vm.approxSteps)걸음"`.
8. `remainingStepsToggleButton.isHidden = vm.remainingExtraStepsCount <= 0`. 보일 경우 타이틀 `"+\(vm.remainingExtraStepsCount)단계"`.
9. `remainingCapsuleLabel.attributedText` = "남은 거리 " + "\(Int(vm.remainingTotalMeters))m" (systemBlue heavy) + " | " + "약 \(vm.remainingMinutes)분".

### `setHUDVisible(_:)` 갱신
신규 HUD 모두 `hudContainerView` 자식 — 기존 동작 유지 (컨테이너 hidden 토글).

### `setupRemainingStepsToggle` 액션
탭 시 임시: `let sheet = UIViewController()` 에 `.systemBackground`, `sheetPresentationController?.detents = [.medium()]` 로 표시. 내용은 후속 phase placeholder.

## 폐기/유지 정리
- 폐기(코드 삭제 X, 호출만 끊음): `instructionCardView`, `instructionLabel`, `remainingDistanceLabel` 의 신규 ViewController 흐름에서 제거.
- 유지: `arrivalBadge`, `scanCompleteBadge`, `scanFailedView`, `routeCalculatingView`, `floorTransitionOverlay`, `headingAlignmentOverlay`, `turnCardView`. — 이번 redesign 범위 외.

## 비범위
- step 리스트 시트 본문 UI (placeholder 만 띄움).
- chevron/ribbon 등 AR 노드 디자인.
- 헤딩 정렬 오버레이.
- 도착 알림 시각화.
- 다크/라이트 테마 토글.

## 테스트 시나리오
1. 경로 계산 직후 첫 step 표시 확인 — 거리, 걸음 수, 액션 한국어, 잔여 거리/시간.
2. 사용자가 첫 step 통과 후 두번째 step 으로 currentStepIndex 가 갱신되어 카드가 바뀌는지 확인.
3. 잔여 step 1 개일 때 `+N단계` 버튼이 사라지는지 확인.
4. 층 전환 모달 후 복귀 시 `setHUDVisible(true)` 와 함께 새 카드가 정상 노출되는지.
5. `재측정` 탭 → 기존 `onLocateButtonTapped()` 호출되는지.
6. 닫기(X) 탭 → 기존 `onCloseButtonTapped()` 호출되는지.
