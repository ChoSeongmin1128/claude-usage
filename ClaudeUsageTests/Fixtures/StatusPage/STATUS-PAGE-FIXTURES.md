# Status page fixtures

Public Statuspage responses captured on 2026-10-11 (UTC).

`claude-summary.json` and `openai-summary.json` are the unmodified
`/api/v2/summary.json` responses of `status.claude.com` and
`status.openai.com`. A summary lists only unresolved incidents. At capture
time each page had one active incident and one degraded component, and the
OpenAI page listed the `Login` component twice.

`claude-incidents.json` and `openai-incidents.json` come from
`/api/v2/incidents.json`, which also lists recently resolved incidents. They
are reduced to the fields the decoder reads: incident name, status, impact,
shortlink, `updated_at`, component names and statuses, and every incident
update's status, `display_at` and affected component names. Only the latest
update keeps its body; older bodies are empty strings because the interpreter
reads the latest one only. Incident classification is unchanged by the
reduction. OpenAI incidents carry no component data, as in the original
response.

These describe the pages as observed on that date, not an upstream schema
guarantee.
