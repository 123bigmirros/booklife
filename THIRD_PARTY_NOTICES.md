# 第三方资源

项目自有代码、原创示例书及图标按根目录 [MIT 许可证](LICENSE) 分发。以下资源保留各自许可证，根许可证不替代这些条款。

| 资源 | 用途 | 随包许可证与来源 |
| --- | --- | --- |
| epub.js | 离线 EPUB 排版 | [BSD 许可证](Sources/BookSlideMac/Resources/Reader/EPUBJS-LICENSE)，[上游](https://github.com/futurepress/epub.js) |
| Mind Elixir Core 6.0.1 | iPad 结构图的布局、触控拖放、节点编辑与撤销 | [MIT 许可证](Sources/BookSlideMac/Resources/Reader/MindMap/vendor/MIND-ELIXIR-LICENSE)，[来源与校验](Sources/BookSlideMac/Resources/Reader/MindMap/vendor/NOTICE.txt)，[上游](https://github.com/SSShooter/mind-elixir-core) |
| JSZip | EPUB 压缩包读取 | 本项目选择其 MIT 许可；[许可证](Sources/BookSlideMac/Resources/Reader/JSZIP-LICENSE)，[上游](https://github.com/Stuk/jszip) |
| Noto Serif SC（常规字重 WOFF2 转换） | 离线中文衬线字体 | [SIL OFL 1.1](Sources/BookSlideMac/Resources/Reader/ReadingSerif-OFL.txt)，[转换与来源说明](Sources/BookSlideMac/Resources/Reader/FONT-NOTICE.txt) |

这些资源随项目保存，不在运行时从 CDN 下载。更新时一并核对来源、版本、许可证及离线 WebKit 回归；不要仅覆盖压缩后的脚本。`QuietHours.epub` 是 `scripts/fixtures/create-sample-epub.py` 生成的原创示例，不包含个人藏书。
