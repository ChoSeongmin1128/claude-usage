# Homebrew 배포 설계

## 상태

이 문서는 Homebrew Cask 도입 전 설계 계약입니다. 현재 ClaudeUsage의 공식 설치 경로는 GitHub Release의 운영 DMG이며, 아직 공개 tap이나 설치 가능한 Cask는 없습니다. 구현·검증·게시를 마치기 전에는 README에 Homebrew 설치 명령을 제공하지 않습니다.

목표는 다음 두 업데이트 경로를 함께 지원하는 것입니다.

- `brew install --cask choseongmin1128/tap/claude-usage`로 운영 앱 설치
- 일반 `brew upgrade` 또는 Cask를 지정한 업그레이드로 운영 앱 갱신
- Homebrew로 설치한 앱에서도 기존 Sparkle 자동 확인·다운로드·사용자 선택 설치 유지

Homebrew는 설치와 제거를 관리하고 Sparkle은 앱 안에서 업데이트를 제공할 수 있습니다. 둘 중 하나를 유일한 업데이트 소유자로 지정하지 않습니다. 두 경로가 같은 불변 운영 DMG와 숫자 버전을 사용하고, 실제 설치 앱이 Cask보다 새로울 때 Homebrew가 다운그레이드하지 않는 계약을 검증합니다.

## 범위

도입 범위:

- 별도 공개 tap `ChoSeongmin1128/homebrew-tap`
- `Casks/claude-usage.rb` 하나로 운영 앱 배포
- 운영 Release를 검증한 뒤 Cask version·SHA-256 갱신
- 신규 설치, 기존 수동 설치본 편입, Homebrew와 Sparkle의 교차 업데이트 검증
- README·배포 문서·release driver 결과에 Homebrew 게시 상태 반영

제외 범위:

- staging Cask와 staging tap
- 소스에서 앱을 빌드하는 Homebrew formula
- 앱에서 Homebrew를 실행하거나 설치 출처를 변경하는 기능
- Cask 설치본의 Sparkle 비활성화
- Homebrew 공식 저장소 등록. 자체 tap을 안정화한 뒤 당시의 공식 수용 기준을 다시 확인합니다.

staging 후보는 `CFBundleShortVersionString`이 같고 build와 검증 회차로 구분됩니다. Homebrew Cask의 사용자용 version과 맞지 않으므로 Cask에는 운영 버전만 게시합니다.

## 배포 구성

| 구성 요소 | 정본과 역할 |
|---|---|
| GitHub 운영 Release | 불변 태그 `vX.Y.Z`와 검증된 `ClaudeUsage.dmg` 제공 |
| 운영 appcast | Sparkle의 버전 발견, 노트, enclosure와 서명 제공 |
| Homebrew tap | 검증된 운영 버전·DMG URL·SHA-256을 선언 |
| 설치 앱 | `/Applications/ClaudeUsage.app`, 운영 bundle identifier와 운영 feed 유지 |

Homebrew와 Sparkle은 별도 payload를 만들지 않습니다. 두 경로 모두 같은 운영 Release의 `ClaudeUsage.dmg`를 사용합니다. Cask 파일은 운영 Release의 파생 메타데이터이며 앱 바이너리의 정본이 아닙니다.

초기 Cask 계약은 다음과 같습니다.

```ruby
cask "claude-usage" do
  version "X.Y.Z"
  sha256 "VERIFIED_DMG_SHA256"

  url "https://github.com/ChoSeongmin1128/claude-usage/releases/download/v#{version}/ClaudeUsage.dmg"
  name "ClaudeUsage"
  desc "Menu bar usage monitor for Claude, Codex, and Antigravity"
  homepage "https://github.com/ChoSeongmin1128/claude-usage"

  livecheck do
    url "https://choseongmin1128.github.io/claude-usage/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true

  depends_on macos: :sonoma
  app "ClaudeUsage.app"
end
```

