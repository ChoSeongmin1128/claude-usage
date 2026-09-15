# 배포와 업데이트 복구

## 배포 계약

공식 배포는 통합 driver를 사용합니다.

```bash
./Scripts/release.sh stg X.Y.Z --notes-file docs/release-notes/X.Y.Z.md
```

환경은 `stg`/`staging` 또는 `prod`이며, 버전은 `X.Y.Z` 형식입니다. staging은 별도 브랜치가 아닙니다. 운영 승격은 staging 검증과 별도의 배포 결정이 필요합니다.

운영 승격은 같은 버전의 staging 태그와 현재 main의 커밋이 정확히 같아야 합니다. 승격 예정 후보의 노트는 두 채널에서 사용할 수 있도록 작성하고, staging 게시 뒤에는 운영 게시가 끝날 때까지 완료 문서 커밋도 추가하지 않습니다. main이 이미 진행됐다면 기존 태그를 변경하지 않고 다음 patch 후보를 검증합니다.

| 채널 | 태그 | 앱 | bundle identifier | feed |
|---|---|---|---|---|
| staging | `vX.Y.Z-staging` | `ClaudeUsage-stg.app` | `com.seongmin.ClaudeUsage.staging` | [staging appcast](https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml) |
| prod | `vX.Y.Z` | `ClaudeUsage.app` | `com.seongmin.ClaudeUsage` | [prod appcast](https://choseongmin1128.github.io/claude-usage/appcast.xml) |

산출물은 `ClaudeUsage.zip`, `ClaudeUsage.dmg`, `appcast.xml` 세 개입니다. 태그와 Release를 게시한 뒤에는 자산을 덮어쓰거나 태그를 이동하지 않습니다. 문제가 남으면 다음 버전 후보를 만듭니다.

버전은 변경 범위에 맞춰 선택하고 프로젝트의 모든 version/build 값과 노트 파일을 함께 갱신합니다. build number는 `major * 10000 + minor * 100 + patch`이며 minor와 patch는 0~99입니다. 예: `2.5.0 → 20500`. 과거 2.3.x의 다른 build 규칙은 이전 자산 검증에만 사용합니다.

## 사전 준비

- 검증된 dev 내용을 squash한 clean main과 원격 main이 일치해야 합니다.
- GitHub 게시 권한과 원격 저장소를 확인합니다. driver의 `REPOSITORY`, `RELEASE_GH_ACCOUNT`, `RESTORE_GH_ACCOUNT`, `EXPECTED_ORIGIN_URL`은 공식 배포 정책입니다. 포크의 배포에는 이를 포함한 저장소·계정·서명·채널 설정을 별도로 검토해야 합니다.
- Xcode 초기 설정과 약관 동의를 완료하고 Developer ID Application 인증서를 준비합니다.
- Keychain에 `ClaudeUsageNotary` 공증 프로파일을 등록합니다. 자격증명과 개인키는 공개 문서나 Git에 넣지 않습니다.
- Sparkle 개인키는 Keychain에, 공개키는 `Config/Release.xcconfig`에 보관합니다. 로컬 feed/profile 설정은 추적하지 않는 `Config/Sparkle.release.local.xcconfig`를 사용합니다.
- ShellCheck 0.11.0과 Xcode 내장 swift-format이 필요합니다.
- 공식 AGY CLI가 설치되고 로그인되어 있어야 필수 live gate를 실행할 수 있습니다.

```bash
gh auth status
gh repo view --json nameWithOwner -q .nameWithOwner
git remote -v

# 공증 자격 등록은 대화형으로 수행
xcrun notarytool store-credentials ClaudeUsageNotary

# 최초 Sparkle 설정
./Scripts/setup-sparkle-keys.sh
```

인증서가 여러 개면 임의의 첫 항목을 사용하지 않습니다. 현재 정상 설치본의 서명 인증서와 Keychain의 유효한 인증서를 대조한 후 SHA-1을 명시합니다.

```bash
CERT_HASH="VERIFIED_CERTIFICATE_SHA1" \
  ./Scripts/release.sh stg X.Y.Z --notes-file docs/release-notes/X.Y.Z.md
```

`setup-sparkle-keys.sh --force`는 로컬 설정을 다시 쓰는 옵션이며 기존 signing key를 회전하는 절차가 아닙니다.

## dev 검증과 main 확정

[개발 절차](PROJECT_WORKFLOW.md)에 따라 작업 단위를 커밋·push하고 전체 XCTest, Release 빌드, 실앱 QA, 코드 리뷰를 완료합니다. 계정 경계·취소·프로세스 소유권·변경된 파일 검증을 중점적으로 확인합니다.

squash 직후 커밋 전에 `git write-tree`와 검증한 `dev^{tree}`가 정확히 같아야 합니다. 중복 이력 때문에 충돌이 생기면 임의로 코드를 혼합하지 말고 검증한 dev tree를 기준으로 정합성을 확인합니다. 다음 작업 전에는 dev를 새 main 이력에 정렬합니다.

게시할 버전의 노트·라이선스·외부 구성 요소 고지도 이 커밋에 포함합니다. 검증용 dev 산출물을 게시 산출물로 재사용하지 않습니다.

dev 빌드도 완성된 앱의 Info.plist에서 채널·feed·공개키를 확인합니다. `-xcconfig`는 명령행 build setting보다 우선하므로 feed 값을 명령행으로만 덮어쓰지 않습니다. 통합 빌드는 로컬 설정을 포함한 뒤 채널 값을 명시하는 임시 xcconfig를 생성합니다.

## 릴리스 노트와 고지

`docs/release-notes/X.Y.Z.md`가 노트 정본입니다. 첫 줄은 `# X.Y.Z`이고, 사용자에게 달라지는 변경과 알려진 제한을 작성합니다. UTF-8, LF, 마지막 줄바꿈을 사용합니다.

driver는 파일 경로·내용·버전을 확인하고 배포 커밋의 파일과 같은지 검사합니다. GitHub에는 원본을 `--notes-file`로 전달하고 Sparkle에는 같은 내용을 `description sparkle:format="plain-text"`로 내장합니다. 이 형식은 기존 Sparkle 2.8.1 설치본과도 호환됩니다.

예약 업데이트의 기본 Sparkle 알림창은 숨기므로 설정 → 업데이트의 버전별 변경 사항에서도 노트를 표시합니다. 서명 복구 시 Sparkle이 제거한 노트를 외부 URL에서 다시 가져오지 않습니다.

`LICENSE`와 `THIRD_PARTY_NOTICES.md`는 소스 저장소의 정본이며 Xcode가 앱 리소스에 복사합니다. 원본 소스의 MIT 조건과 외부 구성 요소·브랜드 자산의 권리 범위를 구분합니다.

## 통합 driver 실행

```bash
# 원격 상태와 계획만 확인
./Scripts/release.sh stg X.Y.Z --non-interactive --dry-run

# 명시적인 자동화 게시
./Scripts/release.sh stg X.Y.Z \
  --notes-file docs/release-notes/X.Y.Z.md \
  --non-interactive --confirm-publish vX.Y.Z-staging
```

실행 순서:

1. 저장소·계정·버전·clean main·기존 태그 상태와 공증 자격 확인
2. 변경 코드 정적 검사, 배포 스크립트 테스트, 전체 XCTest
3. 실제 AGY의 인증된 identity·숫자 quota, 격리한 공식 실행 파일 교체 복구, OAuth 없는 조회 대상 저장·현재 로그인·세션 재사용 검증
4. 이전 동일 채널의 원격 자산 검증과 서명 기준 앱 준비
5. 최종 main에서 archive, 서명, ZIP·DMG 공증, staple·Gatekeeper 검증
6. appcast 생성, 노트·ZIP 해시 반영, 최종 feed 서명
7. 불변 태그와 세 자산의 Release 생성
8. 원격 자산을 다시 내려받아 검증한 뒤 정확한 appcast 바이트만 Pages에 게시
9. 해당 Pages 커밋의 상태 `built`와 공개 feed 전파 확인, 최종 원격 검증

공식 AGY의 live gate는 skip이나 포트 개방, HTTP 200만으로 통과하지 않습니다. 사용자의 실제 AGY 설치 파일을 교체하지 않고 격리 복사본으로 업데이트를 재현합니다.

driver는 임시 빌드·다운로드·마운트·worktree를 정리하고 설정된 복귀 계정으로 GitHub CLI를 복원합니다. 이전 앱을 Downloads에 준비하는 것은 검증용이며, 설치 앱을 자동으로 실행하지 않습니다.

## 원격 검증

```bash
./Scripts/verify-release-artifact.sh \
  --tag vX.Y.Z-staging --channel staging \
  --expected-version X.Y.Z --expected-build BUILD_NUMBER \
  --verify-public-feed
```

검증 기준:

- GitHub 자산의 크기와 SHA-256
- feed와 업데이트 DMG의 Ed25519 서명
- 서명된 feed의 ZIP SHA-256을 압축 해제 전에 대조
- ZIP·DMG 양쪽 앱의 bundle identifier, 버전/build, 채널 feed, 공개키
- 앱과 DMG의 공증·staple·Gatekeeper 결과
- Git 태그의 노트 정본, GitHub 본문과 appcast 노트의 동일성
- 배포 앱에 포함된 라이선스·외부 구성 요소 고지
- Release appcast와 공개 feed의 바이트 동일성

`codesign`, `stapler`, `spctl`은 macOS 보안 서비스에 접근할 수 있는 환경에서 실행합니다. 제한된 샌드박스의 접근 거부를 서명 손상으로 단정하지 않습니다.

## 실앱 업그레이드와 메뉴바

설치본은 Finder에서 직접 실행합니다. Codex·Terminal 등 자동화 호스트의 실행 파일 호출이나 `open` 명령으로 시작하지 않습니다. macOS ControlCenter가 메뉴바 항목을 실행한 호스트에 잘못 연결할 수 있기 때문입니다.

QA 중에는 한 채널만 실행하고 다음을 확인합니다.

- `/Applications`의 의도한 앱에서 해당 채널 프로세스가 하나만 실행됨
- 메뉴바 아이콘과 팝오버가 정상 표시됨
- ControlCenter의 해당 PID에 `Adding displayable items`가 있고 `Moving host to blocked list`가 없음
- 계정 선택·새로고침 후 실제 계정과 quota가 일치하고 이전 계정 값이 섞이지 않음
- idle·반복 새로고침·화면 테마 변경에서 CPU 및 메뉴바 렌더 회귀가 없음
- 설치 후보의 버전별 노트가 정본과 일치함
- 이전 설치본 → 새 후보의 실제 Sparkle 업데이트가 성공함
- 서명된 feed를 요구하는 설치본 → 다음 후보의 업데이트도 성공함

원격 DMG에서 검증한 앱만 설치에 사용하고, 검증 창·마운트·임시 산출물을 마무리합니다. 사용자의 다른 앱 설정이나 보호 저장소를 일반 정리 대상으로 취급하지 않습니다.

## 서명된 feed와 키 복구

업데이트 payload는 Developer ID로 서명·공증한 DMG입니다. ZIP은 별도 다운로드용이며 SHA-256이 서명된 feed에 포함됩니다. 순서는 **XML 생성 → 노트 내장 → ZIP 해시 반영 → 최종 서명 → 검증 → 게시**입니다. 서명 뒤 XML을 다시 저장하면 안 됩니다.

앱은 `SURequireSignedFeed`와 `SUVerifyUpdateBeforeExtraction`을 활성화합니다. feed 서명 실패 유예는 1,728,000초(20일)입니다. 유예 중에는 거부하고, 유예 이후에는 신뢰하지 못하는 노트·안내 링크를 제거한 복구 경로를 허용합니다. 업데이트 아카이브의 검증은 유지합니다.

실제 Sparkle 프레임워크의 headless fixture는 정상 feed, 변조, 다른 키, 유예 이후 노트 제거를 검증합니다. 운영 키나 시스템 시계를 바꾸지 않습니다.

EdDSA 키를 교체할 때는 기존 설치본의 신뢰 경로를 보존해야 합니다. 압축 해제 전 검증을 사용하는 경우 기존 Apple 인증서로 서명된 DMG가 복구 경로입니다. EdDSA 키와 Apple 인증서를 동시에 변경하지 않습니다.

```bash
./Scripts/release.sh stg X.Y.Z \
  --previous-public-key "TRUSTED_PREVIOUS_PUBLIC_KEY" \
  --notes-file docs/release-notes/X.Y.Z.md
```

이전 공개키는 이전 자산 검증에만 사용하며 새 후보는 현재 추적한 공개키로 검증합니다. driver는 이전 앱과 후보의 Apple leaf 인증서 일치를 확인합니다. 독립 verifier의 `--trusted-public-key`도 신뢰한 기존 기준으로만 사용해야 합니다. 두 신뢰 수단을 모두 잃은 경우에는 검증된 DMG의 수동 설치 절차가 필요합니다.

## 게시 중단과 복구

| 상태 | 처리 |
|---|---|
| 태그와 Release 없음 | 전체 검증·빌드·게시 |
| 현재 main을 가리키는 태그만 있음 | 같은 태그로 전체 검증 후 Release 생성 |
| 세 자산이 완전하고 feed만 이전 상태 | 자산 재검증 후 Pages만 복구 |
| 태그·자산·feed가 모두 일치 | 원격 재검증 |
| 태그 불일치·불완전한 자산·분기 | 기존 후보를 보존하고 다음 버전 사용 |

일시적인 네트워크 실패와 실제 자산 결함을 구분하되, 검증 실패를 이유로 기존 자산을 덮어쓰지 않습니다. Pages push 성공만으로 공개 완료를 선언하지 않습니다. 공통 XML 파서는 구버전 ZIP과 현재 DMG의 채널·태그·버전을 함께 확인합니다.

## 구버전 호환

- 직전 버전 검증만으로 모든 과거 버전의 직접 업데이트를 보증하지 않습니다. [업데이트 호환 안내](upgrade-compatibility.md)의 앱 식별자·feed·Sparkle·저장 형식 경계를 확인합니다.
- 2.4.0 이전의 build number는 해당 릴리스의 메타데이터를 따릅니다.
- 2.4.4 이전 staging은 현재와 bundle identifier가 달라 동일 앱 업그레이드 기준으로 사용할 수 없습니다.
- 2.4.15 이전 자산은 ZIP enclosure와 기존 서명 검증을 유지합니다.
- 2.4.15부터는 DMG enclosure, 서명된 feed와 버전별 노트 정본을 검증합니다.

현재 배포 상태의 정본은 [GitHub Releases](https://github.com/ChoSeongmin1128/claude-usage/releases)와 각 공개 채널 feed입니다.
