# Codex Desktop Pet

A native Swift / AppKit companion for macOS. Its appearance follows the Codex reasoning effort picker; it casts while a task runs and returns to idle when the task finishes or is interrupted.

[中文说明](README.md) · [Development notes](SOURCE.md) · [Code license](LICENSE) · [Artwork license](ASSET_LICENSE.md)

![Ultra idle and working poses](preview-ultra.png)

## Features

- Five appearances: Light, Medium, High, Extra High, and Ultra, each with idle and working artwork.
- Supports the Simplified Chinese effort picker (轻度, 中, 高, 极高, Ultra). The pet's menu uses those labels.
- Live effort selection through macOS Accessibility; no message submission needed.
- Task lifecycle via Codex plugin hooks, including concurrent chats.
- A draggable transparent window with scaling, floating, breathing, halos, and particles; respects Reduce Motion.

This is an independent community project, with no affiliation with or endorsement by OpenAI. This repository contains the macOS version only.

## Install from source

Requires Apple Silicon, macOS 13+, Xcode Command Line Tools, Python 3, the Codex desktop app, and a Codex CLI with `codex plugin` support. The build targets arm64; Intel Macs are not supported. No API key is needed to run the pet.

Clone the repository or extract its source ZIP, then run from the project root:

```sh
# If Apple developer tools are missing, install them first:
xcode-select --install

# After the tools finish installing:
zsh install-plugin.command
```

The installer builds and packages the app, registers the local marketplace, and installs `gpt-desktop-pet@pitter-desktop-pets`. Keep the checkout as the local marketplace source. Builds are ad-hoc signed and are not notarized.

In Codex, review and trust the plugin's `UserPromptSubmit`, `Stop`, and `Interrupt` hooks using `/hooks`. Installation alone does not trust them. Restart Codex and open a new chat if the current chat has not loaded the plugin. Submitting a local task then launches the pet. For standalone use, open the build directly:

```sh
open 'macos/.build/apps.noindex/GPT 桌宠.app'
```

Quit any existing pet before starting another copy.

## Connect and use

Right-click the pet, enable **跟随 Codex** (Follow Codex), and select **连接思考程度滑块…** (Connect effort picker). In System Settings → Privacy & Security → Accessibility, authorize the **actual running app**. The app launched by an installed plugin is a separate copy from a development build.

Keep Codex in the foreground, open its reasoning effort picker, and switch between Light and Ultra, pausing for about a second at each. The pet menu should show **滑块已同步** (picker synchronized). It retains the last recognized effort after the picker closes.

Ad-hoc signatures may change after rebuilding. If an update loses Accessibility access, quit the old app, remove its old permission entry, then add and enable the current running copy. An enabled entry for another copy does not authorize this process.

Drag to move; right-click for effort, pose, size, animation, and follow settings; double-click to toggle the pose. The menu bar star offers hide, show, reset, and quit.

Effort controls appearance; task status controls pose. Manually selecting effort disables follow mode. Re-enable it to resume synchronization. Manually selecting a pose keeps effort following enabled; the next task event updates the pose. “Thinking” means a task is running, including tool execution. With concurrent chats, the pet stays active until all latest tasks finish.

## Troubleshooting and privacy

Use `codex plugin list --json` to confirm the plugin is installed and enabled. **手动模式** means follow mode is off. A permission message means the running app needs Accessibility access. **尚未识别思考档位** means no supported control has been found; keep Codex in the foreground and its picker open. If effort changes but task poses do not, check hooks trust and test in a new chat.

The running app reports its state locally:

```sh
cat "$HOME/Library/Application Support/GPTCompanion/runtime-status.json"
```

Check `accessibilityTrusted`, `followCodex`, `selectionEffort`, `activity`, and `activeSessionCount`, and ensure the recorded `pid` is still running. The report changes only when state changes. Remove local identifiers before sharing diagnostics.

The app makes no network requests and does not read or store conversation text. Hooks store only session/turn IDs, action, effort, and time under `~/Library/Application Support/GPTCompanion/events/`. Before a picker value is available, the bridge reads the current session's effort metadata from local `$CODEX_HOME/state_*.sqlite` in read-only mode. These controls and database formats can change with Codex updates.

Only newly received hooks are processed; already-running tasks are not replayed. Hooks must run on the same Mac; remote and cloud tasks do not automatically sync. Records expire after six hours. A lost completion event can leave the pet working until expiry if that chat has no later turn.

## Development

```sh
zsh macos/build.sh
python3 -B -m unittest discover -s tests -v
'macos/.build/apps.noindex/GPT 桌宠.app/Contents/MacOS/GPTCompanion' --self-test
```

Use `GPT_PET_PACKAGE_PLUGIN=1 zsh macos/build.sh` to include the app in the plugin package. Self-tests cover parsing, all ten rendering states, pose following, and concurrent/stale task events. Actual Codex UI compatibility and macOS permissions need verification on the target machine. See [SOURCE.md](SOURCE.md) for implementation details.

Code is licensed under [MIT](LICENSE). Artwork, icons, and previews are licensed under [CC BY 4.0](ASSET_LICENSE.md). The character artwork was made with AI assistance; the prompts used to develop Light, Medium, and Ultra are in `prompts/`. Give credit, link the license, and indicate changes when reusing the artwork. No third-party trademark rights or OpenAI endorsement are granted.