- `version :latest`를 사용하지 않습니다. 숫자 version이어야 Homebrew가 Cask와 설치 앱의 버전을 비교할 수 있습니다.
- 운영 버전은 게시할 때마다 증가하고 기존 태그·자산을 바꾸지 않으므로 Cask version에는 build를 결합하지 않습니다.
- `livecheck`는 최신 버전을 찾기 위한 보조 경로입니다. Homebrew 경로의 payload 무결성은 tap에 커밋된 SHA-256으로 검증합니다. Sparkle feed 서명은 앱 내부 업데이트 경로의 신뢰 기준이며 Homebrew 검증을 대신하지 않습니다.
- `auto_updates true`로 앱 자체 업데이트가 가능함을 선언합니다.
- 초기 도입에는 `zap`을 넣지 않습니다. 일반 `brew uninstall --cask`가 앱 번들만 제거하고 계정·설정·CLI 자격을 보존하도록 합니다. 전체 초기화 범위가 별도로 검토된 뒤에만 명시적인 `--zap` 계약을 추가합니다.
- 설치 파일에 동적 Ruby 코드, 외부 명령, postflight 스크립트를 넣지 않습니다.

tap의 Cask 이름은 Homebrew 전체에서 충돌할 수 있으므로 구현 직전에 다시 검색합니다. 충돌하면 사용자명 접두사를 포함한 이름으로 바꾸고 설치 명령과 마이그레이션을 함께 확정합니다.

## 두 업데이트 경로의 상태 계약

| 상태 | Homebrew 동작 | Sparkle 동작 | 기대 결과 |
|---|---|---|---|
| 설치 앱이 Cask보다 오래됨 | `brew upgrade`가 운영 DMG로 교체 | 새 운영 버전을 발견 | 먼저 시작한 한 경로로 정상 갱신 |
| 설치 앱과 Cask가 같음 | 업그레이드 생략 | 업데이트 없음 | 재설치·다운그레이드 없음 |
| Sparkle이 먼저 앱을 새 버전으로 갱신함 | 실제 앱 version이 Cask 이상이면 생략 | 이미 최신 | 이전 Cask receipt 때문에 다운그레이드하지 않음 |
| tap이 아직 이전 운영 버전임 | 이전 Cask 유지 | 새 appcast로 갱신 가능 | tap 지연이 Sparkle 업데이트를 막지 않음 |
| Homebrew 자동 갱신 Cask 제외 설정 또는 pin 사용 | 일반 `brew upgrade`에서 제외될 수 있음 | 계속 동작 | 앱 설정에서 업데이트 가능 |
| Sparkle 설치가 준비된 동안 Homebrew 갱신 시작 | 동시 교체 금지 | 진행 중 세션 정리 필요 | 앱을 종료하고 한 경로만 완료한 뒤 재검증 |

Sparkle이 먼저 업데이트하면 Homebrew의 설치 receipt가 이전 Cask version을 표시할 수 있습니다. 이 차이를 오류로 숨기지 않습니다. 실제 앱의 `CFBundleShortVersionString`·`CFBundleVersion`과 서명을 기준으로 상태를 판단하고, Homebrew가 versioned `auto_updates` Cask의 실제 앱 버전을 비교하는지 통합 테스트로 고정합니다.

Homebrew는 권한 상태에 따라 앱 번들을 제자리 교체하거나 제거 후 다시 설치할 수 있습니다. 후자는 macOS의 Dock·Launchpad·앱 권한 등록에 영향을 줄 수 있습니다. ClaudeUsage는 메뉴바 앱이므로 Homebrew 업그레이드 후 ControlCenter의 메뉴바 표시가 다른 호스트에 연결되지 않는지, 기존 표시 허용 상태와 단일 프로세스가 유지되는지 실제 앱으로 확인합니다.

## 기존 설치본 편입

신규 사용자는 완전한 이름으로 설치합니다. 이 방식은 tap 전체가 아니라 지정한 Cask만 신뢰하는 현재 Homebrew 계약을 사용합니다.

```bash
brew install --cask choseongmin1128/tap/claude-usage
```

이미 `/Applications/ClaudeUsage.app`을 수동 또는 Sparkle로 설치한 사용자는 다음 순서를 사용합니다.

