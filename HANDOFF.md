# ClaudeUsage 유지보수 인계

- 갱신일: 2026-07-30
- 저장소: `/Users/seongmin/Personal/maintenance/ClaudeUsage`
- 원격: `git@github-seongmin:ChoSeongmin1128/claude-usage.git`
- 브랜치: `main`
- 배포 기준: Developer ID 공증 GitHub Release + Sparkle appcast. App Store 배포 아님
- 최신 게시: `v2.4.5-staging` (`0c17c8a`)
- 현재 후보: `2.4.6` (`20406`). 메뉴바 차단 재발 방어 구현과 자동 검증 완료,
  서명된 staging 게시 및 사용자의 Applications 직접 실행 QA 전

## 0. 현재 source of truth

- `main`, `origin/main`, `v2.4.5-staging`은 현재 `0c17c8a`를 가리킨다.
- 2.4.6 후보는 메뉴바 상태 항목 방어만 추가한다. AGY/provider UX 통합은
  2.4.5에 이미 포함됐다.
- 최종 자동 검증: 전체 XCTest 935개 실행, opt-in 2개 skip, 실패 0;
  상태 항목 전용 16개 실패 0; release driver 317개 실패 0.
- 앱 runtime QA를 위해 Codex/Claude/CuaDriver/Terminal `open`으로 설치 앱을
  실행하지 않는다. 사용자가 Finder의 Applications에서 직접 실행한다.
- prod는 2.4.6 staging signed artifact의 실제 메뉴바 표시, 단일 프로세스,
  ControlCenter 차단 로그 부재를 확인하기 전까지 금지한다.

아래 1~10절은 AGY v2 전환 당시의 역사 기록입니다. 현재 배포 판단은 이 절과
11절 이후의 최신 기록을 우선합니다.

## 1. 가장 먼저 읽을 내용

이전 인계 시점의 미커밋 Stage 8 WIP는 모두 커밋됐습니다. working tree에
보존해야 할 변경은 남아 있지 않습니다.

Stage 8을 막고 있던 Developer ID provisioning profile blocker는 profile을
발급하는 대신 **범위 축소로 해소**했습니다. 근거와 되돌린 경계는 7절에
있습니다. 이 결정을 모르고 Data Protection Keychain을 다시 도입하면 서명된
앱에서 AGY 자격 저장이 조용히 실패합니다.

## 2. 사용자 요구와 중지 범위

사용자는 AGY 작업이 기능 이름에 비해 과도하게 커진 점을 지적했습니다.
남은 범위를 다음과 같이 제한합니다.

- Stage 9: 새 기능·새 추상화 금지. legacy 재생성 차단, 삭제, 문서 정합성만
  수행
- Stage 10: 회귀 검증, 실앱 QA, 실제 결함 수정만 수행
- 새로운 보안 강화나 UX 확장은 배포 blocker가 아니면 별도 후속 작업으로
  분리
- 영향 범위 테스트는 구현 중 필요한 만큼 좁게 실행하고, 단계 종료 시
  통합 suite를 한 번 실행
- 목표는 `2.4.0-staging`; 다른 릴리스 범위를 추가하지 않음

사용자의 공통 원칙도 유지합니다.

- 땜질식 수정 금지
- 책임 분리 명확화
- 기존 사용자 migration과 잔여 데이터 제거 보장
- Keychain prompt 없는 업데이트 경로
- `dev`에서 coherent commit마다 push
- 검토 완료 후 `main`에 squash merge
- staging은 `./Scripts/release.sh stg 2.4.0`으로 배포
- tmp/중복 빌드 정리는 단계 종료 시 한 번만 하고 반복 확인하지 않음

## 3. 구현 계획의 source of truth

먼저 아래 문서를 순서대로 읽습니다.

1. `AGENTS.md`
2. `docs/antigravity-usage-rewrite-plan.md`
3. `docs/PROJECT_WORKFLOW.md`
4. `docs/RELEASE.md`

계획 문서 기준 상태:

- Stage 1~9: commit 완료
- Stage 10: 자동 검증 완료. signed QA만 남음 (11절)
- 버전: 2.4.0 (20400)
- `main` squash와 `v2.4.0-staging` 배포: 완료

## 4. 현재 Git 상태

`main`과 `dev`는 같은 commit을 가리킵니다.

```text
31b1548 docs: v2.4.0-staging 게시와 원격 검증 결과를 기록
3fa8563 fix(release): 존재하지 않는 tag를 mismatched로 오판하지 않도록 수정
6286664 feat(antigravity): 사용량 조회를 v2 quota runtime으로 전면 개편 (2.4.0)
1fc02fa v2.3.3
```

`6286664`는 Stage 1~9의 `dev` 25개 commit을 squash한 것입니다. squash 이전
해시(`e96537e`, `221c514`, `919b284`, `173e40a`, `23ecbb1`, `7a390ba`,
`97c12be` 등)는 어느 branch에서도 도달할 수 없으므로 인용하지 않습니다.

