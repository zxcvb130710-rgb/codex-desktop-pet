# 开发说明 · 0.1.11

## 构建与验证

开发环境为 Apple Silicon Mac、macOS 13+、Xcode Command Line Tools 和 Python 3。项目使用系统 AppKit、QuartzCore 和 Python 标准库，无需安装第三方运行依赖。

在仓库根目录运行：

```sh
zsh macos/build.sh
python3 -B -m unittest discover -s tests -v
'macos/.build/apps.noindex/GPT 桌宠.app/Contents/MacOS/GPTCompanion' --self-test
codesign --verify --deep --strict 'macos/.build/apps.noindex/GPT 桌宠.app'
```

`build.sh` 使用 Swift 5 语言模式、arm64/macOS 13 目标和优化编译，将应用与模块缓存放入 `macos/.build/`，随后做临时签名。此签名不等同于 Developer ID 签名或 Apple 公证。

需要安装插件时，优先运行 `zsh install-plugin.command`。单独打包插件应用可运行：

```sh
GPT_PET_PACKAGE_PLUGIN=1 zsh macos/build.sh
```

这会生成 `marketplace/plugins/gpt-desktop-pet/app/GPT 桌宠.app`。源码仓库忽略构建输出和打包应用；不应把 `.build/` 或本机插件缓存提交进 Git。

自检使用独立的偏好设置域，不改动正常运行中的桌宠设置。自检及签名验证成功不代表真实 Codex 控件兼容或辅助功能权限已经授予；后两项需用实际安装应用人工验证。

## 目录

| 路径 | 用途 |
| --- | --- |
| `macos/main.swift` | 透明窗口、图像和光效、菜单、偏好、任务状态归并、运行状态报告、自检 |
| `macos/CodexSelection.swift` | Codex 辅助功能控件读取、五档解析、分批扫描 |
| `macos/build.sh`、`Info.plist`、`AppIcon.*` | 构建脚本与应用元数据 |
| `marketplace/.agents/plugins/marketplace.json` | 本地插件市场清单 |
| `marketplace/plugins/gpt-desktop-pet/` | 插件清单、图标、hooks 和 Python 桥接脚本 |
| `assets/`、`character.json` | 十种透明立绘、轻量预览、状态映射及图像校验值 |
| `prompts/` | AI 辅助补绘使用的提示词 |
| `tests/test_bridge.py` | hooks 元数据读取、动作、容错、原子写入及隐私测试 |

## 两条同步通道

### 思考程度 → 形象

`CodexSelectionMonitor` 每 250 毫秒开始一次有时间和节点预算的读取。仅当 bundle ID 为 `com.openai.codex` 的应用在前台且桌宠获得辅助功能授权时扫描；优先检查焦点和菜单，大窗口分批继续遍历，不读取文本节点值。

支持旧版 `0…3` 四档、`0…4` 五档滑块，以及新版 Power／强度／強度／效能控件说明。内部档位为 `low`、`medium`、`high`、`xhigh`、`ultra`，分别映射 Light 至 Ultra。选择器关闭后保留最后读到的档位；该实时选择优先于任务事件携带的旧档位。

手动选择档位关闭「跟随 Codex」；选择动作或双击只改变动作，不关闭档位联动。

### 任务 hooks → 动作

`UserPromptSubmit` 发布 `thinking`，`Stop` 和 `Interrupt` 发布 `idle`。Python 桥接仅接受有效会话 ID、轮次 ID 和这三种事件；按当前会话只读查询 Codex 状态数据库以补充档位，使用原子替换写入事件文件。每个轮次拥有独立文件，目录与文件首次创建权限分别为 `0700`、`0600`。桥接失败时返回空结果，不阻塞 Codex 任务。

原生侧先选每个会话的最新轮次，再合并仍在运行的会话。当前 Codex 的 UUIDv7 轮次 ID 提供轮次创建顺序；其他 ID 回退到事件时间。这样旧轮次遗漏的开始事件不会覆盖新轮次完成事件，延迟的旧 `Stop` 也不会清除新任务。任一会话工作时保持思考；全部结束时待机。

事件六小时后过期。若当前轮次丢失结束事件、且该会话没有后续轮次，动作可能保持思考直到过期。这不是 Codex 内部推理状态的实时接口。

## 权限与状态诊断

档位联动需要 macOS 辅助功能权限；任务动作需要用户信任 Codex 插件 hooks。两者相互独立。

临时签名可能随构建变化。更新应用后若失去权限，应给实际运行的安装副本重新授权；不要用开发目录中的另一份应用代替。重复副本也可能使菜单和权限检查指向不同进程。

主进程把自身状态写入 `~/Library/Application Support/GPTCompanion/runtime-status.json`，只在状态变化时更新，文件权限为 `0600`。字段包括版本、PID、`accessibilityTrusted`、`followCodex`、`effort`、`selectionEffort`、`activity`、`taskEvent`、`activeSessionCount`，不含聊天内容。

可对实际应用的 `Contents/MacOS/GPTCompanion` 执行 `--permission-status`：若有有效运行进程报告，返回 `source: running-app`；否则仅返回当前检查进程的 `trustedInThisProcess`，不能据此判断另一个由 LaunchServices 启动的进程是否授权。`--connect-slider` 用于启动时请求辅助功能连接。

## 贡献与发布

修改前先复现问题，修改后运行 Python 测试、原生自检和签名检查。涉及 Codex 控件时补充名称／语言／控件排除或扫描回归，并记录实际测试的 Codex 版本；涉及任务状态时验证并发会话和旧轮次延迟事件。

提交问题时描述 macOS、芯片、Codex 与插件版本、菜单状态和复现步骤。不要附带 API key、完整聊天、Codex 数据库或未经处理的本机诊断文件。素材变更需同时核对 `character.json` 映射与校验值，并说明来源和许可。

发布源码时只包含仓库跟踪的文件。代码许可见 [LICENSE](LICENSE)，角色、图标和预览许可见 [ASSET_LICENSE.md](ASSET_LICENSE.md)。本仓库不含 API 凭据、聊天记录、原始生成日志或编译应用。运行时不需要联网或 API key。
