# Snipbo

A fast, local-first screenshot and annotation tool for macOS. 截图、标注、OCR、贴图，全部在本机完成。

Snipbo 是一个常驻菜单栏的截图工具：按下一个全局快捷键进入选区，标注后回车复制或保存。应用不发起任何网络请求，不上传、不统计、不需要账户。

当前版本：**0.4.0**

## 功能

### 截图模式

| 模式 | 说明 | 默认快捷键 |
| --- | --- | --- |
| 区域截图 | 冻结画面后拖拽框选，可移动、调整八向手柄、方向键微调 | `⌘⇧7` |
| 窗口截图 | 悬停高亮窗口后点击捕获，可选裁掉窗口阴影 | 未设置 |
| 屏幕截图 | 捕获鼠标所在显示器 | 未设置 |
| 全部屏幕 | 捕获所有显示器并按物理排列拼接 | 未设置 |
| 延时截图 | 倒计时后执行区域或屏幕截图（默认 3 秒） | 未设置 |
| 上次区域 | 复用上一次的选区直接截图 | 未设置 |
| 滚动截图 | 框选区域后滚动内容，自动对齐并拼接长图 | 未设置 |

区域选择时：

- 拖拽创建选区，拖动选区可移动。
- `方向键` 移动 1 pt，`Shift + 方向键` 移动 10 pt。
- `Option + 方向键` 调整对应方向的边界。
- `Enter` 确认，`Esc` 取消。

滚动截图使用 Vision 做帧间垂直对齐，默认 10 fps、最大高度 20,000 px，均可在设置中调整。对齐置信度不足时保留已捕获内容并提示。

### 编辑器

支持 14 种工具：选择、箭头、矩形、椭圆、直线、画笔、荧光笔、文字、像素化、模糊、聚光灯、序号、放大镜、裁剪。工具栏提供颜色与线宽控制，裁剪不会栅格化标注，所有操作可撤销/重做（最多 50 步）。

单键切换工具：

| 键 | 工具 | 键 | 工具 |
| --- | --- | --- | --- |
| `V` | 选择 | `P` | 像素化 |
| `A` | 箭头 | `B` | 模糊 |
| `R` | 矩形 | `F` | 聚光灯 |
| `O` | 椭圆 | `C` | 序号 |
| `L` | 直线 | `M` | 放大镜 |
| `D` | 画笔 | `K` | 裁剪 |
| `H` | 荧光笔 | `T` | 文字 |

编辑器快捷键：

| 快捷键 | 动作 |
| --- | --- |
| `Enter` | 复制并关闭 |
| `⌘C` | 复制，保持编辑器打开 |
| `⌘S` | 保存到默认目录并关闭 |
| `⌘⇧S` | 另存为 |
| `Esc` | 关闭；可在设置中选择关闭前自动复制和/或保存（裁剪中按 Esc 则取消裁剪） |
| `⌘Z` / `⌘⇧Z` | 撤销 / 重做 |
| `⌘P` | 作为贴图置顶 |
| `0` / `1` | 适应窗口 / 实际大小 |
| `Tab` | 复制当前颜色（`#RRGGBB`） |
| `Delete` | 删除选中的标注 |
| `⇧P` | 切换逻辑点 / 像素读数 |

单键工具、`0`/`1`、`Tab`、`Delete` 在画布聚焦时生效；正在编辑文字时，`Enter` 提交文字、`Esc` 取消文字编辑。

### OCR 与条码

使用 Vision 在本机识别当前编辑图上的文字与条码（QR、Aztec、Data Matrix、PDF417、常见一维码等）：

- 支持简体中文与英语，可同时启用。
- 识别块在画布上高亮，右侧面板展示文本；可一键复制全部（含条码内容），也可选中部分复制。
- 可选去除文本中的换行。
- 识别在后台串行执行，关闭编辑器即取消。

### 贴图、历史与设置

- **贴图**：把截图或历史图片变成无边框置顶窗口；拖动移动、滚轮缩放、`⌘C` 复制、`Esc` 关闭，右键可关闭全部。
- **最近截图**：菜单栏子菜单直接访问最近的历史条目。
- **历史浏览**：网格浏览历史，双击重新编辑，右键贴图、复制、在 Finder 中显示或删除，可一键清空。
- **设置**：通用 / 快捷键 / 高级 / 更新 / 关于五个分页；支持中英文界面、每个截图模式独立热键、开机启动、Retina 缩至 1x 等。

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本。
- Apple Silicon（构建脚本默认只产出 arm64）。
- Swift 6 工具链。只安装 Command Line Tools 也能构建和测试，不需要完整 Xcode。

## 安装

### 下载