## 5. Stage 8에서 전환된 범위

- `AntigravityApplicationBootstrap`과 공용 product runtime composition
- account repository, migration, typed settings, refresh coordinator의 실제
  product path 활성화
- Google OAuth quota client와 account/source provenance 검증
- AppDelegate의 hard-coded legacy `.auto` 경로 제거
- standard, compact, menu bar, settings, notification을 stable quota lane
  presentation으로 전환
- account boundary와 last-good refresh 상태 분리
- 설정 화면의 공용 runtime controller 주입
- OAuth login cancellation과 loopback listener 정리
- 계정/세션 경계의 stale response 및 superseded mutation 차단
- typed AGY menu visibility 사용과 우클릭 menu style 연결
- 새 storage path와 bootstrap/migration activation
- 자격 보관을 배포 가능한 Keychain 경계로 고정 (7절)

## 6. 해소된 review 항목

이전 strict review에서 수정한 항목:

- 실행 중 executable 신뢰: `proc_pidpath` 문자열이나 현재 path를 믿지 않고
  `PROC_PIDREGIONPATHINFO`로 mapped executable vnode의 device/inode/size/
  ctime을 catalog identity와 비교. managed launch는
  `POSIX_SPAWN_START_SUSPENDED` 직후 검사하고 불일치 child는 resume 전에
  kill/reap. Antigravity language server는 `SecCodeCheckValidity`로 signing
  identifier `language_server`와 Team ID `EQHXZ8M8AV`를 동적 검증. 검사 전후
  kernel identity와 `pidVersion`을 비교해 동일 PID의 중간 `exec` 교체 차단
- display mutation race: field-specific `updateMenuBarStyle`과 전체 display
  저장의 `replacing:` expected snapshot CAS, stale settings window의
  `operationSuperseded` 거부
- typed AGY visibility와 legacy visibility 충돌
- 실제로 동작하지 않던 AGY 우클릭 style control
- superseded account mutation의 false-success notice
- OAuth 취소 시 loopback listener/task 누수
- display update와 pending notice consumption의 account boundary race
- 늦은 settings stream revision이 최신 mutation 결과를 덮는 race

이번에 전체 XCTest를 처음 돌리면서 추가로 발견해 고친 항목:

- `PopoverViewModelTests`의 AGY display section 테스트 3건이 cutover 이전
  계약을 검증하고 있었습니다. 이 클래스는 `RefreshOrchestrationTests.swift`
  안에 정의돼 있어 Stage 8 선택 suite(클래스명 지정)로는 실행되지 않았고,
  그래서 회귀가 드러나지 않았습니다. 제품 결함이 아니라 낡은 테스트였고,
  현재 계약(AGY는 legacy `UsageItemCatalog`를 거치지 않고, 팝오버 높이는
  실제 lane 수에서 계산)으로 다시 작성했습니다.

## 7. Developer ID provisioning profile: 범위 축소로 해소

### 확인된 사실

`OAuthCredentialVault`의 Data Protection Keychain 구현은 명시적인 app access
group을 요구합니다. Developer ID 배포에서 `keychain-access-groups`는
restricted entitlement라 embedded provisioning profile이 승인해야만 런타임에서
동작합니다. ClaudeUsage용 profile은 없었고, 실제 Developer ID 서명 probe로
다음을 확인했습니다.

1. profile 없음, Release entitlements만 사용, access group 생략:
   `errSecMissingEntitlement (-34018)`
2. profile 없음,
   `com.apple.security.application-groups =
   ["5YG4V2PLZV.com.seongmin.ClaudeUsage"]`,
   같은 값을 `kSecAttrAccessGroup`으로 사용:
   동일하게 `errSecMissingEntitlement (-34018)`

probe 조건: bundle identifier `com.seongmin.ClaudeUsage`, Team ID
`5YG4V2PLZV`, 유효한 Developer ID certificate chain, hardened runtime,
no embedded provisioning profile, no-UI.

`6fa5d5c`가 넣은 release 검증은 서명된 앱에
`keychain-access-groups[0] == 5YG4V2PLZV.com.seongmin.ClaudeUsage`를 요구했기
때문에, 그 상태로는 `./Scripts/release.sh stg 2.4.0`이 notarization 이전
단계에서 실패했습니다.

### 결정

계획 문서 `docs/antigravity-usage-rewrite-plan.md`에는 "Data Protection
Keychain", "access group", "entitlement", "provisioning"이 한 번도 나오지
않습니다. 계획이 요구하는 것은 "app-owned Keychain vault"와 "Keychain prompt
0회"뿐이고, 이미 출시된 파일 기반 Keychain이 두 조건을 모두 충족합니다.
Data Protection Keychain 강제는 `3a43ed7`/`48b443a`에서, release 측 강제
검증은 `6fa5d5c`에서 스스로 추가한 보안 강화였습니다.

