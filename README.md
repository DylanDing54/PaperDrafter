# PaperDrafter

macOS 本地 LaTeX 工程编辑器。窗口从左到右排列工程文件、源码和 PDF，支持中文输入、英文及中英混排。文件保存在普通文件夹中。

## 开始写作

双击同目录的 **PaperDrafter.app**。首次启动会将可编辑的双语示例复制到 `~/Library/Application Support/PaperDrafter/Research Notes`，并编译预览。示例包含主文件、样式和两个正文章节。

- 从 **文件 → 新建工程**（⇧⌘N）先选 **ACM**、**IEEE** 或 **Others**，点“下一步”后再命名并选择位置。ACM 使用 acmart 2.21 的 SIGCONF 样稿，IEEE 使用 IEEE Template Selector 当前列出的 Conference / Original Research 样稿。Others 可选中文混排或英文。模板随应用提供，新建时会复制主文件及相应的本地资源。
- 从 **文件 → 打开工程文件夹** 打开已有文稿。应用优先选择之前指定的主文件、顶层 `main.tex` 或含 `\documentclass` 的文件。要更改入口，选中一个 `.tex` 文件，再选择 **文件 → 设为主文件**。
- 在 Overleaf 下载工程的源码 ZIP，然后选择 **文件 → 导入 Overleaf ZIP**（⇧⌘O），指定新的解压位置。正文、图片、样式和参考文献按原有目录结构解压。
- 在 **PaperDrafter → 界面语言 / Language** 切换简体中文或 English。两种界面均可编辑两种语言。

## 编辑与预览

停顿约一秒后自动保存，也可按 ⌘S。⌘F 打开查找栏，⌘↩ 编译主文件。可拖动分隔线调整面板宽度，在 PDF 中滚动、缩放、选取文字，通过右上角导出按钮保存 PDF。⇧⌘L 切换编译日志。编译失败时保留上一次成功生成的 PDF。

- 双击 PDF 预览里的文字或图片，编辑器会打开对应的源码文件，并把光标移到排版位置。图片通常对应插图命令，宏生成的内容按 SyncTeX 记录定位。
- 点击源码左侧行号，行号底色会变暗，预览会滚动到对应内容并标红。再次点击同一行号即可恢复。可以分别标记多行，标色只在预览中显示，导出的 PDF 保留原色。空行和注释没有对应的排版内容。

文件树上的 **＋** 在工程中创建文件。外部添加或修改文件后，点击文件树的刷新按钮重新载入。编辑文件使用 UTF-8。磁盘文件发生冲突时，按 ⌘S 选择保留哪个版本。

## 编译引擎

新建 ACM 工程默认使用 LuaLaTeX，与官方参考 PDF 使用的引擎一致；IEEE 和通用英文工程使用 pdfLaTeX，通用中文工程使用 XeLaTeX。顶部引擎菜单可按工程切换。已有工程沿用保存的引擎；没有引擎记录的工程使用 Tectonic。首次使用某个宏包或字体时，Tectonic 可能需要联网下载资源，缓存齐全后可离线编译。中文模板使用 xeCJK 和 Fandol 字体。英文模板也可由 pdfLaTeX 编译。

本机已为 PaperDrafter 配置用户级 TeX Live 2026 和 latexmk，位于 `~/Library/Application Support/PaperDrafter/TeXLive/2026`。在其他 Mac 上可安装含 latexmk 的新版 MacTeX。应用按工程记忆主文件和引擎。自定义字体、宏包和文献工具需要在本机或工程中可用。编译关闭 shell escape，latexmk 使用标准参数并忽略自定义 rc 文件。Overleaf 的云端历史、评论和多人协作数据不包含在源码 ZIP 中。

## 从源码构建

在 macOS 13 或更高版本上安装 Xcode Command Line Tools，运行：

```sh
./build.sh
open PaperDrafter.app
```

构建使用系统 Cocoa 和 PDFKit，生成当前 Mac 架构的应用。Tectonic 可通过 `brew install tectonic` 安装。ZIP 导入使用本机的 `/usr/bin/python3` 和 Python 标准库。

## 项目库与选区润色

从侧栏或 **项目 → 项目库**（⇧⌘P）打开可搜索的项目列表。双击一项回到编辑器。列表会保留打开、新建或导入的工程，也会识别当前机器 TSP 工作目录中包含 LaTeX 主文档的项目。首次启动会沿用 InkTeX 已保存的工程和界面偏好。

在正文里选中一句中文或英文，停顿片刻即可看到浮窗。点 **采用** 将建议替换到原选区，⌘Z 可撤销。切换选区、编辑正文或换文件会使之前的建议失效。**写作 → 选中后自动建议** 可以关闭自动触发；⌥⌘P 可手动请求。

润色在后台通过 DeepSeek Harness 的 headless 客户端运行，按桌面配置调用 DeepSeek。模型服务收到选区和它在稿件里的位置（章节路径、段落序号、段首或段末等），由本机 DSH 处理认证。PaperDrafter 将数学公式、引用和常见 LaTeX 命令换成占位符，核对后恢复。模型生成两种候选，本机先沿主文件的 input/include 路径定位选区，模型结合位置判断句子的写作用途。收到候选后，本机限定一级章节类别，按用途和关键词检索 `~/Documents/Work/Learning/Paper/Conference/paper-structure/data/corpus.sqlite`，根据例句中常见的比较、转折等表达筛选候选。点击 **本地例句** 可查看匹配到的原句。模型请求不包含工程全文、句库原句或检索结果。
