# ClaudeUsage AGY v2 작업 인계

- 갱신일: 2026-07-27
- 저장소: `/Users/seongmin/Personal/maintenance/ClaudeUsage`
- 원격: `git@github-seongmin:ChoSeongmin1128/claude-usage.git`
- 브랜치: `dev`
- 상태: Stage 8~9 완료. `v2.4.0-staging` 게시·원격 검증 완료. signed QA만 남음

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
- `97c12be` `docs/antigravity-usage-sources.md`를 v2 연결 정책
  (`sourcePolicy` / `allowManagedCLI` / `managedSession`)과 현재 테스트
  클래스 목록으로 갱신. 삭제한 타입 참조도 현재 타입으로 교체
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

### 남은 signed QA

`~/Downloads/ClaudeUsage.app`은 이전 동일 채널 앱(v2.3.3-staging)으로
유지돼 있습니다. **그 앱에서 Sparkle 업데이트를 실행해** 실제 upgrade 경로를
확인합니다.

- 기존 prod → 새 signed app upgrade migration
- Keychain prompt 0회
- account A↔B 10회 전환
- managed AGY opt-in과 idle teardown
- standard / compact / menu bar / settings / notification 실제 화면

QA에서 결함이 나오면 tag는 immutable이므로 2.4.0을 버리고 다음 숫자 버전으로
갑니다. staging 검증 전 prod 배포를 진행하지 않습니다.

### 배포 순서

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