1. 앱 자체 업데이트로 Cask와 같은 최신 운영 버전까지 올립니다.
2. ClaudeUsage를 종료하고 staging이 실행 중이지 않은지 확인합니다.
3. 동일한 artifact인지 확인하는 `--adopt`를 사용합니다.
4. version/build, 코드 서명, 운영 feed, 기존 계정·표시 설정을 확인합니다.

```bash
brew install --cask --adopt choseongmin1128/tap/claude-usage
```

`--adopt`는 대상 앱이 Cask artifact와 동일할 때만 성공해야 합니다. 실패했을 때 `--force`로 덮어쓰는 절차를 기본 안내로 제공하지 않습니다. 앱 번들만 별도로 제거한 뒤 Cask를 설치하는 복구가 필요한 경우에도 Application Support, UserDefaults, Keychain과 각 CLI의 자격 저장소는 삭제하지 않습니다.

## 게시 순서

Cask 갱신은 운영 게시가 모두 끝난 뒤 수행합니다. staging 게시나 운영 빌드 시작 시점에는 tap을 변경하지 않습니다.

1. 기존 통합 driver로 승인한 staging 후보를 운영으로 승격합니다.
2. 운영 태그·세 자산·Pages `built`·공개 appcast·원격 DMG의 서명, 공증, Gatekeeper와 SHA-256을 검증합니다.
3. 검증 결과에서 version, 태그, DMG URL, DMG SHA-256을 구조화된 manifest로 내보냅니다.
4. manifest와 원격 appcast가 같은 운영 version·DMG URL을 가리키는지 확인합니다.
5. Cask를 결정적으로 렌더링하고 기존 tap과의 diff가 version·SHA-256 이외의 예기치 않은 변경을 포함하지 않는지 검사합니다.
6. 격리된 tap에서 `brew style`, Cask audit, livecheck, 다운로드 SHA-256과 앱 메타데이터 검사를 통과시킵니다.
7. tap main에 커밋·push한 뒤 공개 tap에서 version·SHA-256·URL을 다시 읽어 운영 Release와 대조합니다.
8. 실제 설치·업그레이드 검증을 마친 뒤 README에 Homebrew 설치 명령과 현재 지원 상태를 공개합니다.

release driver에 연동할 때 Homebrew 게시 단계는 운영 Release보다 뒤에 있는 재시도 가능한 후속 단계로 둡니다. 운영 게시 성공 후 tap 갱신이 실패해도 기존 운영 태그·자산·feed를 되돌리거나 덮어쓰지 않습니다. 결과를 `운영 게시 완료, Homebrew 반영 대기`로 명확히 남기고 동일 manifest로 tap 단계만 재시도합니다.

tap이 운영 Release보다 먼저 새 version을 제공하거나 검증하지 않은 SHA-256을 게시하는 경로는 허용하지 않습니다. Cask 게시가 완료된 뒤 운영 자산을 바꾸는 것도 금지합니다.

## 자동화 경계

도입 초기에는 다음 두 단계로 나눕니다.

1. Cask 생성·검증과 tap 갱신을 별도 명령으로 수행해 상태와 실패 복구를 검증합니다.
2. 충분한 실배포 근거가 생기면 통합 release driver가 운영 원격 검증 후 같은 명령을 호출하도록 연결합니다.

자동화는 다음 성질을 가져야 합니다.

- 운영에서만 실행하고 staging에서는 no-op이 아니라 명시적으로 비대상임을 출력
- 입력은 검증된 원격 manifest만 사용하고 로컬 미게시 DMG를 사용하지 않음
- 같은 version·SHA-256 재실행은 변경 없이 성공
- 같은 version에 다른 SHA-256이 나오면 불변 자산 위반으로 중단
- tap의 현재 version이 더 새로우면 중단
- GitHub 계정·대상 tap·원격 URL을 고정하고 완료 후 기존 계정 복원
- 자격증명, 절대 로컬 경로, 원본 API 응답을 문서·로그·Cask에 기록하지 않음

