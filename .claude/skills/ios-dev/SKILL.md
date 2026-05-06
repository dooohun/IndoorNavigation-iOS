---
name: ios-dev
description: iOS ARKit 기반 실내 내비게이션 앱의 모든 코드 변경을 처리하는 오케스트레이터 스킬. 기능 추가, 버그 수정, UI 수정, AR 개선, API 연동 등 Swift/iOS 코드 수정 요청이 들어오면 반드시 이 스킬을 사용할 것. "만들어줘", "수정해줘", "추가해줘", "고쳐줘", "다시 해줘", "업데이트해줘" 같은 구현 요청 모두 포함. 단순 코드 설명이나 질문은 이 스킬 없이 직접 응답 가능.
---

# ios-dev 오케스트레이터

iOS 개발 요청을 **ios-planner → ios-implementer → ios-reviewer** 파이프라인으로 처리한다.

**실행 모드**: 에이전트 팀 (TeamCreate + TaskCreate + SendMessage)

**데이터 전달 방식**: SendMessage **본문 기반**. 산출물은 메시지 마크다운에 직접 담아 주고받는다 — 별도 `_workspace/` 파일 저장 없음. 짧은 3단 파이프라인이라 메시지로 충분히 표현되며, 후속 세션에서도 대화 컨텍스트로 추적 가능.

## Phase 0: 컨텍스트 확인

대화 컨텍스트로 후속 작업 여부를 판별한다:

| 단서 | 판단 | 조치 |
|------|------|------|
| 현 세션에 직전 계획·구현·리뷰 메시지가 있고 사용자가 "수정해줘", "다시 해줘" 등 부분 변경 요청 | 부분 재실행 | 해당 단계 에이전트만 재호출, 변경된 부분만 새 메시지로 |
| 현 세션에 직전 흐름이 없거나 사용자가 새 기능을 요청 | 초기 실행 | Phase 1부터 진행 |
| 사용자가 명확화 질의에 답변 | 진행 중 흐름 재개 | 해당 시점 에이전트에게 답변 전달 후 계속 |

## Phase 1: 팀 구성

```
TeamCreate(
  team_name: "ios-dev-team",
  members: ["ios-planner", "ios-implementer", "ios-reviewer"]
)
```

3개 태스크를 의존 관계와 함께 생성한다 (모든 산출물은 SendMessage 본문):

```
TaskCreate("plan", assignee="ios-planner",
  description="요청 분석 및 구현 계획 수립. 계획을 SendMessage 본문에 담아 팀 전체에 전송.")

TaskCreate("implement", assignee="ios-implementer",
  description="플래너 메시지의 계획대로 코드 변경 실행. 변경 요약을 SendMessage 본문에 담아 리뷰어에게 전송.",
  depends_on=["plan"])

TaskCreate("review", assignee="ios-reviewer",
  description="실제 변경된 파일을 Read하여 검토. 결과(PASS/PASS_WITH_NOTES/FAIL)를 SendMessage 본문에 담아 발신.",
  depends_on=["implement"])
```

모든 Agent 호출에는 `model: "opus"` 명시.

## Phase 2: 파이프라인 실행

### 2-1. 플래너 실행

ios-planner에게 SendMessage:
```
[오케스트레이터] 작업 시작. plan 태스크를 in_progress로 업데이트하고 계획 수립 후 메시지 본문에 담아 팀에 알려줘.

요청: {사용자 요청 내용 전문}

프로젝트 경로: /Users/kimdohun/Desktop/University/2026_1/IndoorNavigation-iOS/IndoorNavigation-iOS/
관련 Phase 문서를 먼저 읽고 영향 파일을 직접 Read한 뒤 구체적 계획을 작성할 것.
```

플래너의 완료 메시지(`[플래너] 계획 완료` + 마크다운 계획 본문)를 기다린다.

### 2-2. 임플리멘터 실행

ios-implementer에게 SendMessage:
```
[오케스트레이터] implement 태스크 시작.

플래너의 계획은 직전 메시지에 담겨 있어. 그대로 구현하고 결과 요약을 본문에 담아 리뷰어에게 알려줘.

전문 스킬 로드:
- API 관련 변경이면 `api-integration` 스킬을 읽고 패턴 따를 것
- AR 관련 변경이면 `ar-rendering` 스킬을 읽고 패턴 따를 것
- 두 영역에 걸치면 둘 다 로드
```