따라서 profile을 발급하는 대신 그 강화를 되돌렸습니다 (`221c514`).

- vault의 storage domain 분기와 access group 배선을 제거하고 단일 구현으로
  정리. AGY와 Claude 자격은 별도 domain이 아니라 reference namespace
  (`oauth.antigravity.v2.` 등)로 분리합니다
- DP 실패를 설명하려고 만든 `credentialVaultEntitlement` runtime blocker와
  그 사용자 노출 문구를 제거했습니다
- release 검증에서 `application-identifier` / `team-identifier` /
  `keychain-access-groups` 강제 조건을 제거했습니다. 서명 팀 신뢰 경계는
  인증서 선택(`build-notarize-release.sh`)과 code signature 검증
  (`verify-release-artifact.sh`)이 그대로 담당하므로 약해지지 않습니다
- 대신 승인될 수 없는 restricted entitlement가 다시 들어오면 빌드와 원격
  artifact 검증이 **실패하도록** negative 검증을 넣고 회귀 테스트로
  고정했습니다

### 후속 과제로 분리

Data Protection Keychain 채택은 별도 과제입니다. 재개한다면 순서는
profile 발급이 먼저입니다.

- Apple Developer portal에서 App ID `com.seongmin.ClaudeUsage`에 Keychain
  Sharing capability를 추가하고 Developer ID provisioning profile 발급
- profile은 repository에 commit하지 않고, release driver가 이름 또는 명시적
  local path로 선택
- profile CMS signature, TeamIdentifier, application-identifier,
  keychain-access-groups exact allowlist, 만료 시각, 허용된 certificate와
  실제 signing certificate 일치, `Contents/embedded.provisionprofile`,
  embedded profile entitlement와 signed app entitlement 일치, 예상하지 않은
  추가 access group 부재를 모두 검증
- archive 성공만으로 승인하지 않고, 해당 signed artifact에서 Data Protection
  Keychain add → read-back → delete를 no-UI로 실제 검증

Apple 참고 문서:

- https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps
- https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain
- https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles

## 8. 현재 테스트 상태

- 전체 XCTest: 881 executed, 1 skipped, 0 failures (2.4.0 기준)
- release driver shell tests: 307 passed
- universal Release build: `x86_64 arm64` 확인
- `git diff --check`: 통과

테스트 수가 944에서 881로 줄어든 것은 legacy 경로와 함께 그 전용 테스트
파일을 삭제했기 때문입니다.

이전 인계 문서의 "release driver 308/308"은 오래된 수치였습니다. Stage 8
이전 HEAD에서도 302였고, negative entitlement 검증 3개와 tag 해석 회귀 2개를
더해 307입니다.

signed app QA는 아직 실행하지 않았습니다 (11절).

## 9. 다음 순서

1. `~/Downloads/ClaudeUsage.app` (v2.3.3-staging)에서 Sparkle 업데이트를
   실행해 11절의 signed QA 수행
2. 결함이 없으면 prod 배포를 검토. 결함이 있으면 2.4.0을 버리고 다음 숫자
   버전으로 진행
3. 후속 과제: Data Protection Keychain 채택 (7절)

전체 테스트:

```bash
xcodebuild test -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS'
```

release driver test:

```bash
bash Scripts/tests/release-driver-tests.sh
```

테스트 클래스를 골라 돌릴 때는 파일명이 아니라 **클래스명**으로 지정된다는
점에 주의합니다. `RefreshOrchestrationTests.swift`에는
`RefreshOrchestrationTests`와 `PopoverViewModelTests` 두 클래스가 있고,
이 차이 때문에 Stage 8에서 회귀를 놓쳤습니다.

## 10. Stage 9 범위

### 완료

- `173e40a` legacy 조회 경로 삭제. 구 refresher, refresh configuration, TUI
  quota parser와 CLI usage service, remote usage service/parsing, local IDE
  API service/parsing. `AntigravitySetupPolicy`는 두 호출부 모두 `.auto`
  고정이었으므로 `AntigravityEnvironmentSignals.requiresInteractiveSetup`으로
  인라인
- `7a390ba` legacy "model window" 서브시스템 삭제. legacy 메뉴바 overload와
  전용 helper, `ProviderMenuBarDisplayConfig`의 primary/secondary model ID,
  AppSettings의 AGY data-source / hidden model / menu bar model ID 필드와
  helper, 설정 화면의 모델 표시·숨김 섹션, `RuntimeProviderPayload`의
  `.antigravity` 케이스, 구 usage model. AGY catalog는 권위 ID
  `antigravityUsageLimits` 하나로 정리