从 [GitHub Releases](https://github.com/Liuke618/snipbo/releases) 下载最新的 `Snipbo.app`，拖入 `/Applications`；如果没有现成构建，按下面的步骤从源码构建。

应用未做公证，首次打开若被 Gatekeeper 拦截，请在 Finder 中右键应用选择“打开”。

### 从源码构建

```bash
git clone https://github.com/Liuke618/snipbo.git
cd snipbo
./scripts/build_app.sh
open dist/Snipbo.app
```

安装到应用目录：

```bash
cp -R dist/Snipbo.app /Applications/
open /Applications/Snipbo.app
```

`build_app.sh` 会执行 release 构建、组装 `.app`、复制 `Info.plist` 与图标，并完成签名。

### 屏幕录制权限

首次截图时 macOS 会请求“屏幕录制”权限，请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许 Snipbo。授权需要重启应用才生效；权限引导页提供了“重启 Snipbo”按钮。每次启动最多只会自动请求一次权限，之后未授权时显示引导页。

ad-hoc 签名每次重建都会改变 CDHash，权限可能反复失效。建议先创建一次本机自签名证书：

```bash
./scripts/create_signing_cert.sh
./scripts/build_app.sh
```

`build_app.sh` 会自动使用名为 `Snipbo Local Signing` 的证书。之后在系统设置里移除旧的 Snipbo 条目并重新添加，权限即可在后续重建中保持。

## 数据与隐私

- **设置**：`UserDefaults`，bundle id 为 `local.snipbo.app`。
- **历史**：`~/Library/Application Support/Snipbo/History/`，包含 `index.json`、原图 PNG 与缩略图；默认上限 200 条 / 500 MB，超出后按最旧优先清理。
- **截图保存目录**：默认 `~/Pictures/Snipbo`，可在设置中修改。
- **网络**：应用代码不包含 `URLSession`，不发起任何网络请求，无上传、遥测或崩溃上报。设置中的“打开 GitHub Releases”只是调用系统浏览器打开链接。
- **历史写入时机**：每次截图在交付（打开编辑器或直接复制/保存）时记录；编辑器内再次复制或保存不会产生重复条目。
- **贴图**：不持久化，关闭应用后消失。

## 开发

### 目录结构

```
Sources/
  SnipboCore/     # 纯逻辑：文档模型、标注、渲染、导出、几何、历史、滚动拼接、设置
  SnipboApp/      # AppKit/SwiftUI：截图、编辑器、OCR、贴图、历史、设置
Tests/
  SnipboCoreTests/
Resources/           # Info.plist、AppIcon、Lucide 图标
scripts/             # 构建、签名、验证脚本
docs/                # 设计文档与阶段计划
```

`SnipboCore` 不依赖 UI，便于单元测试；所有 AppKit 对象与 UI 状态都在 `@MainActor` 上，截图、OCR、滚动帧处理与历史写盘在后台执行。

### 常用命令

```bash
swift build            # debug 构建
swift test             # Swift Testing 单元测试
./scripts/build_app.sh # release 构建并打包到 dist/Snipbo.app
```

`swift run` 产出的未打包进程不能用于验证屏幕录制权限，TCC 相关测试请始终运行打包后的 `dist/Snipbo.app`。

仓库内还有几个不需要真实屏幕的验证脚本：

```bash
./scripts/run_editor_probe.sh          # 编辑器行为探针
./scripts/run_scroll_verify_harness.sh # 滚动拼接验证
./scripts/run_final_fix_harness.sh     # 截图交付路径验证
```

### 技术栈

- Swift 6（Swift 6 language mode）、SwiftPM
- AppKit + SwiftUI
- ScreenCaptureKit、Vision、Core Graphics、ImageIO
- Carbon 全局热键（`RegisterEventHotKey`）
- Swift Testing

## 已知限制

- 仅构建 arm64；未验证 Intel 与 macOS 14/15 的全部行为。
- 本机自用项目，不沙盒、不公证、不提供自动更新。
- “上次区域”在显示器布局变化后失效，需要重新框选。
- 滚动截图依赖画面中的可对齐内容；纯色或极度重复的页面可能提前停止并保留已捕获部分。
- 超大长图受内存限制，可用“滚动高度”上限控制。
- `Snipbo` 为本地工作名，对外分发前应完成名称与商标检索。

## 原创性

本项目为原创实现，不基于任何反编译产物，不使用其他截图软件的代码、资源、字符串、图标或界面布局；交互上仅参考公开可见的通用截图习惯。

## 第三方资源

工具栏与菜单图标来自 [Lucide](https://lucide.dev)，按 ISC 许可证使用，许可全文见 `Resources/Icons/LICENSE`。运行时仅使用 Apple 系统框架，无第三方依赖。
