# 交接：ModernSpectacle 当前任务

最后更新：2026-11-17。商店上的最新版本是 **0.3.10**：在 0.3.9（背景窗口不动、按 App 叠放）的基础上，看得见的窗口重新有滑动动画。两者都已在本机屏幕上测过（见下面「屏幕测试结果」）。

## 0.3.10：可见窗口滑到目标位置

文件：`SmartArranger.swift` 里的 `move(_:slide:)`。

- 只有看得见的窗口有动画，背景窗口照旧不动；打开「减少动态效果」时没有动画，直接到位。
- 时长 `slideDuration` = 0.25 秒，ease-out。滑动途中**只改位置**：会缩小的窗口先缩小再滑，会变大的落位后再放大。原因：每步都改大小时，iTerm2 这类 App 每次都要重新排版，一次排列只走 1 步，等于跳过去；只改位置时，每个 App 都能走 10 步以上。
- 按时间插值：慢的 App 步数少、步子大，不会拖慢整体；最后一步一定精确落到目标上。
- 一个 App 的几个窗口一起滑，不同 App 并行。

### 屏幕测试结果（2026-11-17，本机，DEV_HOOKS 构建）

- 用 CGWindowList 每 8 ms 采样：Claude 窗口在约 215 ms 内走了 13 步，Chrome 只变大小、没有位置变化，一次到位。
- 叠放顺序正确：`stackcheck` 报的「covered」都来自**不能缩到格子大小的窗口**（System Settings 宽度固定 740、最小高度 624；zoom.us 最小高度 650），它们超出自己的格子，压到相邻格子，或露出后面的窗口。这是排版适配的问题，不是叠放问题，0.3.9 之前就有。可以作为后续任务：给这类窗口的最小尺寸找个合适的格子，或把它们放到后面。

## 任务 1（已发布 0.3.9，已在屏幕上验证）：排列不再一个个画窗口，背景窗口不动

### 改了什么（已在 0.3.9 发布）

文件：`Sources/ModernSpectacleServices/SmartArranger.swift`、`Sources/ModernSpectacleServices/AccessibilityClient.swift`

1. **背景窗口原地不动**（`placementsToApply`）：被藏在后面的窗口（placement 的 group 是 `"behind"`）不再移动、不再改大小，也不再被提到前面。瓦片铺满整块屏幕，所以它们在哪里都看不见。以前排列完、预览淡出后，还要把它们一个个拉成全屏。
2. **按 App 叠放，不再按窗口**（`restack`）：每个有瓦片的 App 只被提到前面一次，背靠背进行，焦点窗口所在的 App 最后。只有背景窗口的 App 不会被提到前面，所以留在下面。以前是每个窗口（包括背景窗口）依次 raise 并把整个 App 设为 frontmost，每次停 30 ms，看起来就是一个个画出来。
3. **保留之前修过的 Chrome 多窗口 bug 的处理**：同一个 App 既有瓦片又有背景窗口时（比如两个 Chrome 窗口），背景那个仍然移到自己 App 的瓦片正下方（`LayoutDesign.swift` 里的 `tileOfApp`），并在 App 内先 raise 背景、后 raise 瓦片。原因：把 App 设为 frontmost 会把它的**所有**窗口带到前面，全屏的背景窗口会盖住别的 App 的瓦片（0.3.7 修的就是这个）。
4. **学习不被污染**：`watchForCorrections` 跳过 `"behind"` 窗口。它们不再在计划的位置上，否则会被当成用户手动挪了窗口。
5. 新日志：`stacked N app(s) in X ms`，在 `~/Library/Application Support/ModernSpectacle/status.log`。

单元测试 63 个全过，发布流程完整跑通（公证、Gatekeeper、Sparkle 签名）。**没有在真实屏幕上测过**：用户决定直接发布。如果用户报告窗口被盖住、或排列后窗口叠放不对，先按下面的步骤测。

### 要做的测试

1. 打开**两个 Chrome 窗口**，再加几个别的 App（编辑器、终端、Notes 等），都在主屏上。
2. 构建带调试接口的版本并启动（会写 `last-arrangement.json`，并开启 `spectacle-cli trigger`）：
   ```bash
   cd ModernSpectacle && DEV_HOOKS=1 ARCHS=arm64 ./build-app.sh && open dist/ModernSpectacle.app
   ```
3. 跑 5 次排列，覆盖每个模版。每次后运行叠放检查：
   ```bash
   CLI=$(swift build -c release --product spectacle-cli >/dev/null && swift build -c release --show-bin-path)/spectacle-cli
   $CLI trigger press; sleep 1.5; $CLI trigger release; sleep 3; swift Scripts/stackcheck.swift
   $CLI trigger press; sleep 1.5; $CLI trigger press; sleep 0.6; $CLI trigger release; sleep 3; swift Scripts/stackcheck.swift   # 切到下一个模版，重复 3 次
   ```