- legacy 부활 방지 테스트 3건 추가:
  `testAntigravityUsageLimitsItemStaysStructuralAndLegacyIDsAreDropped`,
  `testResetToDefaultsDoesNotRecreateLegacyAntigravityKeys`,
  `testLegacyAntigravityPopoverItemsDoNotSurviveLoad`
- `97c12be` 당시 `docs/antigravity-usage-sources.md`를 schema v1 연결 정책
  (`sourcePolicy` / `allowManagedCLI` / `managedSession`)과 당시 테스트
  클래스 목록으로 갱신. 이 정책은 아래 §15의 schema v2 자동 조회 정책으로
  대체됨
- `docs/authentication-and-sources.md`는 이 문서를 가리키는 한 줄뿐이라
  갱신할 내용이 없고, `docs/PROJECT_WORKFLOW.md`와 `docs/RELEASE.md`에는
  AGY 언급이 없어 대상이 아니었습니다

### 완료: display/alert 이중 소유 제거

조사 결과 AGY 메뉴바와 알림 상태가 두 곳에 있었습니다.

```text
typed  : AntigravityDisplaySettings.menuBar / .notifications
         → 렌더와 NotificationManager가 실제로 읽는 값
generic: AppSettings의 provider별 UserDefaults 키
         → 쓸 수는 있으나 AGY에서는 아무도 읽지 않았고
           snapshot/restore가 계속 되살렸다
```

- `d0e3b95` `menuBarDisplayConfig(for: .antigravity)`를 nil로 만들고,
  display formatting setter 8개와 `applyMenuBarDisplayPreset`이 AGY를 받지
  않도록 차단. 경계는 `ownsGenericMenuBarDisplay` 한곳에 명시
- `5f5d936` `setProviderAlertEnabled`도 AGY 차단,
  `isProviderAlertEnabled(.antigravity)`는 false 반환

provider 활성화와 메뉴바 노출은 공용 설정이라 그대로 뒀습니다. 차단이 다른
provider까지 막지 않는지도 회귀 테스트로 고정했습니다.

검토 중 확인한 사실: `isProviderVisibleInMenuBar(.antigravity)`는 이제 항상
false지만, 프로덕션 소비처가 없습니다. 메뉴바 렌더와 서비스 선택 모두
`AppDelegate+StatusBar`의 typed 서술자를 주입해 씁니다.

## 11. Stage 10과 배포

### 자동 검증 완료

- 전체 XCTest: 881 executed, 0 failures (2.4.0 기준)
- universal Release unsigned build: `x86_64 arm64` 확인
- release driver shell tests: 305 passed
- automatic refresh가 AGY를 시작하지 않음:
  `AntigravityRefreshPolicyTests.testAutomaticPlanNeverLaunchesManagedCLI`
- managed CLI opt-in:
  `AntigravityRefreshPolicyTests.testManagedCLIRequiresExplicitLocalSessionOptIn`
- strict review: 이 과정에서 alert 이중 소유를 발견해 `5f5d936`으로 해소
- notary keychain profile `ClaudeUsageNotary`: 정상 응답
- `git diff --check`: 통과

### signed QA는 staging 산출본에서

unsigned 빌드로는 QA하지 않습니다. prod와 code signature가 달라 실제
자격증명에 Keychain prompt가 뜨고, "항상 허용"을 누르면 prod 앱의 ACL이
오염됩니다.

사용자 결정에 따라 로컬 서명 QA를 건너뛰고 staging 산출본에서 QA합니다.
staging tag는 immutable이므로, QA에서 결함이 나오면 2.4.0을 버리고 다음 번호로
갑니다.

staging 산출본에서 확인할 항목:

- 기존 prod → 새 signed app upgrade migration
- Keychain prompt 0회
- account A↔B 10회 전환
- managed AGY idle teardown
- standard/compact/menu bar/settings/notification 실제 화면

### 게시 완료: v2.4.0-staging

- tag: `v2.4.0-staging` (annotated `c70bff6`) → `3fa8563` = `main`
- Release: pre-release, 3-asset (`appcast.xml`, `ClaudeUsage.dmg`, `ClaudeUsage.zip`)
- 공증: ZIP·DMG 모두 Accepted, staple validate 성공,
  Gatekeeper `accepted / source=Notarized Developer ID`
- 원격 재다운로드 검증 통과. app 2.4.0 (20400)
  - DMG SHA-256 `4d34ee103755be8b837c917f5e21031cbce375546db0ede0dbe9cc794fa84b29`
  - ZIP SHA-256 `ac5cf91d7dea6e3f69a3ff0df63b0d08895eae3ffdb24bb745a6c45d2342fe92`
  - appcast SHA-256 `6ddd63c9f642ccfbdcc5940f72b2ce1cd02e49d25eb2b078dfe489b10e5c0eb2`
- 공개 Pages 피드가 2.4.0 / 20400과 edSignature를 서빙
- gh CLI 계정은 `nathan-glorang`으로 복원됨

