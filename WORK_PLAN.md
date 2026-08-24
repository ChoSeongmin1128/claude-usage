# ClaudeUsage 작업 계획

최종 갱신: 2026-08-24

이 문서는 현재 진행 중이거나 실제로 남은 작업만 관리합니다. 완료된 변경의
연대기는 Git history와 GitHub Release를 사용하고 이 파일에 누적하지 않습니다.

## 1. 현재 운영 상태

- 현재 prod는 `2.4.11 (20411)`, staging은 `2.4.12 (20412)`(기준 커밋 `c03f892`)입니다.
- `main`, `dev`, `origin/main`, `origin/dev`는 같은 기준 커밋에 정렬돼 있습니다.
- prod/staging public appcast는 각각 `v2.4.11`, `v2.4.12-staging`의 원격
  ZIP을 가리킵니다.
- 현재 진행 중 작업: 아래 `1.1 managed recovery 자가 치유` (2.4.12 staging 후보).
- App Store가 아니라 Developer ID 공증, GitHub Release, Sparkle appcast로
  직접 배포합니다.

### 1.1 진행 중: managed recovery 자가 치유와 차단 상태 표시 (2.4.12 후보)

실사례(2026-08-24): prod 원장에 8월 19의 `incomplete` managed 세션 기록이
남아 recovery가 영구 차단됐고, managed 자동 실행이 5일간 조용히
비활성화됐다. 사용자에게는 원인과 무관한 "조회 계정 또는 로그인 필요"가
표시됐다. 즉시 복구는 stale 원장 파일 제거로 완료(백업 보관), 코드 수정이
이 항목이다.

1. [완료] recovery가 기록된 실행(owner/child/descendants)이 전부 확실히
   죽었음이 증명되는 incomplete 기록을 stale로 정리 (ambiguous하면 기존
   fail-closed 유지).
2. [완료] recovery 차단 상태를 setup 사유 `managedRecoveryBlocked`로
   구분해 팝오버/설정에 "이전 AGY 실행 정리 필요"로 표시.
3. [완료] dev 검증(전체 XCTest 980개, live AGY, 코드 리뷰 10건 반영) 후
   main squash(`c03f892`), `v2.4.12-staging` 게시와 원격 검증 완료.
4. [남음] 사용자 staging 실앱 QA(권장: 백업해 둔 8월 19 stale 원장을
   staging 원장에 심어 자가 치유를 실증) 후 prod 승격 판단.

## 2. 최근 완료

- managed AGY readiness를 인증된 계정 identity 기준으로 강화하고(공용
  userStatus 인증 증거 분류, 인증 대기 시 같은 endpoint 폴링, 예산 소진 시
  loginRequired 귀속, identity 재시도 확대, ETXTBSY spawn 재시도)
  `2.4.11`로 staging·prod에 게시했습니다.

- Claude, Codex, Antigravity의 provider 표시 component와 설정 UX를 통합했습니다.
- Antigravity를 group × cadence quota, 구조화 local RPC, borrowed/managed AGY,
  선택 계정 OAuth, typed display settings 구조로 전환했습니다.
- managed AGY의 정확한 HTTPS bootstrap port와 PTY backpressure 처리를 고정했습니다.
- prod/staging 앱 identity와 단일 인스턴스 경계를 분리했습니다.
- release driver가 legacy production release metadata도 검증하도록 보강했습니다.
- 메뉴바 appearance 관찰 → 렌더 → 재관찰 loop를 제거하고 semantic render key,
  요청 coalescing, provider icon cache를 추가해 지속 고 CPU 문제를 수정했습니다.
- 수정본을 staging과 prod `2.4.10`으로 게시하고 사용자가 prod Sparkle 업데이트와
  직접 실행 상태를 확인했습니다.

## 3. 현재 유지보수 목표

### 릴리스 회귀 방지

- 다음 후보마다 통합 release driver의 전체 XCTest, shell test, 공식 AGY live
  integration, notarization, 원격 artifact, Pages public feed 검증을 유지합니다.
- 설치 앱은 자동화 도구가 실행하지 않고 사용자가 Finder의 Applications에서
  직접 실행해 메뉴바와 ControlCenter 상태를 확인합니다.
- published tag, release, asset은 immutable입니다. blocker가 있으면 다음 numeric
  patch candidate를 만듭니다.

### CPU·메뉴바 회귀 감시

- idle 시 ClaudeUsage가 지속적으로 한 코어를 점유하지 않는지 확인합니다.
- 사용량 변화가 없을 때 status item content와 image를 반복 적용하지 않아야 합니다.
- light/dark/high-contrast 전환은 실제 의미 변화마다 한 번만 갱신돼야 합니다.
- ClaudeUsage idle 상태에서 WindowServer가 지속적으로 과도하게 동작하지 않는지
  함께 확인합니다.

### 인증·AGY 호환성

- Claude 계정 전환에서 Keychain prompt와 이전 계정 provenance 혼입을 방지합니다.
- Antigravity local RPC와 OAuth 응답 shape가 바뀌면 가짜 0%/100%로 숨기지 않고
  typed failure나 identity-only 상태로 드러냅니다.
- borrowed AGY는 종료하지 않고 owned process tree만 정리합니다.
- 사용자가 고르는 것은 조회 계정이며 source 순서는 앱 정책으로 유지합니다.

### 문서 유지

- 버전이나 release gate가 바뀌는 작업은 `HANDOFF.md`, 이 문서와 관련 reference를
  같은 release task에서 갱신합니다.
- 현재 상태 문서에 과거 버전별 진행 로그를 누적하지 않습니다.
- `AGENTS.md`가 로컬 agent rule의 원본이며 `CLAUDE.md`는 `@AGENTS.md` 한 줄만
  유지합니다.

## 4. 다음 작업 후보

아래 항목은 blocker가 아니라 다음 유지보수 후보입니다.

- 장시간 idle·appearance 전환·화면 잠금/해제에서 2.4.10 CPU 회귀 관찰
- 별도 Mac에서 실제 이전 prod → 다음 staging Sparkle upgrade 반복 검증
- Antigravity upstream AGY 및 Cloud Code Assist payload 변화 감시
- first-run 권한 설명과 실패 후 다음 행동의 문구 단순화
- 메뉴바/팝오버 accessibility label과 compact 폭 회귀 점검

## 5. 기준 문서

- 현재 인계: [HANDOFF.md](HANDOFF.md)
- 프로젝트 작업 방식: [docs/PROJECT_WORKFLOW.md](docs/PROJECT_WORKFLOW.md)
- 배포 절차: [docs/RELEASE.md](docs/RELEASE.md)
- Apple Developer / 업데이트 전략: [apple-developer-update.md](apple-developer-update.md)
- Claude 인증과 사용량 소스: [docs/authentication-and-sources.md](docs/authentication-and-sources.md)
- Antigravity 현재 계약: [docs/antigravity-usage-sources.md](docs/antigravity-usage-sources.md)
- 완료된 Antigravity 구현 계획: [docs/antigravity-usage-rewrite-plan.md](docs/antigravity-usage-rewrite-plan.md)
