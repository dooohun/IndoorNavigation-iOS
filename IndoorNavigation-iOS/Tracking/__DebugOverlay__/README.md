# __DebugOverlay__

이 폴더는 SuperPoint 디버그 시각화 전용입니다.

- 모든 파일은 `#if DEBUG` 가드로 보호되어 릴리즈 빌드에서 컴파일되지 않습니다.
- 본 모듈(Tracking/) 의 어떤 파일도 이 폴더를 import 하지 않습니다 (단방향 의존: 시각화 → 본 모듈).
- 프로덕션 배포 전 또는 디버그 시각화가 더 이상 필요 없을 때 **이 폴더 통째로 삭제** 가능합니다.

삭제 시 함께 제거할 항목:
- `ARNavigationViewController.swift` 의 `#if DEBUG ... #endif` 블록 내 `SuperPointDebugController` 인스턴스화·연결 코드
- `ARNavigationLogic.swift` 의 `#if DEBUG` 가드 내 디버그 콜백 호출