서명 인증서는 `A4F7A686CAD1108C148DA7C53E707F308304480F`를 명시했습니다. 같은
팀에 Developer ID 인증서가 두 개 있어 자동 선택이 모호하고, 배포 중인 v2.3.3이
쓴 인증서와 같아야 Keychain ACL 연속성이 유지되기 때문입니다. 다음 배포에서도
`CERT_HASH`로 이 값을 넘깁니다.

### staging QA 결과 (v2.4.0-staging 기준)

통과:

- **upgrade migration**: `accounts.json`은 metadata만 담고 secret은 vault에만
  있음. `credentialReference`가 `oauth.antigravity.v2.<uuid>` 형식이고
  `migrationAliases`에 legacy 계정 키가 남아 이전 경로가 확인됨. legacy JSON
  3종과 legacy Keychain 2 service 모두 제거됨. durable version 2 마커 존재
- **Keychain prompt 0회**: 실행 중 `SecurityAgent` 없음
- **automatic refresh가 AGY를 시작하지 않음**: AGY/language_server 프로세스
  없음, ClaudeUsage 자식 프로세스 없음, managed launch lock 비어 있음

검증 불가:

- **account A↔B 10회 전환**: 계정이 1개뿐이라 전환 자체가 성립하지 않음

결함 발견 → v2.4.1에서 수정:

- **Google 계정 연결이 항상 실패**. 토큰 교환이 일회용 authorization code를
  secret 없는 첫 시도로 소진했다. 자세한 경위는 커밋 메시지 참조
- 실패 사유가 UI에서 버려지고 로그인 경로에 로깅이 없어 진단 자체가 불가능했다
- `language_server` client discovery가 로그인마다 14.6초 (→ 0.41초)

**교훈**: AGY 2.4.2는 앱을 `app.asar`로 패키징하므로 코드가 찾는
`Contents/Resources/app/out/main.js`는 존재하지 않는다. OAuth client는
`bin/language_server` 바이너리에서만 나오고, 그 안에서 clientID와 secret은
460KB 떨어져 있다. 이 경로는 배포 전에 로컬 빌드로 반드시 확인해야 한다.
opt-in 통합 테스트로 고정해 뒀다
(`CLAUDEUSAGE_RUN_AGY_INTEGRATION=1`, `TEST_RUNNER_` 접두사로 전달).

### 게시 완료: v2.4.1-staging

- tag `v2.4.1-staging` → `401d77a` = `main`
- Release: pre-release, 3-asset. 공증 ZIP·DMG Accepted, staple·Gatekeeper 통과
- 공개 피드 2.4.1 / 20401 + edSignature
- DMG SHA-256 `861105b9d209795f2ec7e58bdb5b9639009500737dcd7dabc17a6af3761fcf53`
- **인증서 자동 선택 동작 확인**: `CERT_HASH` 없이 실행해 배치된 v2.4.0-staging
  앱 기준으로 `A4F7A686…`을 스스로 선택

### 남은 QA

`~/Downloads/ClaudeUsage.app`(v2.4.0-staging)에서 Sparkle 업데이트를 실행한 뒤:

- Google 계정 연결 성공 여부 (실패해도 이제 사유가 화면에 표시됨)
- quota 수치가 실제로 표시되는지 (`계정만 확인됨`에서 벗어나는지)
- standard / compact / menu bar / settings / notification 화면
- managed AGY opt-in과 idle teardown

### 배포 순서### 배포 순서

1. reviewed `dev`를 `main`에 squash merge
2. staged main tree와 reviewed dev tree 동일성 검증
3. `main` push
4. `dev`를 squash된 main history로 realign
5. `./Scripts/release.sh stg 2.4.0`
6. 원격 GitHub Release DMG를 다시 다운로드
7. checksum, staple, Gatekeeper, appcast, Pages propagation 검증
8. 필요 시 verified remote DMG에서 mounted app만 Downloads에 배치

gh CLI 계정은 배포 중에만 `ChoSeongmin1128`로 바꾸고, 끝나면 즉시
`nathan-glorang`으로 복구합니다.

staging 검증 전 prod 배포를 진행하지 않습니다.


## 11. 메뉴바 상태 아이템 미배치 (macOS 26 재발 가능, 2026-07-30 갱신)

### 결론

macOS 26 Tahoe에서 서드파티 상태 아이템은 ControlCenter가 replicant로 호스팅하며,
앱별 표시 상태를 TCC 보호 저장소에 유지한다:

```
~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist
```

`trackedApplications`(Swift Codable dict가 [key, value, ...] 교차 배열로 직렬화된
bplist blob)에서 ClaudeUsage 자체는 `isAllowed: true`였지만, **다른 앱 항목의
`menuItemLocations`에 ClaudeUsage 식별자가 교차 오염**돼 있었다. 2026-07-30
재현 직후의 정확한 쌍은 다음과 같다.