임플리멘터의 완료 메시지(`[임플리멘터] 구현 완료` + 변경 요약 본문)를 기다린다.

### 2-3. 리뷰어 실행

ios-reviewer에게 SendMessage:
```
[오케스트레이터] review 태스크 시작.

플래너 계획 + 임플리멘터 구현 메시지가 직전에 있어. 실제 변경된 파일을 직접 Read로 확인하고 검토 결과를 본문에 담아 발신해줘.
```

리뷰어 결과 처리:
- `PASS` / `PASS_WITH_NOTES` → Phase 3 진행
- `FAIL` → 리뷰어 메시지의 CRITICAL 항목을 임플리멘터에게 수정 요청, 2-2부터 반복 (최대 2회)

## Phase 3: 완료 처리

1. 리뷰어의 최종 판정 확인
2. 사용자에게 결과 보고:
   ```
   ## 작업 완료

   **변경 파일**: (임플리멘터 메시지 기반)
   **리뷰 판정**: PASS / PASS_WITH_NOTES
   **주요 변경 내용**: (요약)

   (PASS_WITH_NOTES인 경우) **참고 사항**: (WARNING 목록)
   ```
3. 팀 정리: 모든 태스크 completed로 업데이트

## 에러 핸들링

| 상황 | 처리 |
|------|------|
| 플래너 응답 없음 (5분+) | 플래너에게 재전송 1회, 그 후 직접 계획 수립 후 임플리멘터로 진행 |
| 임플리멘터가 명확화 요청 | 메시지를 플래너에게 그대로 전달 |
| 임플리멘터 2회 재작업 후 FAIL | 리뷰어 보고 + 사용자에게 에스컬레이션 (판정 강등 권한은 리뷰어에게 위임) |
| 팀원이 사용자 명확화를 요청 | AskUserQuestion으로 사용자 확인 후 해당 팀원에게 답변 전달 |

## 후속 작업 처리

사용자가 직전 작업 결과에 대해 "다시 해줘", "수정해줘", "추가해줘" 요청 시:

1. 대화 컨텍스트에서 직전 계획·구현·리뷰 메시지를 찾는다
2. 변경 범위에 따라 호출할 에이전트 결정:
   - "이 부분만 다시 구현" → 임플리멘터만 재호출 (계획은 그대로)
   - "계획부터 다시" → 플래너부터 재실행
   - "리뷰 결과의 WARNING도 고쳐줘" → 임플리멘터 재호출 + 리뷰어 재검토
3. 이전 메시지 컨텍스트를 새 SendMessage 본문에 인용하여 명확하게 전달

## 테스트 시나리오

**정상 흐름**: "POI 검색 결과가 없을 때 '결과 없음' 메시지를 표시해줘"
- 플래너: `POISelectionViewController.swift` Read → 영향 함수 식별 → 빈 배열 분기 추가 계획을 메시지로 발신
- 임플리멘터: `api-integration` 스킬 로드 (검색 API 패턴 확인) → 빈 배열 처리 UI 추가 → 변경 요약 발신
- 리뷰어: 메인 스레드 업데이트 확인, retain cycle 없음 → PASS

**에러 흐름 (재작업)**: 임플리멘터가 계획에 없는 파일을 추가 수정 → 리뷰어 FAIL (CRITICAL: 범위 일탈) → 임플리멘터가 해당 변경 되돌림 → 리뷰어 PASS

**층 전환 관련 변경 흐름**: "층 이동 모달의 닫기 버튼을 추가해줘"
- 플래너: `phase3_floor_transition.md` 참조 → `ARNavigationViewController.swift`의 모달 정의 위치 식별 → delegate `hideFloorTransition` 호출 경로 검토 후 계획 작성
- 임플리멘터: `ar-rendering` 스킬 로드 → 모달 UI 변경 + delegate 호출 추가
- 리뷰어: ARKit 세션 정상 유지 + `hasActiveFloorTransition` 플래그 정합성 확인 → PASS
