# 0.1.12 · 中文档位联动修复

- 适配新版 Codex 的「轻度、中、高、极高、Ultra」，切换档位时桌宠会使用对应形象。旧版滑块和英文档位也可继续使用。
- 桌宠右键菜单使用相同的中文档位名。
- 在本机用 Codex 26.1117.41037 确认联动恢复。五档解析与十种形象通过原生自检。

从源码安装时，解压后在项目根目录运行 `zsh install-plugin.command`。
若更新后滑块联动提示缺少权限，请在 macOS「辅助功能」中移除旧的 GPT 桌宠条目，再添加并开启新版应用。

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
