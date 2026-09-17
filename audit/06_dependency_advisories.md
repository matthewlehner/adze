# Issue 6 — Dependency security advisories

## Status

✅ **Resolved** — you already bumped the deps.

## What was reported

`mix deps.get` previously reported transitive advisories:

- `req` — **HIGH** `CVE-2026-49756` (multipart form-data header injection) and **HIGH** `CVE-2026-49755` (decompression bomb DoS).
- `usage_rules` — **LOW** `CVE-2026-82710` (terminal escape injection via `mix usage_rules.search_docs`).

These came through `igniter` and `usage_rules`.

## Verification steps

After bumping, confirm the warnings are gone:

```bash
mix deps.get
mix deps.audit        # if you have mix_audit installed
```

Also keep an eye on `mix hex.audit` / `mix deps.audit` in CI so you don't re-introduce vulnerable versions.

## Notes for consumers

- `usage_rules` is only used in `:dev`, so the LOW CVE only affects users who run `mix usage_rules.search_docs` in a terminal.
- `req` is transitive through `igniter` and is used for network calls; keeping it patched is important.
