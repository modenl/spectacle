# 交接：智能窗口布局（DESIGN.md 第 6 节 / 0.4 期）

写于 2026-10-21。给接手这部分工作的人或新会话看，读完应能独立开工。总体设计在 `DESIGN.md`，这里只讲窗口布局。

## 1. 一句话目标

按一个快捷键，把当前「工作情境」里的窗口按用户自己的习惯排好；布局不写死，从用户行为里学。

## 2. 现状

- 代码：`ModernSpectacle/` 是一个 Swift Package（swift-tools 6.2，macOS 14+），三个 target：
  - `ModernSpectacleCore`（纯 Swift，无 AppKit）：`WindowAction`（18 个动作和默认快捷键）、`WindowLayoutCalculator.rect(for:currentWindow:sourceVisibleFrame:destinationVisibleFrame:)`（单窗口几何计算，有 4 个 Swift Testing 测试）、`ShortcutBinding`。
  - `ModernSpectacleServices`：`AccessibilityClient.focusedWindow()` 和 `ManagedWindow.setFrame(_:)`（只读写**聚焦**窗口）、`ScreenGeometry.sourceAndDestination`（多显示器）、`HotKeyCenter`（Carbon 全局快捷键）、`WindowController.perform(_:)`（带撤销/重做栈）、`LoginItemController`。
  - `ModernSpectacleApp`：`AppDelegate` 建菜单栏菜单，`AppModel`，`SettingsView`（SwiftUI；0.2 期会换成 AppKit）。
- 全部约 1100 行。`swift test --package-path ModernSpectacle` 通过。
- 已发布 0.1.0 到用户的商店（app-id `modern-spectacle`），Developer ID 签名并公证。发布流程见 `~/.claude/skills/publish-to-webstore/SKILL.md`。
- 智能布局**一行代码都还没写**。前置的 0.2（Chrome 扩展 + AppKit 底座）和 0.3（Chrome 自动管理）也未开始。

## 3. 要做什么

### 3.1 数据：情境模型

- 事件源：`NSWorkspace.didActivateApplicationNotification`；每个运行中 App 一个 `AXObserver`，订阅 `kAXFocusedWindowChangedNotification`、`kAXWindowMovedNotification`、`kAXWindowResizedNotification`、`kAXTitleChangedNotification`；Chrome 标签事件来自 0.2 期的扩展（`onActivated`、`onUpdated`）。
- 存储：系统自带 SQLite（`libsqlite3`），放在 `~/Library/Application Support/ModernSpectacle/`。窗口标题不落盘原文，存哈希后的词和域名。
- 模型：窗口/标签之间的共现图。两个窗口在短时间内（比如 60 秒）被来回切换，边权加一，按天衰减。对图做聚类得到「情境」。冷启动的弱先验：App 的 `LSApplicationCategoryType`（从 `Bundle(url:)` 读 Info.plist）和标题相似度。
- 这些是计数表，内存占用可忽略；全部放在 Core，用回放的事件日志做单测。

### 3.2 数据：摆放偏好

- 键：（App bundle id，情境 id，显示器配置指纹）。显示器配置指纹 = 各屏 `visibleFrame` 排序后哈希。
- 值：用户手动摆放后的位置和大小，量化到屏幕的 1/12 网格，带衰减的直方图；众数即预测位置。
- 最强信号：我们排完之后 10 秒内用户又挪动了 → 把新位置记为高权重纠正，同时降低这次排列方案的信心。
- 「Finder 层叠在角落」「VS Code 占左 60%」都应该是这里学出来的，不要写成规则。

### 3.3 排列算法

1. 确定情境：当前聚焦窗口所在的簇；没有簇就按当前显示器上可见窗口的 App 类别兜底。
2. 收集该情境的窗口：辅助功能读所有 App 的 `kAXWindowsAttribute`（只取标准、可移动、未最小化的）；Chrome 窗口从扩展拿 `chrome.windows` 列表，和 AX 窗口按标题 + 位置对应。
3. 每个窗口的候选槽位 = 摆放偏好的预测位置；无偏好的窗口按类别先验给默认区域。
4. 无重叠分配：窗口数通常 ≤ 10，匈牙利算法或贪心都行，目标函数 = 偏好匹配度之和，约束 = 不重叠、不超出屏幕、满足 `kAXMinimumSize`。
5. 不属于情境的窗口：按学到的习惯留在原处、最小化或移到另一块屏幕；默认留在原处。
6. 执行：先改大小再改位置，避免闪动；多个窗口并行下发；Chrome 窗口走 `chrome.windows.update(bounds)`。
7. 记录本次方案和每个窗口的实际结果，供 3.2 学习。

### 3.4 标签拆分（依赖 0.2 的扩展）

- 判断相关：同域名、标题里出现同一个项目名（和 VS Code/终端窗口标题对得上）、同情境里常一起看。
- 执行：`chrome.windows.create({tabId, left, top, width, height})` 拆出来，并入第 3.3 步。
- 可选：macOS 26+ 用 Foundation Models 按标题语义分组；没有就退回规则。

### 3.5 快捷键与菜单

- 新增动作 `smartArrange`，默认 ⌃⌥⌘A（或由用户改）。加到 `WindowAction` 时注意 `SettingsView` 和菜单里的列表。
- 菜单栏加「智能排列」一项；活动面板里每次排列一条记录，可一键撤销（恢复所有窗口到排列前的位置，用 `WindowController` 的撤销栈扩展成多窗口快照）。

## 4. 约束

- 快捷键到窗口动起来，我们这边 ≤ 50 毫秒；8 个窗口 ≤ 300 毫秒。被移动 App 的响应时间不算。
- 常驻内存 ≤ 10 MB，空闲零唤醒：不轮询，全部靠通知和观察者。
- 默认不联网。排列决策纯本地；只有标签语义分组可用本机模型。
- 辅助功能权限是唯一需要的权限，不新增。
- 窗口标题属于隐私数据，只在内存里用。

## 5. 完成标准

- 单测：共现图聚类、偏好直方图、分配算法各有基于回放日志的测试。
- 实测：排列后 10 秒内被用户手动调整的窗口比例，连续两周下降。
- 每次排列可撤销，撤销后位置和排列前完全一致。
- 性能预算全部达标，用 `footprint` 和计时日志给出数字。

## 6. 相关决定（已定，不要重新讨论）

- Bundle id `xyz.alvumo.ModernSpectacle`；任何标识符里不出现用户姓名。
- 只用 AppKit，不用 SwiftUI。
- Chrome 的一切通过我们自己的扩展，不用 AppleScript 和「自动化」权限。
- 仓库：`master` 推到用户的 fork（remote `modenl`），绝不推 `origin`（原作者的归档仓库）。提交和推送要用户明确要求。
- 发布：`CODE_SIGN_IDENTITY="Developer ID Application: <your name> (7MH8YWVA8U)" ARCHS="arm64 x86_64" ModernSpectacle/build-app.sh`，然后打 dmg、签名、`xcrun notarytool submit --keychain-profile notary --wait`、`stapler staple`、`spctl` 检查，再用 `publish.mjs` 发布。商店页文案在 `store/description.txt`，图标源文件在 `Resources/AppIcon.png`。

## 7. 待确认

- 默认布局先验：编程类左 60%、浏览器右 40%、Finder 右下角层叠。用户上次没有回答，先按这个做，让学习覆盖它。
- 智能排列的默认快捷键。
- 是否在切换情境时自动排列（默认关，只在快捷键时排）。
