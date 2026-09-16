# Homebrew 설치와 업데이트

ClaudeUsage는 GitHub Release의 운영 DMG와 공개 Homebrew tap을 통해 설치할 수 있습니다. 두 경로는 같은 서명·공증된 운영 DMG를 사용하며, Homebrew 설치본에서도 앱의 업데이트 확인 기능을 사용할 수 있습니다.

## 설치

macOS 14 이상의 Apple Silicon 및 Intel Mac을 지원합니다.

```bash
brew install --cask choseongmin1128/tap/claude-usage
```

설치 후 `/Applications/ClaudeUsage.app`을 Finder에서 실행합니다. 완전한 Cask 이름을 사용하면 tap 전체가 아니라 이 Cask만 신뢰 대상으로 추가됩니다.

## 기존 설치본 편입

DMG 또는 앱 자체 업데이트로 설치한 ClaudeUsage를 Homebrew 관리로 바꾸려면 다음 순서를 따릅니다.

1. 앱 자체 업데이트로 최신 운영 버전까지 올립니다.
2. ClaudeUsage를 종료합니다.
3. Finder에서 `/Applications/ClaudeUsage.app` 번들만 휴지통으로 옮깁니다.
4. 위 Homebrew 설치 명령을 실행합니다.
5. Finder에서 앱을 실행하고 기존 설정과 계정 상태를 확인합니다.

앱 번들 밖의 UserDefaults·Application Support·Keychain 자료와 Claude Code·Codex CLI·AGY CLI의 자격 저장소는 이 절차로 삭제하지 않습니다.

`--adopt`는 사용하지 않습니다. `auto_updates true`인 Cask를 adopt하면 Homebrew가 기존 앱과 내려받을 artifact의 version·내용을 비교하지 않아, 오래된 앱이 최신 receipt로만 등록될 수 있습니다.

## 업데이트

Homebrew로 업데이트하려면 다음 명령을 사용합니다.

```bash
brew upgrade --cask choseongmin1128/tap/claude-usage
```

일반 `brew upgrade`도 Cask가 오래된 경우 ClaudeUsage를 갱신합니다. 앱 안의 설정 → 업데이트에서 Sparkle 업데이트를 설치할 수도 있습니다.

두 업데이트를 동시에 진행하지 마세요. Homebrew를 사용할 때는 앱을 종료하고 교체가 끝난 뒤 Finder에서 다시 실행합니다. Sparkle이 먼저 앱을 갱신하면 Homebrew receipt가 이전 버전을 표시할 수 있으므로, 문제가 있으면 receipt와 실제 앱 버전을 함께 확인합니다.

```bash
brew list --cask --versions claude-usage
defaults read /Applications/ClaudeUsage.app/Contents/Info CFBundleShortVersionString
defaults read /Applications/ClaudeUsage.app/Contents/Info CFBundleVersion
```

## 제거와 재설치

```bash
brew uninstall --cask choseongmin1128/tap/claude-usage
```

현재 Cask에는 `zap`이 없습니다. 일반 제거는 앱 번들만 삭제하며 ClaudeUsage 설정·계정 자료와 외부 CLI 자격은 유지합니다. 완전 초기화가 필요할 때도 외부 CLI 저장소를 ClaudeUsage 데이터로 취급해 삭제하면 안 됩니다.

## 배포 신뢰

- Cask는 운영 GitHub Release의 `ClaudeUsage.dmg`와 고정 SHA-256을 사용합니다.
- 숫자 버전과 Sparkle `livecheck`로 최신 운영 버전을 확인합니다.
- 동적 Ruby 코드, 외부 명령, `postflight` 스크립트를 사용하지 않습니다.

Homebrew 설치 후 메뉴바 아이콘이 보이지 않으면 앱이 실행 중인지 확인하고 시스템 설정의 메뉴바 허용 상태를 확인한 뒤 Finder에서 다시 실행하세요.

## 참고

- [Homebrew의 self-updating 앱 처리](https://docs.brew.sh/FAQ#how-does-brew-upgrade-handle-apps-that-update-themselves)
- [tap trust](https://docs.brew.sh/Tap-Trust)
- [Homebrew의 앱 편입 안내](https://docs.brew.sh/Tips-and-Tricks#adopt-a-manually-installed-app-as-a-cask)
