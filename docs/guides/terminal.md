# 终端阅读器

终端版支持 macOS 13+，以文本和终端原生配色阅读未加密、可重排版 EPUB 和带文字层的 PDF。PDF 按原页提取文字，核对版式或阅读扫描页可使用图形界面。它共用 Mac 的阅读进度，并可通过 Mac App 接受 Watch 遥控。

## 启动

在仓库根目录运行，首次启动自动用 Xcode 构建：

```sh
./booklife
./booklife /path/to/book.epub
./booklife /path/to/book.epub --no-remote
./booklife /path/to/book.epub --mode paged
./booklife --list
```

不传文件时进入书库，按方向键选择，回车打开。书库可只读发现书籍人生以及系统允许访问的 Apple Books 本机 EPUB 和 PDF；云端文件需先下载完整。不会修改 Apple Books 的元数据和阅读记录。

## 阅读操作

默认连续滚动，沿用终端字体、字号与前景背景色。状态栏显示书名和进度，`?` 打开完整帮助。

| 按键 | 操作 |
| --- | --- |
| `↑` / `k`、`↓` / `j` | 滚动一行；分页模式按页移动 |
| 空格 / `→` / PageDown | 向下约八成屏；分页时下一页 |
| `←` / PageUp | 反向阅读 |
| `m` | 切换连续滚动与分页 |
| `w`、`g` | 切换正文宽度、行距 |
| `c`、`[` / `]` | 目录、上一章 / 下一章 |
| `b`、`r` | 返回书库、刷新书库 |
| `s`、`u` | 检查进度同步、继续其他设备的位置 |
| `?`、Esc | 查看帮助、返回 |
| `q` / Ctrl-C | 保存位置并退出 |

窗口缩放后按内容位置重新排版；退出恢复原有终端屏幕和输入模式。宽度、行距与阅读模式会保留。

## 插图

支持 Kitty 与 iTerm2 图片协议。无法识别协议或解码图片时显示替代说明。可显式覆盖自动识别：

```sh
BOOKSLIDE_IMAGES=kitty ./booklife /path/to/book.epub
BOOKSLIDE_IMAGES=iterm2 ./booklife /path/to/book.epub
BOOKSLIDE_IMAGES=none ./booklife /path/to/book.epub
```

图片仅从 EPUB 内部读取。终端版不还原完整 CSS、表格、矢量图和数学排版，不执行书籍脚本。

## Watch 与进度

默认由 Mac App 中转遥控，使用已经确认的 Watch → Mac 蓝牙配对。Mac App 必须保持运行；通过根目录启动脚本进入正文时会尝试启动本项目的 Mac 开发构建。先按 [本地构建](../../README.md#本地运行) 构建 Mac App。

仅本机阅读使用 `--no-remote`。终端退出或返回书库后释放控制，断线后不补发旧指令。独立诊断接收器的选项见 `./booklife --help`。

本机续读记录位于 `~/Library/Application Support/BookSlide/Terminal/`；共享文件夹由 Mac 的进度同步设置管理，新安装不会自动连接个人目录。跨设备位置到达后由用户选择是否继续，详见 [进度同步](progress-sync.md) 与 [连接说明](connections.md)。
