# Adze code audit — open issue tracker

This directory captures the remaining issues from the audit. The two compile-blocking warnings in `lib/adze/extract.ex` were already fixed and the dependency advisories were bumped separately.

Use this file as a checklist. Mark items `[x]` as they're resolved.

## Quick status

| # | Issue | Severity | Status | File |
|---|-------|----------|--------|------|
| 1 | `extract` rewrites local calls inside `@spec` bodies | 🟡 Medium | open | [`01_extract_spec_rewrite.md`](01_extract_spec_rewrite.md) |
| 2 | `find-callers` cannot resolve `__MODULE__`-based aliases | 🟡 Medium | open | [`02_find_callers_module_alias.md`](02_find_callers_module_alias.md) |
| 3 | Formatting / I/O failures can raise instead of returning `{:error, _}` | 🟡 Medium | open | [`03_formatting_exceptions.md`](03_formatting_exceptions.md) |
| 4 | Module disambiguation logic is duplicated across Extract/ExtractPrivate | 🟢 Low | open | [`04_code_deduplication.md`](04_code_deduplication.md) |
| 5 | No static-analysis tooling (Dialyzer/Credo) | 🟢 Low | open | [`05_static_analysis.md`](05_static_analysis.md) |
| 6 | Dependency security advisories (`req`, `usage_rules`) | 🔴 High | resolved | [`06_dependency_advisories.md`](06_dependency_advisories.md) |
| 7 | Compile warnings in `lib/adze/extract.ex` | 🔴 High | resolved | n/a |

## How to work through these

1. Pick an issue from the table above.
2. Read its dedicated `.md` file for context, severity, proposed fix, and acceptance criteria.
3. Implement the fix, add/update tests, and check the acceptance criteria.
4. Mark the issue resolved in this overview and commit.
5. Move to the next issue.

When all files are checked off, run:

```bash
mix compile --warnings-as-errors
mix test
```

and, if you've completed `05_static_analysis.md`:

```bash
mix dialyzer
```