4. **通过标准**：
   - 每次 `stackcheck` 都输出 `STACKING OK`：每个瓦片中心和四角最上面的窗口都是它自己的 App，没有背景窗口、第二个 Chrome 窗口或全屏窗口盖在任何瓦片上。
   - 至少有一次排列里，一个 Chrome 窗口是瓦片、另一个是 hidden（`stackcheck` 输出里的 `hidden:` 一栏），那一次也必须 OK。
   - `status.log` 里 `apply:` 显示 `hidden left in place`，`stacked … in X ms` 明显小于以前（以前是窗口数 × 30 ms 以上）。
   - 肉眼看：松开按键后窗口一次到位，不再一个个出现。
5. 失败时：看 `status.log` 和 `last-arrangement.json`，修好再测。注意：在 macOS 上，把 App 设为 frontmost 会带上它所有窗口，这是 Chrome bug 的根源。

### 下一次发布（0.3.11 及以后）

```bash
cd ModernSpectacle
# 把 build-app.sh 里的 VERSION 改成新版本号
./release.sh                         # 构建、Developer ID 签名、公证、staple，打印 dmg 路径
SPARKLE_SIGN_UPDATE=$PWD/.build/artifacts/sparkle/Sparkle/bin/sign_update \
  node ~/.config/webstore/publish.mjs modern-spectacle <版本> dist/ModernSpectacle-<版本>-universal.dmg \
  --sparkle --notes-file <中英双语发布说明>
```
然后检查 appcast 里新版本有 `sparkle:edSignature`，再提交并推送版本号改动。

## 换到另一台 Mac 需要先准备

这些都不在仓库里，也不能放进仓库：

| 需要 | 怎么准备 |
|---|---|
| 提交身份 | `git config --global user.name moden` 和 `git config --global user.email 1688563+modenl@users.noreply.github.com`（GitHub 上不能出现个人姓名） |
| Developer ID Application 证书 | 从原来那台 Mac 的钥匙串导出 .p12 再导入，或在 Xcode → Settings → Accounts → Manage Certificates 新建 |
| 公证凭据 | `xcrun notarytool store-credentials modernspectacle`（Apple ID + App 专用密码 + Team ID 7MH8YWVA8U，由用户自己输入）。公证要求 Mac 处于解锁状态 |
| **Sparkle 签名私钥** | **只在原来那台 Mac 的钥匙串里。** 在原机运行 `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <文件>` 导出，在新机运行 `generate_keys -f <文件>` 导入，然后删除这个文件。没有它，已安装的 App 不会接受新版本。不要换新密钥：Info.plist 里的 `SUPublicEDKey` 必须保持不变 |
| 商店发布权限 | 按 https://store.alvumo.xyz/agent.md 下载 `publish.mjs` 并运行 `login`，由用户用 passkey 批准 |
| `ModernSpectacle/jev.key` | 内置的 Jev（TypeSafe）API Key，已在 .gitignore 里。从原机安全地拷过来，或在 TypeSafe 控制台新建。没有它，排序会退回本机规则 |
| 辅助功能权限 | 第一次运行时在 系统设置 → 隐私与安全性 → 辅助功能 里打开 ModernSpectacle |

## 固定规则

- GitHub 上不能出现个人姓名：文件内容、提交作者和提交者都不行。推送前用 `git log --format='%an %ae %cn %ce'` 和 `git grep -i <姓名>` 检查。
- 改动做完并测试通过后直接发布到商店（`--sparkle`），不用问。
- 发布说明写中英双语。
- `DEV_HOOKS=1` 构建只用于测试，绝不发布：它让任何本地进程都能借用本 App 的辅助功能权限。

## 关键位置

- 构建：`build-app.sh`（打包 Sparkle、jev.key、签名）；发布：`release.sh`（dmg、公证、staple、Gatekeeper 检查）。
- 排列流程：`SmartArranger.swift`。按下热键出预览（`beginPreview`），松开全部修饰键后应用（`commitPreview` → `apply` → `settle` → `restack`）。
- 模版：`LayoutScheme.swift` 里的内置 JSON；填充和背景窗口位置：`LayoutTemplates.swift`、`LayoutDesign.swift`。
- 排序：`JevRanker.swift`（Jev，约 0.2 秒）；没有 Key 或超时时用本机的 `LocalRanker`。
- 自动更新：`Updater.swift`（Sparkle，appcast 在 store.alvumo.xyz/app/modern-spectacle/appcast.xml）。
