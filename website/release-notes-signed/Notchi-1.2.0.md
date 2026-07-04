<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Notchi 1.2.0

This release adds a full cost dashboard for Claude and Codex, redesigns the usage page, and makes the notch usage ring reliable again.

## Highlights

1. Cost dashboard with a 30-day spend chart — hover any bar to see that day's cost and tokens
2. Codex cost history, scanned incrementally from session and archived-session transcripts
3. Claude/Codex toggle on the usage page to switch between providers
4. Model-aware weekly limits — the usage row now tracks whichever model your plan scopes (Fable today), instead of a hardcoded Sonnet bucket
5. Redesigned usage page: two-column usage grid, stable stat columns, and uniform number sizing that never truncates
6. The notch usage ring now reliably reappears after authentication recovery and follows the active session's provider
7. Track usage by clicking on the usage bar

![Usage dashboard](https://updates.notchi.app/release-images/1.2.0-usage-dashboard.png)

## Fixes

- Keeps usage enabled across sleep/wake and when reconnect fails with cached usage
- Defers blank session creation on SessionStart for all providers
- Persists Codex scan state across incremental boundaries
- Persists models.dev pricing and reprices cached history when rates change
- Counts id-less messages and prevents truncation double-counting in cost reports
- Pins cost formatting to a deterministic locale
- Removes temporary ring diagnostics logging
