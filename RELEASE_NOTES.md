# 0.1.11 · Initial public source release

Native macOS desktop companion for Codex, with five reasoning-level appearances
and automatic idle/working poses.

- Light, Medium, High, Extra High, and Ultra each have two transparent sprites.
- Task start, completion, and interruption are synchronized through plugin hooks.
- Floating motion, breathing, halos, and particles support Reduce Motion.
- Concurrent chats and delayed events are handled per chat and turn.
- The source installer builds the app before installing the local plugin.

Apple Silicon and macOS 13+ are required. Download the source ZIP, extract it,
and follow [README.md](README.md) or [README.en.md](README.en.md).
Builds use ad-hoc signatures; Accessibility permission and hook trust are
configured locally. This is an independent community project.

Validated locally: five Python hook tests, all ten native rendering states,
state-handling self-tests, and code signature verification. Hosted CI and
compatibility with other Codex versions are not implied by those checks.

Code: MIT. Artwork: CC BY 4.0, with scope and attribution in ASSET_LICENSE.md.
No API key is required to run the pet.
