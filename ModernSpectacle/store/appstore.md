# Mac App Store listing

Copy these into App Store Connect. Limits are App Store Connect's.

## App information

- Bundle ID: `xyz.alvumo.ModernSpectacle`
- SKU: `modern-spectacle`
- Primary category: Productivity. Secondary: Utilities.
- Price: Free
- Privacy policy URL: https://github.com/modenl/spectacle/blob/master/ModernSpectacle/PRIVACY.md (live once this branch is merged into master)
- Support URL: https://github.com/modenl/spectacle/issues
- Copyright: 2026 Alvumo
- App Privacy ("nutrition label"): Data Not Collected
- Export compliance: no non-exempt encryption (`ITSAppUsesNonExemptEncryption` is false)
- Age rating: 4+, no restricted content

## English (primary)

Name (30): Modern Spectacle

Subtitle (30): Smart window layouts, one key

Promotional text (170):
Press ⌃⌥⌘M and every window on the screen falls into a clean layout built around what you are doing now. Ranked on your Mac by Apple Intelligence; nothing leaves it.

Keywords (100):
window manager,tile,tiling,snap,layout,arrange,split screen,keyboard,ultrawide,spectacle,productivity

Description (4000):
Modern Spectacle arranges your windows with one shortcut. It looks at what you are working on, puts that window in the main spot, the windows your task needs next to it, and the ones you only keep an eye on (chat, mail) where you can still see them. Everything else waits neatly behind. It also keeps every classic Spectacle shortcut for halves, corners, thirds and moving between displays.

SMART ARRANGE
• Press ⌃⌥⌘M (hold ⌃⌥⌘ with the left hand, press M with the right). A small preview shows the layout; let go to apply, Esc to cancel.
• Keep holding and press M again to switch between three layouts for the display: laptop, standard monitor or ultrawide.
• Only the display you are working on is arranged.
• Bring to Main (⌃⌥⌘↩) swaps the current window into the main spot instantly.
• Save a layout from the menu and restore it with ⌃⌥⌘1…9.

PRIVATE BY DESIGN
• Windows are ranked by Apple's on-device model (Apple Intelligence). Window titles never leave your Mac, there is no account and no API key, and the app makes no network connections.
• Without Apple Intelligence, windows are ranked by focus and recent use.
• Nothing runs in the background: the app does work only when you press a shortcut.

WHY THESE LAYOUTS
Each rule comes from human-computer interaction research: the main task in the center of view (Bi & Balakrishnan, CHI 2009), task windows tiled rather than overlapping (Kandogan & Shneiderman, CHI 1997), peripheral windows kept visible (Hutchings & Stasko, GI 2004), and layouts that stay where you left them so spatial memory still works (Scarr, Cockburn & Gutwin).

CLASSIC SHORTCUTS
⌥⌘←/→/↑/↓ halves, ⌃⌘←/→ and ⌃⇧⌘←/→ corners, ⌥⌘C center, ⌥⌘F maximize, ⌃⌥←/→ thirds, ⌃⌥⌘←/→ next display, ⌃⌥⇧←/→ larger and smaller, ⌥⌘Z undo. Every shortcut can be changed in Settings.

REQUIREMENTS
macOS 14 or later. Ranking with Apple Intelligence needs a Mac with Apple silicon, macOS 26 or later, and Apple Intelligence turned on. Modern Spectacle needs Accessibility permission to move other apps' windows; it asks the first time.

Modern Spectacle is based on Spectacle by Eric Czarny (MIT License).

## 简体中文

名称：Modern Spectacle

副标题：一键智能排列窗口

宣传文本：
按 ⌃⌥⌘M，屏幕上的窗口按你此刻在做的事排好。Apple Intelligence 在本机判断哪些窗口重要，什么都不离开你的 Mac。

关键词：
窗口管理,分屏,平铺,布局,排列,快捷键,超宽屏,多窗口,效率,spectacle

描述：
Modern Spectacle 用一个快捷键排好所有窗口。它看你正在做什么：当前窗口放在主位，任务需要的窗口放在旁边，聊天、邮件这类只需留意的放在看得见的地方，其余整齐地放在后面。经典 Spectacle 的半屏、四角、三分之一、跨屏快捷键也都保留。

智能排列
• 按 ⌃⌥⌘M（左手按住 ⌃⌥⌘，右手按 M），小窗口预览布局，松手生效，Esc 取消。
• 不松手再按 M，在三种布局之间切换，笔记本、普通显示器、超宽屏各有一套。
• 只排列你正在用的这块屏幕。
• 移到主位（⌃⌥⌘↩）把当前窗口立刻换到主位。
• 在菜单里保存布局，用 ⌃⌥⌘1…9 恢复。

隐私
• 窗口由 Apple 本机模型（Apple Intelligence）排序，窗口标题不会离开你的 Mac，不需要账号或 API Key，应用不联网。
• 没有 Apple Intelligence 时按焦点和最近使用排序。
• 不在后台运行任何计算，只在你按快捷键时才工作。

为什么这样排
每条规则都来自人机交互研究：主任务放在视线中央（Bi 与 Balakrishnan，CHI 2009），任务窗口平铺而不重叠（Kandogan 与 Shneiderman，CHI 1997），外围窗口保持可见（Hutchings 与 Stasko，GI 2004），布局不乱动以保留空间记忆（Scarr、Cockburn 与 Gutwin）。

经典快捷键
⌥⌘←/→/↑/↓ 半屏，⌃⌘←/→、⌃⇧⌘←/→ 四角，⌥⌘C 居中，⌥⌘F 最大化，⌃⌥←/→ 三分之一，⌃⌥⌘←/→ 跨屏，⌃⌥⇧←/→ 放大缩小，⌥⌘Z 撤销。所有快捷键都能在设置里修改。

系统要求
macOS 14 或更高版本。用 Apple Intelligence 排序需要 Apple 芯片、macOS 26 或更高版本，并打开 Apple Intelligence。移动其他应用的窗口需要辅助功能权限，第一次使用时会提示。

Modern Spectacle 基于 Eric Czarny 的 Spectacle（MIT 许可）。

## Notes for App Review

Modern Spectacle is a window manager. It uses the macOS Accessibility API (AXUIElement) only to read the position, size and title of other apps' windows and to move and resize them when the user presses one of its shortcuts. It does not read window contents, does not use the network, and runs no background work.

To test:
1. Launch the app (it lives in the menu bar). Open System Settings → Privacy & Security → Accessibility and turn on Modern Spectacle.
2. Open two or three windows (for example Safari, Notes and Terminal).
3. Hold Control-Option-Command and press M: a small preview appears. Release the keys to arrange the windows. Press M again while holding the keys to switch layouts; Esc cancels.
4. Control-Option-Command-Return moves the front window into the main spot. Option-Command-Left/Right puts a window on the left or right half.

Apple Intelligence is optional; without it, windows are ranked by focus and recent use.

## Screenshots

Mac screenshots must be 1280×800, 1440×900, 2560×1600 or 2880×1800 (16:10). Suggested set:
1. A messy desktop next to the same desktop after ⌃⌥⌘M.
2. The preview while ⌃⌥⌘ is held.
3. An ultrawide layout (main in the middle, chat on the right).
4. Settings with the shortcut recorder.