- `com.openai.codex` (`isAllowed: false`) 항목에
  `com.seongmin.ClaudeUsage.staging`
- `com.anthropic.claude-code` 항목에 `com.seongmin.ClaudeUsage`

CC가 ClaudeUsage 아이템을 차단된 앱 소속으로 오인해 등록 15ms 만에
`Moving host to blocked list`로 격리했다 (`log` category `appStatusItems`).
2026-07-30 재현 시간축으로 오염 경위를 바로잡았다. 14:22~15:28의 staging
실행은 정상 displayable로 유지됐지만, Codex가 `/Applications/ClaudeUsage-stg.app`
을 진단 실행한 15:32:49(PID 49973)에 처음 `Moving host to blocked list`가
발생했다. 그 직후 staging 식별자가 `com.openai.codex`의
`menuItemLocations`에 기록됐다. 따라서 현재 증거상 직접 재현 조건은
**ClaudeUsage가 CLI 자식을 실행한 것**이 아니라 **다른 GUI 자동화 호스트가
ClaudeUsage 앱 자체를 실행한 것**이다. Tahoe ControlCenter가 launch attribution을
잘못 영구 저장하는 OS 결함으로 판단한다.

### 해결 절차 (재발 시 그대로)

1. 먼저 앱 프로세스, ControlCenter 로그, `trackedApplications`를 읽기 전용으로
   대조한다. 로그만으로 저장소 손상을 추정하지 않는다.
2. 보호 plist 수정이 꼭 필요하면 사용자가 승인한 로컬 Terminal 등 정확히 권한이
   있는 프로세스에서 원본 해시와 백업을 남기고, ClaudeUsage 쌍과 타 앱의
   ClaudeUsage 참조만 제거한다. 앱이나 자동화 도구가 FDA를 요구하거나 plist를
   직접 고치게 만들지 않는다.
3. cfprefsd가 오래된 값을 되쓰지 않도록 검증된 정리 절차로 ControlCenter와
   preferences cache를 재기동하고, 백업에서 다른 앱 쌍이 보존됐는지 확인한다.
4. 사용자가 Applications의 앱을 직접 실행한 뒤 `Adding displayable items`가
   있고 `Moving host to blocked list`가 없으며 실제 메뉴바에 보이는지 확인한다.

### 진단에서 확정한 사실 (증거)

- 설정 > 메뉴 막대의 앱 토글은 이 차단 상태와 **동기화되지 않는다** (토글 ON인데
  차단 유지; OFF→ON, 라이브 토글, CC 재시작 조합 전부 무효)
- 차단 키는 bundle ID 단독 (autosaveName 변경 우회 무효, bundle ID 변경 시 정상)
- `com.apple.controlcenter` 도메인의 `NSStatusItem Visible Item-N` 키는 무관
- AX/CGWindow 좌표 하나만으로는 판정하지 않는다. 앱 표시 의도,
  `NSStatusItem.isVisible`, button/window/screen 상태, ControlCenter proxy
  geometry를 함께 본다. 창 서버 좌표 비교에는 `CGDisplayBounds`를 쓴다.
- 앱 창은 Tahoe에서 항상 오프스크린 파킹({{0,-6}} 또는 우상단, h=22)이며
  CC replicant가 실제 표시를 담당하므로 창 프레임 단독 판정은 금지한다.

### 앱 코드 방어 (2.4.6 staging 후보)

- status item에 채널별 안정적 autosave name을 부여
  (`claudeusage`, `claudeusage-staging`)
- 앱의 표시 의도, `NSStatusItem VisibleCC`, button/window/screen,
  ControlCenter proxy geometry를 함께 판정해 정상 menu bar manager 이동과
  Tahoe 차단을 구분
- 사용자가 시스템 설정에서 의도적으로 숨긴 항목과 살아 있는 window/proxy는
  복구 대상에서 제외하며, Tahoe 전용 증거는 macOS 26 미만에서 사용하지 않음
- 시작 2초 후 차단이면 status item을 최대 한 번만 재생성하고 750ms 뒤 재검증.
  반복 재생성은 ControlCenter를 더 손상시킬 수 있어 금지
- 계속 차단되면 알림 권한에 의존하지 않는 modal 안내를 하루 한 번 표시
- 이미 실행 중인 앱을 Finder에서 다시 열면 정상 상태는 popover, 차단 상태는
  복구 안내를 표시
- 앱은 보호된 ControlCenter plist를 수정하거나 Full Disk Access를 요구하지 않음

## 12. 진단 중 발견한 별개 결함 (2026-07-28 판정 확정)

