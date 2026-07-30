# ClaudeUsage 작업 계획

최종 갱신: 2026-07-30

이 문서는 현재 진행 기준과 남은 작업만 관리합니다. 과거 통합 로그는 Git commit history와 release note를 기준으로 확인하고, 이 파일에는 오래된 상세 변경 이력을 누적하지 않습니다.

## 0. 현재 운영 상태

- `main`은 검증이 끝난 squash commit만 두는 배포 기준 브랜치입니다.
- 기능과 유지보수 작업은 최신 `main`에서 정렬한 `dev`에 작업 단위별 커밋으로 쌓고, 전체 검증 후 `main`에 squash 반영합니다.
- `gh-pages` 는 Sparkle appcast와 GitHub Pages 정적 파일을 올리는 배포 산출물 브랜치입니다.
- staging은 브랜치가 아니라 `vX.Y.Z-staging` prerelease와 `channels/staging/appcast.xml` 로 운영하는 release channel입니다.
- prod는 staging 검증이 끝난 버전만 `vX.Y.Z` stable release와 root `appcast.xml` 로 게시합니다.
- 배포 절차, GitHub 계정 전환, 개인 로컬 파일 관리 기준은 [docs/PROJECT_WORKFLOW.md](docs/PROJECT_WORKFLOW.md) 를 따릅니다.

## 1. 현재 진행 작업

- AGY v2 group × cadence quota runtime, 구조화 RPC, process lifecycle, OAuth
  계정 저장소, migration, refresh orchestration과 모든 표시 surface 연결은
  완료되어 staging에서 검증 중입니다.
- Claude/Codex/Antigravity의 standard·compact·메뉴바·설정 표시 모델과 공용
  design-system component를 유지하고, provider별 예외는 typed adapter와
  metadata 경계 안에 둡니다.
- 현재 후보 2.4.7은 상태 badge 클리핑과 Claude 하드코딩 외부 링크를
  수정합니다. Claude/Codex의 사용량·공식 상태 링크는 하나의 provider
  descriptor에서 팝오버, 설정 미리보기, 우클릭 메뉴, 단축키로 투영합니다.
- 2.4.7 staging 게시 후 사용자가 `/Applications/ClaudeUsage-stg.app`을 직접
  실행해 메뉴바 표시, provider 전환, 외부 링크, AGY 조회, 단일 인스턴스를
  확인하기 전에는 prod를 게시하지 않습니다.

## 2. 완료된 주요 정리

- Sparkle 기반 업데이트와 GitHub Release fallback 경계를 정리했습니다.
- `prod` / `staging` appcast 채널을 분리했고, `gh-pages` 게시 스크립트를 기준 절차로 고정했습니다.
- `main` 단일 코드 브랜치와 release channel 운영 방식을 문서화했습니다.
- DMG, Downloads, App Translocation 실행 시 `Applications` 이동 안내를 추가했습니다.
- 이동 과정에서 기존 실행본이 있으면 먼저 종료를 요청해 중복 실행을 줄였습니다.
- 설치 후 남은 DMG를 휴지통으로 이동하는 안내를 추가했습니다.
- Claude `resets_at` 을 정각 리셋이 아니라 갱신 예상 시각으로 취급하도록 정리했습니다.
- 임계값 알림은 reset time 변경이 아니라 사용률 상태 전이 기준으로 동작하도록 분리했습니다.
- Codex/Gemini 계열의 토큰 만료 상황은 먼저 refresh를 시도하고, 실패 시 재로그인 안내로 내려가도록 정리했습니다.
- 설정 UI는 일반 사용자에게 필요한 상태와 다음 행동을 먼저 보여주고, 상세/복구 정보는 접힌 고급 영역으로 내리는 방향으로 정리했습니다.

## 3. 현재 제품 기준

- 기본 제품 축은 `Claude` 중심 multi-provider menubar app입니다.
- runtime provider는 `Claude`, `Codex`, `Antigravity`입니다. AGY quota의
  `Gemini`는 Antigravity 내부 quota group이지 별도 app provider가 아닙니다.
