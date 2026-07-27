# Antigravity quota fixtures

`agy-1.1.7-quota-summary.json` was captured on 2026-07-26 from the local
AGY 1.1.7 `RetrieveUserQuotaSummary` endpoint. AGY was launched with
`AGY_CLI_DISABLE_AUTO_UPDATE=true`.

The fixture preserves the observed response envelope, field names, array shape,
product-level group and bucket identifiers, `window` values, and optional-field
presence. `remainingFraction`, `resetTime`, and the bucket description that
contained live reset timing were replaced with deterministic fixture values.
The captured payload contained no email, token, or account identifier fields.
The unsanitised response is not retained.

This is one account and version snapshot of an undocumented local endpoint, not
an upstream compatibility guarantee.

## Legacy OAuth account fixture

`legacy-oauth-user-shape-redacted.json`은 실제 `oauth_accounts.json`의 필드 구조,
snake/camel case 혼용, 복수 계정 및 active account 형태만 재현한 결정적 fixture입니다.

- 모든 identity는 `example.invalid` 도메인을 사용합니다.
- token과 client secret은 실행 불가능한 `[redacted-*]` 표식입니다.
- 실제 사용자 credential, token fingerprint 또는 Keychain payload를 포함하지 않습니다.