tap 저장소는 `Casks/claude-usage.rb`와 필요한 최소 CI만 유지합니다. fully-qualified Cask 설치를 안내하며 tap 전체 신뢰를 요구하지 않습니다. branch protection과 최소 권한을 적용하고, Cask 로딩 시 임의 코드를 실행하는 workflow·외부 command는 추가하지 않습니다.

## 검증 행렬

### 정적·원격 검증

- Cask style과 online audit 통과
- appcast livecheck가 운영 short version만 반환
- Cask URL이 정확한 운영 태그의 `ClaudeUsage.dmg`를 가리킴
- Cask SHA-256, GitHub asset digest, 재다운로드한 DMG SHA-256 일치
- universal 앱, macOS 14 이상, 운영 bundle identifier·feed 확인
- codesign, notarization staple, Gatekeeper 통과
- staging tag·앱 이름·bundle identifier·feed가 Cask에 없음

### 설치·업데이트 검증

| 시나리오 | 필수 확인 |
|---|---|
| 미설치 → Cask 설치 | `/Applications/ClaudeUsage.app`, 첫 실행, 메뉴바, 운영 feed |
| 같은 버전 수동 설치 → `--adopt` | 앱 재복사 없음, Cask 등록, 설정·계정 유지 |
| 이전 Cask → 새 Cask | 일반 `brew upgrade`, 버전/build·서명·메뉴바·설정 유지 |
| Cask 설치 → Sparkle 업데이트 | 앱 내 확인·설치·재실행 성공, Cask 관리 상태 유지 |
| Sparkle 선행 업데이트 → `brew upgrade` | 같은 버전 재설치와 다운그레이드 없음 |
| 실행 중 Homebrew 업데이트 | 정상 종료·교체·Finder 재실행, 중복 프로세스 없음 |
| Homebrew 업데이트 후 Sparkle 다음 버전 | feed 확인과 설치가 계속 동작 |
| `brew uninstall --cask` | 앱만 제거, 사용자 데이터와 외부 CLI 자격 보존 |
| 재설치 | 기존 설정·계정 이전 유지, 평문 자격 생성 없음 |

Homebrew 업그레이드 후에는 ControlCenter 메뉴바 등록, 다른 앱과의 잘못된 연결, 앱 표시 허용 상태를 확인합니다. 검증 중에는 운영과 staging을 동시에 실행하지 않습니다. 자동화 도구로 메뉴바 창 연결이 반복 실패하면 같은 호출을 반복하지 않고 필요한 Finder 실행과 설정 창 열기만 수동으로 확인합니다.

지원하는 두 CPU에서 동일한 universal DMG를 사용하지만 최소 한 번씩 신규 설치와 실행 서명을 확인합니다. 별도 macOS 환경이 없으면 구버전 Homebrew·macOS 조합은 검증하지 않은 항목으로 남기며 최신 환경의 성공으로 대체하지 않습니다.

## 완료 기준

- 공개 tap에서 fully-qualified 명령으로 신규 설치 성공
- 일반 `brew upgrade`와 Cask 지정 업그레이드 성공
- Homebrew 설치본의 Sparkle 업데이트 성공
- Sparkle 선행 업데이트 뒤 Homebrew가 재설치·다운그레이드하지 않음
- 기존 수동 설치본의 안전한 편입 또는 실패 시 데이터 보존 복구 절차 검증
- 메뉴바 등록, 설정, 계정, 자동 조회, 코드 서명에 회귀 없음
- 운영 배포 실패와 Homebrew 후속 게시 실패를 서로 구분하고 각각 재시도 가능
- README, 배포 문서, 유지보수 현황이 실제 공개 tap 상태와 일치

## 참고

- [Homebrew의 self-updating 앱 처리](https://docs.brew.sh/FAQ#how-does-brew-upgrade-handle-apps-that-update-themselves)
- [Cask 작성 규칙](https://docs.brew.sh/Cask-Cookbook)
- [third-party tap 생성과 유지](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [tap trust](https://docs.brew.sh/Tap-Trust)
- [기존 앱의 Cask 편입](https://docs.brew.sh/Tips-and-Tricks#adopt-a-manually-installed-app-as-a-cask)