- `Antigravity`는 2.0 로컬 앱 API, `agy` CLI 감지, Google OAuth 원격 quota 조회, multi-account OAuth 설정 UX까지 현재 runtime provider 기준으로 정리되어 있습니다.
- 기본 활성화는 Claude 중심이고, 다른 provider는 사용자가 필요할 때 켜는 정책을 유지합니다.
- 메뉴바는 정상 상태에서 과도한 설명을 줄이고, 문제가 있을 때만 상태 badge/dot으로 신호를 줍니다.
- popover는 일반 보기와 간소화 보기 모두 전역 모드이며, provider별 표시 항목과 순서는 provider 설정에서 조정합니다.
- release build는 Sparkle appcast를 기준으로 업데이트하고, 개발 빌드는 feed/public key가 없으면 GitHub Release fallback을 사용합니다.

## 4. 운영 규칙

- 배포 작업 전 `gh auth switch --hostname github.com --user ChoSeongmin1128` 로 active 계정을 맞춥니다.
- 배포 후 평소 작업 계정이 필요하면 `gh auth switch --hostname github.com --user nathan-glorang` 로 되돌립니다.
- staging 배포는 `./Scripts/release.sh stg X.Y.Z`로 실행하고 driver가
  `vX.Y.Z-staging` prerelease와 staging feed를 고정합니다.
- prod 배포는 staging 검증 후 `./Scripts/release.sh prod X.Y.Z`로 실행하고
  driver가 `vX.Y.Z` stable release와 prod feed를 고정합니다.
- staging과 prod는 앱에 들어가는 `SUFeedURL` 이 다르므로 같은 커밋이어도 산출물을 각각 다시 빌드합니다.
- `Config/Sparkle.release.local.xcconfig`, notarization key, SSH alias, 로컬 DMG/ZIP 산출물은 저장소에 올리지 않습니다.

## 5. 남은 리스크

- v2.3.3 prod 이후 2.4.x 누적 변경이 크므로 자동 테스트만으로 prod 승인을
  내리지 않습니다. 기존 2.3.3 데이터 upgrade, AGY 설치/미설치/신뢰 거부,
  multi-monitor 상태 항목, Sparkle upgrade를 staging에서 수동 확인해야 합니다.
- 메뉴바와 refresh 경로는 일반화됐지만 Claude 전용 로그인 복구 화면처럼
  의도적인 provider 전용 흐름과 제거 대상 하드코딩을 계속 구분해야 합니다.
- first-run onboarding과 권한 설명은 계속 실제 사용자 실패 사례 기준으로 줄이고 보강해야 합니다.
- 설치 위치 이동은 앱 내부 버튼 흐름에서는 재실행을 다루지만, Finder에서 DMG를 수동 드래그하는 경우 자동 실행되지 않는 macOS 기본 동작은 바꿀 수 없습니다.
- Sparkle 자동 업데이트는 설치 권한, 실행 위치, 기존 실행본 상태에 영향을 받으므로 릴리스마다 별도 Mac에서 확인해야 합니다.

## 6. 다음 작업 후보

- 2.4.7 staging 수동 QA 결과를 기록하고 prod gate를 통과/보류로 명시합니다.
- Antigravity managed CLI 자동 실행 정책을 일반 사용자에게 충분히 설명하는지
  별도 prod 정책 검토를 완료합니다.
- first-run wizard에서 권한 요청 이유와 실패 시 다음 행동을 더 짧게 정리합니다.
- 문서와 UI copy에서 내부 구현어가 다시 새지 않는지 정기적으로 점검합니다.

## 7. 기준 문서

- 프로젝트 작업 방식: [docs/PROJECT_WORKFLOW.md](docs/PROJECT_WORKFLOW.md)
- 배포 절차: [docs/RELEASE.md](docs/RELEASE.md)
- Apple Developer / 업데이트 전략: [apple-developer-update.md](apple-developer-update.md)
- 인증과 사용량 소스: [docs/authentication-and-sources.md](docs/authentication-and-sources.md)
- Antigravity 현행(개편 전) 사용량 소스와 설정 UX: [docs/antigravity-usage-sources.md](docs/antigravity-usage-sources.md)
- Antigravity/AGY 전면 개편 구현 계획: [docs/antigravity-usage-rewrite-plan.md](docs/antigravity-usage-rewrite-plan.md)
