# 参与开发

优先保证 11 英寸 iPad Pro 的横屏阅读与笔记体验，同时兼顾竖屏：横竖屏、窄窗口、键盘避让、Pencil 与手指共存、草稿恢复和离线可用。再验证 iPhone 与 Mac 的兼容性。

## 本地环境

需要完整 Xcode 26+（包含 iOS/watchOS SDK）、Python 3.10+、Git；JavaScript 单元测试需要支持 `node --test` 的 Node.js。当前本地验收使用 Xcode 26.6。部署系统最低版本与编译 SDK 版本不同。

```sh
python3 scripts/generate_project.py
bash scripts/check.sh
```

项目文件由 `scripts/generate_project.py` 生成。修改构建设置、资源、target 或共享源文件列表时，修改生成器并重新生成，不要只改 `.pbxproj`。个人签名使用 Xcode 的 Team 或命令行参数，不把个人 Team、设备 UDID、配置描述文件和密钥写进公共配置。

`Package.swift` 的测试覆盖 Core、传输、终端与共享 ReaderModel。iPad 的 UIKit/PencilKit 测试由 Xcode scheme `booklifePencilTests` 运行，不在 `swift test` 中。具体命令见 [开发与架构](docs/development/architecture.md)。

## 目录约定

- iPad/iPhone 与 Watch 平台代码放在 `Apps/`，按入口、书库、阅读和连接职责归类。
- 通用模型、传输、终端和共享阅读实现放在 `Sources/` 对应模块，测试放在 `Tests/` 对应目录。
- 使用说明放在 `docs/guides/`，架构与发布说明放在 `docs/development/`，设计约定放在 `docs/design/`。文档入口是 [文档导航](docs/README.md)。
- 构建入口保留在 `scripts/` 顶层；专项检查、原创夹具和开发诊断分别放在 `checks/`、`fixtures/`、`dev/`。见 [脚本说明](scripts/README.md)。
- 安装过程、设备记录、录屏原片和临时分析放在忽略的 `build/`，不要向根目录追加工作日志或同步冲突副本。

移动文件后更新生成器、脚本引用和 Markdown 链接，再重新生成工程。路径变化也需验证导出的源码可以独立构建。

## 提交改动

1. 用原创的最小 EPUB、临时目录和独立 UserDefaults suite 复现问题。不得使用个人书库或访问真实付费 AI 服务。
2. 修改相关模块，保持旧索引、笔记、CFI、进度和配对数据的兼容性。数据保存失败时保留可编辑内容，不显示成功状态。
3. 运行与改动相关的检查。阅读、笔记、布局的变化需提供 iPad 横竖屏与窄窗口截图；纯脚本或文档变更不要求 UI 截图。
4. 提交前运行 `python3 scripts/check-publication.py`。不要提交 `build/`、同步冲突副本或设备安装记录。
5. PR 写清用户可见的行为、验证结果与未覆盖范围。

Bug 报告请写出版本、设备/系统、复现步骤、期望与实际结果。先用随附示例书复现，再附脱敏截图；不要附受版权限制的图书或密钥。安全问题按 [SECURITY.md](SECURITY.md) 私密报告。

提交代码表示你有权按项目的 [MIT 许可证](LICENSE) 贡献这些内容。第三方资源必须保留原许可证与来源记录。