진단 당시 4건을 기록했으나, 잔존 샌드박스 컨테이너
(`~/Library/Containers/com.seongmin.ClaudeUsage`, 7/7 실험 빌드가 생성)가
defaults CLI를 컨테이너로 리다이렉트해 **CLI 쓰기가 앱에 도달하지 않는
split-brain** 상태였음이 확인됐다. 이 오염을 걷어낸 최종 판정:

1. **[반증] updateMenuBar가 providerStates를 반영하지 않는다** — 렌더러는
   앱이 실제로 읽는 outer plist 값을 정확히 반영했다. CLI 쓰기(컨테이너행)가
   앱(outer)에 안 보였을 뿐. updateMenuBar에 결정 로그를 추가해 재발 시
   즉시 판별 가능하게 했다.
2. **[반증] 활성 provider는 메뉴바에서 숨길 수 없다** — 숨김은 허용되며 모두
   숨기면 placeholder(⋯)가 남는다. 되살림(`applyMinimalVisiblePresetIfNeeded`)은
   메뉴바 표시를 한 번도 만지지 않은 provider를 새로 켤 때의 onboarding
   기본값뿐이고, Claude는 `hasExplicitMenuBarCustomization`이 항상 true라
   대상조차 아니다.
3. **[수정] providerStates ↔ legacy 미러 불일치** — didSet에서
   claudeEnabled/codexEnabled를 함께 기록하도록 수정. AppSettings init을
   `init(defaults:)`로 주입 가능하게 바꿔 회귀 테스트 추가
   (`testProviderStatesChangeKeepsLegacyMirrorsInSync`).
4. **[수정] 팝오버 Claude 미인증 화면 푸터 겹침** — rich 패널(아이콘+2줄
   안내+버튼 2개)이 일반 status panel 뷰포트(88pt)에 강제돼 본문이 넘쳤다.
   `standardRichAuthPanelHeight`(192pt)와 `richAuthPanel` 플래그를 추가하고
   88pt를 고정하던 기존 테스트를 바로잡았다.

기존 20s+10s `occlusionState` + 사용자 알림 방어는 §11의 2.4.6 방어로
교체했다. `occlusionState` 단독 판정은 전체 화면/자동 숨김에서 오탐 가능하고,
알림 권한이 없으면 사용자가 아무 안내도 받지 못했기 때문이다.

### 잔존 컨테이너 정리 (사용자 액션 필요)

컨테이너는 TCC 보호라 에이전트 권한으로 삭제 불가. 터미널에서:

```
rm -rf ~/Library/Containers/com.seongmin.ClaudeUsage
```

지우지 않으면 이후 `defaults` CLI 진단이 계속 어긋난 값을 읽는다(앱 동작에는
영향 없음 — 앱은 outer plist를 사용).


## 13. v2.4.2-staging 게시 기록 (2026-07-28)

- tag `v2.4.2-staging`, 2.4.2 (20402), source `acee2f1`
- 게시 전 검증: 전체 XCTest 886 중 885 통과/1 스킵(옵트인 AGY 통합), release
  driver 312 통과, 로컬 빌드 QA(메뉴바 표시, watchdog 정상 상태 오탐 없음)
- 드라이버 원격 검증: ZIP/DMG notarized accepted + staple + Gatekeeper,
  Sparkle Ed25519, appcast 게시 확인
  - DMG SHA-256 `bd0ab2c6440fcb9d95d6594a33f833cc557194f7ad28113423debd68e40c4481`
  - ZIP SHA-256 `3d10276fc71ece311626a4feaa0cc3b08717710a21beb33587a1728ba48e20a4`
- 공개 피드 응답 확인: shortVersionString 2.4.2 / sparkle:version 20402
- dev는 main(acee2f1)으로 realign 완료, gh 계정 nathan-glorang 복원 확인
- `~/Downloads/ClaudeUsage.app`은 v2.4.1-staging 그대로 유지 —
  Sparkle upgrade QA(2.4.1 -> 2.4.2)에 사용 가능

## 14. Data Protection Keychain 재개 (진행 중)

사용자 지시로 §7 보류를 철회했다(2026-07-28). 1단계 = portal에서 App ID
`com.seongmin.ClaudeUsage`에 Keychain Sharing capability 추가 + 릴리스 서명
leaf(`A4F7A686CAD1108C148DA7C53E707F308304480F`)와 일치하는 Developer ID
provisioning profile 발급. 1단계 완료(2026-07-28):

- App ID `com.seongmin.ClaudeUsage`(explicit, 5YG4V2PLZV) 등록. 현재 포털에는
  "Keychain Sharing" capability 항목이 존재하지 않으며(128개 전수 확인),
  keychain-access-groups는 프로파일에 기본 부여되는 방식으로 바뀌었다
