# ClaudeUsage 유지보수 인계

최종 갱신: 2026-08-24

이 문서는 현재 릴리스 상태와 다음 작업의 시작점만 기록합니다. 2.4.0~2.4.8
구현 과정과 과거 staging 기록은 Git history, GitHub Release, 완료된
[Antigravity 재작성 계획](docs/antigravity-usage-rewrite-plan.md)을 확인합니다.

## 1. 현재 기준

- 저장소: `/Users/seongmin/Personal/maintenance/ClaudeUsage`
- 원격: `git@github-seongmin:ChoSeongmin1128/claude-usage.git`
- 게시된 릴리스 기준 커밋(`main`): `8fa58906baf60a780cfb28029e753e44122b22a5`
- 게시된 버전/build: `2.4.10 (20410)` — prod `v2.4.10`, staging `v2.4.10-staging`
- prod/staging public appcast: 모두 `2.4.10 (20410)`
- `dev`는 `2.4.11-staging` 후보(managed AGY readiness 인증 게이트)를
  진행 중이며, 상세 범위는 [WORK_PLAN.md](WORK_PLAN.md)를 따릅니다
- 배포: Developer ID 공증 GitHub Release + Sparkle appcast
- App Store 배포가 아님

`v2.4.10`은 메뉴바 appearance 관찰과 반복 렌더가 서로를 다시 깨우면서
ClaudeUsage가 CPU 한 코어를 지속적으로 점유하던 문제를 수정한 릴리스입니다.
동일한 의미 상태는 다시 렌더하지 않고, 같은 run loop의 요청은 합치며, 실제
appearance·사용량·provider·표시 설정 변화만 render key를 무효화합니다.

## 2. 현재 제품 구조

- 런타임 provider는 Claude, Codex, Antigravity입니다.
- Claude는 Web session과 Claude Code OAuth를 주 소스로 사용하고 Messages
  header는 명시적인 보조 복구 경로로만 사용합니다.
- Antigravity 자동 조회 순서는 local app → borrowed AGY → managed AGY이며,
  선택한 Google 계정이 있으면 마지막에 해당 계정 OAuth를 시도합니다.
- managed AGY는 검증된 Google 서명 실행 파일만 시작하고, ClaudeUsage가 소유한
  process tree만 idle timeout 또는 종료 시 정리합니다.
- Antigravity의 Gemini와 Claude·GPT 사용량은 group × cadence lane으로 보존하며
  standard/compact 다중 lane과 메뉴바 단일 lane 설정을 각각 지원합니다.
- provider 설정은 공통 design-system component와 provider별 typed adapter를
  사용합니다.
- prod와 staging은 앱 이름, bundle ID, 저장소, Sparkle feed, 단일 인스턴스
  경계가 분리되어 각 채널당 하나씩 동시에 실행할 수 있습니다.

## 3. 현재 배포·검증 상태

- `v2.4.10`과 `v2.4.10-staging`은 같은 기준 커밋에서 게시됐습니다.
- GitHub Release의 두 채널 release note는 지속 메뉴바 렌더 loop와 고 CPU 수정
  내용을 가리킵니다.
- 2026-08-14 직접 조회한 prod/staging public appcast는 각각 올바른 채널의
  `ClaudeUsage.zip`과 `2.4.10 (20410)`을 가리킵니다.
- 사용자가 `/Applications/ClaudeUsage.app`을 Sparkle로 업데이트하고 직접
  실행한 뒤 CPU 상태가 정상으로 보인다고 확인했습니다.
- 다음 릴리스에서도 통합 driver의 전체 XCTest, release-driver test, 실제 로그인된
  공식 AGY live integration, 공증, 원격 재다운로드 검증을 다시 통과해야 합니다.

## 4. 남은 운영 리스크

- Antigravity local RPC와 Google Cloud Code Assist endpoint는 공개 안정 API가
  아니므로 upstream shape와 AGY bootstrap 동작 변화에 민감합니다.
- macOS 26 ControlCenter는 자동화 호스트가 메뉴바 앱을 실행할 때 status item
  attribution을 오염시킬 수 있습니다. 설치 앱 최종 QA는 사용자가 Finder의
  Applications에서 직접 실행해 확인합니다.
- 메뉴바는 장시간 idle 상태에서 ClaudeUsage와 WindowServer CPU가 안정되는지,
  appearance 전환 때 한 번만 갱신되는지 회귀 확인해야 합니다.
- Claude 계정 전환은 legacy `claude-session-key` 부재, migration version,
  credential provenance, Keychain/password prompt 부재를 함께 확인해야 합니다.
- Sparkle upgrade는 설치 위치·권한·실행 중인 기존 프로세스 영향을 받으므로
  staging에서 실제 이전 버전 → 후보 버전 업데이트를 검증합니다.

## 5. 다음 작업 시작점

진행 중 작업은 [WORK_PLAN.md](WORK_PLAN.md)의 `1.1`(managed AGY readiness
인증 게이트, 2.4.11 후보)입니다. 새 작업은 아래 순서로 시작합니다.

1. `main`, `dev`, 원격과 public feed의 현재 상태를 다시 확인합니다.
2. 새 작업은 최신 `main`에 정렬한 `dev`에서 coherent commit으로 진행합니다.
3. 영향 범위 테스트와 전체 검증, 실제 앱 QA, 코드 리뷰를 완료합니다.
4. 문서 계약이 바뀌면 같은 release task에서 관련 문서를 함께 갱신합니다.
5. 검증한 `dev` tree를 `main`에 squash하고 exact tree 일치를 확인합니다.
6. 통합 `Scripts/release.sh`로 새 numeric staging 후보를 게시합니다.

## 6. 문서 권위

- 로컬 에이전트 규칙: `AGENTS.md` (`CLAUDE.md`는 `@AGENTS.md`만 포함)
- 현재 작업: [WORK_PLAN.md](WORK_PLAN.md)
- 제품 개요: [README.md](README.md)
- 브랜치·채널·계정: [docs/PROJECT_WORKFLOW.md](docs/PROJECT_WORKFLOW.md)
- 배포 절차: [docs/RELEASE.md](docs/RELEASE.md)
- Claude 인증: [docs/authentication-and-sources.md](docs/authentication-and-sources.md)
- Antigravity 현재 계약: [docs/antigravity-usage-sources.md](docs/antigravity-usage-sources.md)
- Antigravity 구현 역사: [docs/antigravity-usage-rewrite-plan.md](docs/antigravity-usage-rewrite-plan.md)
