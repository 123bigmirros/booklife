# 平台应用

`iOS/` 同时服务 iPad 和 iPhone，对应 Xcode 的 `booklifePhone` target。优先验收 11 英寸 iPad Pro 横屏。

| 目录 | 责任 |
| --- | --- |
| `iOS/App/` | 应用入口、窗口与生命周期 |
| `iOS/Library/` | iPad/iPhone 书库及首页 |
| `iOS/Reader/` | 阅读容器、触摸、工具面板与 PencilKit |
| `iOS/Connectivity/` | Mac 书库、进度交换、遥控接收及兼容中继 |
| `watchOS/App/` | Watch 界面、表冠与交互 |
| `watchOS/Connectivity/` | 阅读设备发现、蓝牙直连及恢复 |
| `Shared/` | iOS/Watch 共用的 App Intents 和通信适配 |

业务模型和持久化在 `Sources/BookSlideCore/`。跨平台的 ReaderModel、笔记和阅读 UI 位于 `Sources/BookSlideMac/Reader/`、`Notes/` 与 `Sync/`；iOS target 通过工程生成器显式复用这些文件。

工程与 Info.plist 由 `scripts/generate_project.py` 维护；新增文件或修改 target 依赖后从仓库根目录重新生成。详见 [架构与验证](../docs/development/architecture.md)。
