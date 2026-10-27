# Snipbo 软件更新功能设计

日期:2026-10-28
状态:已与用户对齐(四项决策见下),待实现

## 背景与决策

spec(2026-10-21)曾将「零网络」列为硬性排除,Updates 页按纯手动设计(跳转浏览器)。
2026-10-28 用户决定解除该排除,范围收窄为:**应用只访问 GitHub Releases 做
检查与下载安装,不新增任何遥测、上传、账号或崩溃上报。**原排除的其余部分
继续有效。About 页与 Updates 页的「完全不联网」文案随本设计修订。

四项已确认的决策:

1. **隐私范围**:窄解除——仅更新检查与下载(方案:手写轻量更新服务,不用 Sparkle)。
2. **发布渠道**:功能先行,URL 常量指向 `Liuke618/snipbo`;仓库公开前检查会得到
   404/403,手动检查显示「发布渠道暂不可用」,自动检查完全静默,待仓库公开后自动生效。
3. **安装深度**:应用内下载 → SHA-256 校验 → 备份旧版 → 替换应用 → 自动重启。
4. **检查时机**:手动(Updates 页按钮 + 状态菜单项)+ 启动静默检查一次(默认开,
   设置可关;失败不打扰)。

## 需求

- Updates 页显示:当前版本、检查结果(已是最新 / 发现 x.y.z / 失败原因)、
  新版本说明(release body 前 600 字符,超出截断)、「下载并安装」进度。
- 状态菜单:「检查更新…」;发现新版本时变为「安装更新 x.y.z」。
- 安装完成后应用以新版本重启;设置与历史(AppSupport)不受影响。
- 当前应用不在 `/Applications` 或 `~/Applications` 时(开发构建),不提供
  自动安装,显示提示让用户手动安装。
- 新增设置 `autoCheckUpdates`(默认开),只影响启动静默检查,不影响手动检查。

## 架构

依赖方向:`SnipboApp/Update/UpdateCoordinator` → `SnipboCore/Update/*`。无第三方依赖。

### SnipboCore/Update(纯逻辑,全部可单测)

- `UpdateModels.swift`
  - `SemVer`(解析 `v0.5.0` / `0.5.0`,按数字段比较;段数不齐时右侧补 0;
    非数字段(如 `-beta`)视为无法比较,调用方按「不提示更新」处理,避免误升/降级)
  - `UpdateRelease`(tag、name、说明、资产列表)
  - `UpdateAsset`(name、url、size)+ `UpdateError` 枚举
    (requestFailed / channelUnavailable / rateLimited / noMatchingAsset /
    checksumMismatch / notInstalledInApplications / installFailed(underlying))
    每个错误带用户可读的本地化描述。
- `UpdateChecker.swift`
  - `check() async throws -> UpdateRelease`:GET
    `https://api.github.com/repos/Liuke618/snipbo/releases/latest`,
    解码 `tag_name`、`name`、`body`、`assets`。
  - HTTP 状态映射(判定顺序固定):带速率限制头的 403/429 → rateLimited;
    404/403 → channelUnavailable;其余非 200 → requestFailed。
- `UpdatePackage.swift`
  - 从资产中挑选 `Snipbo-<ver>-arm64.zip` 与同名 `.sha256`;若仅有一个 zip
    资产则直接取用。
  - `verifySHA256(of:digestText:)`:解析 `<hex>  <filename>` 格式并比较。

### SnipboApp/Update

- `UpdateCoordinator.swift`(@MainActor 状态机,单例式,由 AppDelegate 持有)
  - 状态:idle / checking / upToDate / available(UpdateRelease) /
    downloading(progress) / installing / failed(UpdateError)
  - 入口:`checkInteractively()`(结果用窗口反馈)、`checkSilently()`
    (任何失败静默回到 idle)、`install()`(仅 available 态有效)。
  - 安装流水线(每步失败即回滚并报告):
    1. 下载 zip + sha256 到 `~/Library/Caches/Snipbo/updates/`(URLSession,
       上报进度);
    2. 校验 SHA-256,失败删除下载物;
    3. `ditto -x -k` 解压到同目录临时文件夹,校验 `Contents/MacOS/Snipbo`
       存在且 `CFBundleShortVersionString` 等于目标版本;
    4. 将 `Bundle.main.bundleURL` 移动到备份路径(同一 updates 目录下的
       `backup/`,下次下载开始时清理);
    5. 移动新包到目标位置;失败则把备份移回原位后报 installFailed;
    6. `Process /usr/bin/open <新包路径>` + 延迟 `NSApp.terminate(nil)`。
  - 启动静默检查:启动后延迟 10 秒,`autoCheckUpdates` 开且无手动检查进行中;
    发现新版本时状态菜单项变为「安装更新 x.y.z」。
- `StatusItemController`:菜单加「检查更新…」/「安装更新 x.y.z」,状态从
  coordinator 读取。

### 设置与文案

- `AppSettings` 新增 `autoCheckUpdates: Bool`(默认 true,decodeIfPresent 兼容旧档)。
- Updates 页重写:当前版本行;自动检查开关行;检查按钮(含进度态);结果区
  (已是最新 / 新版本 + 说明节选 + 「下载并安装」按钮 / 失败原因)。
- About 页与 Updates 页文案:从「完全不联网」改为「除检查更新外不联网
  ——无上传、无遥测、无崩溃上报,截图永远留在你的电脑上」。

## 安全与边界

- 只出站 GET 两个主机名:api.github.com 与 github.com(releases 资产下载)。
- 校验失败、解压失败、版本不符一律放弃安装并清理下载物,绝不启动未经校验的包。
- 应用由稳定的自签名身份「Snipbo Local Signing」签署;替换后 designated
  requirement 不变,屏幕录制等 TCC 授权保持有效。
- `/Applications/Snipbo.app` 为拖拽安装(用户所有),替换无需管理员;若
  移动失败(属主异常)按 installFailed 报告并回滚。
- 下载目录独占使用,启动安装前清理上次残留。

## 测试

- `SnipboCoreTests`:SemVer 解析/比较(含段数不齐、前缀 v、非数字段);
  releases/latest JSON 解码(fixture);HTTP 状态 → UpdateError 映射;
  资产挑选;sha256 文本解析与校验。
- 安装路径:对「备份→替换→回滚」用临时目录 + 假 app 包做集成测试
  (不真重启;`open` 调用注入替身)。
- 手动验证清单:私有渠道 404 的提示文案;真实 release 的检查/下载/安装/
  重启;断网时的手动与静默行为;开发构建下不出现安装按钮。
