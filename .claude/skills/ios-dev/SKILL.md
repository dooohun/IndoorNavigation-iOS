---
name: ios-dev
description: iOS ARKit 기반 실내 내비게이션 앱의 모든 코드 변경을 처리하는 오케스트레이터 스킬. 기능 추가, 버그 수정, UI 수정, AR 개선, API 연동 등 Swift/iOS 코드 수정 요청이 들어오면 반드시 이 스킬을 사용할 것. "만들어줘", "수정해줘", "추가해줘", "고쳐줘", "다시 해줘", "업데이트해줘" 같은 구현 요청 모두 포함. 단순 코드 설명이나 질문은 이 스킬 없이 직접 응답 가능.
---

# ios-dev 오케스트레이터

iOS 개발 요청을 **ios-planner → ios-implementer → ios-reviewer** 파이프라인으로 처리한다.

**실행 모드**: 에이전트 팀 (TeamCreate + TaskCreate + SendMessage)

## Phase 0: 컨텍스트 확인

시작 전 `_workspace/` 존재 여부를 확인한다:

| 상태 | 판단 | 조치 |
|------|------|------|
| `_workspace/` 없음 | 초기 실행 | 그대로 진행 |
| `_workspace/` 있고 부분 수정 요청 | 후속 실행 | 해당 에이전트만 재호출 |
| `_workspace/` 있고 새 요청 | 새 실행 | 기존 `_workspace/`를 `_workspace_prev/`로 이동 후 진행 |

## Phase 1: 팀 구성

```
TeamCreate(
  team_name: "ios-dev-team",
  members: ["ios-planner", "ios-implementer", "ios-reviewer"]
)
```

3개 태스크를 의존 관계와 함께 생성한다:

```
TaskCreate("plan", assignee="ios-planner", 
  description="요청 분석 및 구현 계획 수립. 결과를 _workspace/01_planner_plan.md에 저장")

TaskCreate("implement", assignee="ios-implementer",
  description="plan 완료 후 코드 변경 실행. 결과를 _workspace/02_implementer_log.md에 저장",
  depends_on=["plan"])

TaskCreate("review", assignee="ios-reviewer",
  description="implement 완료 후 코드 리뷰. 결과를 _workspace/03_reviewer_report.md에 저장",
  depends_on=["implement"])
```

## Phase 2: 파이프라인 실행

### 2-1. 플래너 실행

ios-planner에게 SendMessage로 작업 지시:
```
"[오케스트레이터] 작업 시작. 요청: {사용자 요청 내용 전문}. 
프로젝트 경로: /Users/kimdohun/Desktop/University/2026_1/IndoorNavigation-iOS/IndoorNavigation-iOS/
plan 태스크를 in_progress로 업데이트하고 계획 수립 후 팀에 알려줘."
```

플래너의 완료 메시지(`[플래너] 계획 완료`)를 기다린다.

### 2-2. 임플리멘터 실행

ios-implementer에게 SendMessage:
```
"[오케스트레이터] implement 태스크 시작. 
계획: _workspace/01_planner_plan.md 참조.
API 관련 변경이면 api-integration 스킬을, AR 관련 변경이면 ar-rendering 스킬을 읽고 작업해줘."
```

임플리멘터의 완료 메시지(`[임플리멘터] 구현 완료`)를 기다린다.

### 2-3. 리뷰어 실행

ios-reviewer에게 SendMessage:
```
"[오케스트레이터] review 태스크 시작. 
계획: _workspace/01_planner_plan.md, 구현 로그: _workspace/02_implementer_log.md 참조."
```

리뷰어 결과 처리:
- `PASS` / `PASS_WITH_NOTES` → Phase 3 진행
- `FAIL` → 임플리멘터에게 수정 요청 (`_workspace/03_reviewer_report.md` 참조), 2-2부터 반복 (최대 2회)

## Phase 3: 완료 처리

1. `_workspace/03_reviewer_report.md`의 최종 판정 확인
2. 사용자에게 결과 보고:
   ```
   ## 작업 완료
   
   **변경 파일**: (02_implementer_log.md 기반)
   **리뷰 판정**: PASS / PASS_WITH_NOTES
   **주요 변경 내용**: (요약)
   
   (PASS_WITH_NOTES인 경우) **참고 사항**: (WARNING 목록)
   ```
3. 팀 정리: 태스크 completed 업데이트

## 에러 핸들링

| 상황 | 처리 |
|------|------|
| 플래너 응답 없음 (5분+) | 플래너에게 재전송 1회, 그 후 직접 계획 수립 |
| 임플리멘터 2회 재작업 후 FAIL | 리뷰어 보고서와 함께 사용자에게 에스컬레이션 |
| 팀원이 명확화 요청 | 사용자에게 AskUserQuestion으로 확인 후 해당 팀원에게 전달 |

## 테스트 시나리오

**정상 흐름**: "POI 검색 결과가 없을 때 '결과 없음' 메시지를 표시해줘"
→ 플래너: POISelectionViewController.swift 영향 파악, 계획 작성
→ 임플리멘터: 빈 배열 처리 UI 추가
→ 리뷰어: 메인 스레드 업데이트 확인, PASS

**에러 흐름**: 임플리멘터가 계획과 다른 파일 수정 → 리뷰어 FAIL → 임플리멘터 재작업 → PASS
