#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    print -u2 -r -- '目前仅支持 Apple Silicon Mac（macOS 13 或更新版本）。'
    exit 1
fi
for required in xcrun codesign codex; do
    if ! command -v "$required" >/dev/null 2>&1; then
        print -u2 -r -- "缺少命令：$required。请先安装 Xcode Command Line Tools 和支持 plugins 的 Codex CLI。"
        exit 1
    fi
done
if [[ ! -x /usr/bin/python3 ]] || ! /usr/bin/python3 --version >/dev/null 2>&1; then
    print -u2 -r -- '需要 /usr/bin/python3；请先安装 Xcode Command Line Tools。'
    exit 1
fi
xcrun --find swiftc >/dev/null
codex plugin add --help >/dev/null

print -r -- '正在从源码编译并打包桌宠…'
GPT_PET_PACKAGE_PLUGIN=1 zsh "$TASK_ROOT/macos/build.sh"
codex plugin marketplace add "$TASK_ROOT/marketplace" --json
codex plugin add gpt-desktop-pet@pitter-desktop-pets --json
print -r -- '插件已安装。请在 Codex 的 /hooks 中审核并信任 GPT 桌宠的三个 hooks。'