- Developer ID 프로파일 "ClaudeUsage Developer ID" 발급, `security cms -D`
  실측: TeamIdentifier 5YG4V2PLZV, application-identifier
  5YG4V2PLZV.com.seongmin.ClaudeUsage, keychain-access-groups
  ['5YG4V2PLZV.*'], 포함 인증서 = 릴리스 서명 leaf(A4F7A686...0480F) 정확히
  1개, ProvisionsAllDevices true, ExpirationDate 2044-07-23
- 보관: `~/Documents/인증서와 키/ClaudeUsage/ClaudeUsage_Developer_ID.provisionprofile`
  (repo 커밋 금지). 같은 폴더 `현황.md`에 인증서/프로파일 실사 기록
- 함께 정리: MinNote App ID(com.seongmin.minnote)와 프로파일 2개를 포털에서
  삭제(사용자 지시)

남은 것(다음 사이클): vault를 Data Protection Keychain으로 복원, Xcode
embedded profile 배선, release driver의 §7 검증 목록(embedded profile CMS,
entitlement 일치, no-UI add -> read-back -> delete 실증) 구현.

## 15. AGY 자동 조회 UX 전환 (2026-07-29)

사용자 결정:

- 설정의 `자동/로컬 세션/Google 계정` 조회 방식 선택은 완전히 제거
- 조회 계정 미선택은 ambient local account를 의미
- 공식 AGY CLI가 검증되면 별도 opt-in 없이 자동 source로 허용
- AGY release digest allowlist 대신 Google Developer ID 서명 경계를 사용
- IDE extension 전용 source는 이번 릴리스에서 추가하지 않음

현재 구현:

- source 순서:
  - ambient: local app → borrowed AGY → managed AGY
  - 선택 Google 계정: local app → borrowed AGY → managed AGY → OAuth
- 선택 계정과 local/AGY identity가 다르면 해당 수치를 거부하고 다음 source로
  진행하는 기존 account guard를 유지
- `AntigravityConnectionSettings` schema v2에서 `sourcePolicy`,
  `allowManagedCLI`를 제거하고 `managedSession.idleTimeoutSeconds`만 보존
- schema v1과 더 오래된 `antigravityUsageDataSource` migration은 source
  선택 의미를 버리고 v2 자동 정책으로 전환하되 idle timeout을 보존
- CLI 후보는 `ANTIGRAVITY_CLI_PATH`, `~/.local/bin/agy`,
  `/opt/homebrew/bin/agy`, `/usr/local/bin/agy`, 절대 `PATH` 순서
- AGY trust는 signing identifier `cli`, Team ID `EQHXZ8M8AV`, Apple generic
  Developer ID designated requirement를 정적·실행 직전·실행 중에 검증
- catalog가 캡처한 vnode/file identity도 유지해 같은 경로 교체를 거부
- 설정 고급 진단은 검증된 정확한 경로, 미감지, Google 서명 거부,
  managed recovery 실패를 구분

검증 상태:

- Debug universal app build 성공
- unsigned universal Release build 성공
- 전체 XCTest 890개 실행, 889 통과/1 스킵/0 실패
- release driver 테스트 312개 통과
- 설치된 공식 AGY 1.1.7을 production resolver가 승인하고 실제 managed
  launcher로 시작·suspend·자기 process tree 종료하는 통합 테스트 통과
- 새 회귀 검증: 임의 새 digest + 공식 서명 허용, 잘못된 서명 거부, 실행 직전
  file identity 교체 거부, 실행 중 dynamic designated requirement, CLI 후보
  우선순위, v1 → v2 timeout 보존

남은 릴리스 절차:

- 구현은 `b04761a`로 main/dev/origin 양쪽에 반영·정렬 완료
- `v2.4.3-staging` 게시 시도는 release driver의 첫 mutation 전
  `ClaudeUsageNotary` Keychain profile 부재로 중단됨
  - tag/Release/Pages/Downloads는 변경되지 않음
  - GitHub CLI는 `nathan-glorang`으로 복원됨
  - Documents의 Developer ID p12, ClaudeUsage provisioning profile,
    Sparkle 키, `AuthKey_6MM7PM2P55.p8`은 존재하며 기록된 무결성 값과 일치
  - 셸 기록상 기존 `ClaudeUsageNotary`는 P8이 아니라 Apple ID + Team ID
    `5YG4V2PLZV`로 생성됐음. 복구에는 새 app-specific password 입력이 필요
  - P8은 별도 공증 자격으로 재사용할 수 있지만 Team API Key의 issuer UUID가
    로컬에는 보관돼 있지 않아 현재 즉시 대체할 수 없음
- Apple ID 방식으로 `ClaudeUsageNotary`를 다시 저장하거나 P8 issuer를
  확보한 뒤 release driver를 그대로 재실행. 배포 대상은 Mac App Store가
  아니라 Developer ID 공증을 거친 GitHub staging Release/appcast임
- 게시된 서명 후보에서 설정 UI와 실제 자동 조회를 확인한 뒤 이 절에 최종
  릴리스 결과를 기록
