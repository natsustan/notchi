<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Notchi 1.1.2

A small polish release that makes active sessions easier to return to and gives the mascot a little more motion variety.

## Session Jumping

Notchi can now take you back to the place where an agent session is running.

- Opens Codex desktop sessions through their thread URL
- Focuses the hosting terminal app for Codex CLI and Claude CLI sessions
- Safely ignores stale, missing, or non-terminal session origins

## Mascot Polish

Sprites now have more visual variety without changing the core interaction model.

- Adds mirrored sprite sheets for supported mascot states
- Randomizes mirrored variants so repeated idle and working loops feel less repetitive
- Keeps sprite handoff and compact idle behavior covered by tests

## Website Copy

- Updates the website description so Notchi is clearly positioned for both Claude Code and Codex activity
