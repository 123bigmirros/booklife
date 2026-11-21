# 开发脚本

所有命令从仓库根目录执行。编译缓存写入本机 `~/Library/Caches/AppleProjectBuilds/book-slide/`；公开源码只包含用于项目说明的演示素材。不要将本机书库作为测试输入。

## 常用入口

```sh
python3 scripts/generate_project.py
bash scripts/check.sh
python3 scripts/check-publication.py
```

| 入口 | 用途 |
| --- | --- |
| `generate_project.py` | 生成 Xcode 工程、共享 schemes 与 Info.plist；按磁盘目录展示源码 |
| `check.sh` | Swift 与 JavaScript 测试，Mac、Watch、iOS 无签名构建 |
| `check-simulator.sh` | iPad 托管与 UI 测试；退出时自动清理本次模拟器产物 |
| `clean-simulator-builds.py` | 预览历史模拟器构建占用；加 `--apply` 执行清理 |
| `build-mac.sh` | Mac 本地开发构建及 ad-hoc 签名 |
| `check-publication.py` | 检查公开文件与忽略规则，可导出干净源码目录 |

## 专项工具

| 目录 | 内容 |
| --- | --- |
| `checks/` | WebKit、终端 PTY、JavaScript 与发布规则回归 |
| `fixtures/` | 原创示例 EPUB 与隔离的演示书库生成器 |
| `assets/` | 从品牌母图生成图标资源 |
| `dev/` | 本地 AI 开发桥接及接收端手动诊断 |

```sh
# 发布规则和 JavaScript 回归
python3 scripts/checks/test-publication.py
node --test scripts/checks/*.test.cjs

# 实际 WebKit 检查：需要正常 macOS 图形会话
xcrun swift scripts/checks/reader-webkit-check.swift

# 连续滚动、跨章反向与延迟回收：横屏、竖屏、窄窗口；截图写入 build/
xcrun swift scripts/checks/reader-gesture-check.swift

# 生成原创的隔离演示书库，不会写入应用真实书库
python3 scripts/fixtures/create-notes-demo.py build/demo-library
```

`fixtures/create-sample-epub.py` 会重新生成随包的原创示例书；`assets/generate_icons.py` 会重建图标。常规检查不需要运行这两项。

### Codex Luna 桥接

Mac 应用可直接使用已登录的 Codex CLI。iPhone 和 iPad 真机可通过 Mac 连接 Codex Luna。在已登录 Codex 的 Mac 上启动 `python3 scripts/dev/discussion-codex-bridge.py`，启动前在环境中设置 `BOOKSLIDE_LUNA_BRIDGE_TOKEN`。桥监听 `127.0.0.1:8787`。通过 HTTPS 反向代理转发 `/chat/completions`，保留 `Authorization` 请求头，并在移动端「AI 设置」填写完整的 HTTPS 地址和同一个令牌。桥接令牌可独立于 DeepSeek API Key 设置。

共享 iPad 模拟器默认请求同一台 Mac 的回环地址。开发调试也可用 `BOOKSLIDE_DISCUSSION_ENDPOINT` 覆盖 Debug 应用的回环地址。运行 `python3 scripts/dev/discussion-codex-bridge.py --fixture-only` 可以把真实模型测试限定在固定的原创材料内。常规测试使用本地协议桩。

更多平台要求和 iPad 托管测试命令见 [架构与验证](../docs/development/architecture.md)。

## 模拟器磁盘占用

```sh
# 先预览，再删除 build/ 下可重新生成的 iOS / Watch 模拟器产物与编译中间文件
python3 scripts/clean-simulator-builds.py
python3 scripts/clean-simulator-builds.py --apply

# 测试结束（包括失败）自动清理本机 iPad 缓存中的模拟器构建
bash scripts/check-simulator.sh
```

清理保留 Mac / 真机产物、书库、截图、录像和 `Logs/Test` 测试报告；不删除模拟器设备或系统运行时。需要保留二进制调试时设置 `BOOKSLIDE_KEEP_SIMULATOR_BUILDS=1`。

独立开发者可在 Xcode 中选已有 iPad 模拟器，依次选择 `booklifePencilTests` 和 `booklifeUITests` scheme，按 ⌘U 运行。项目工作站通过 `~/.local/bin/shared-apple-sim` 共用设备，运行上面的脚本会领取 iPad 并持有设备锁。CI 通过 `BOOKSLIDE_IPAD_SIMULATOR_ID` 指定 runner 已有的 iPad。

构建固定写入本机 `~/Library/Caches/AppleProjectBuilds/book-slide/<平台>/`；新增临时构建也使用这个根目录，不再创建 `build/<每次任务>/` DerivedData。
