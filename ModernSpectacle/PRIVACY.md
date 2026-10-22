# Modern Spectacle Privacy Policy

Last updated: October 23, 2026

The developer of Modern Spectacle does not collect, store, sell or share your data. The only data that leaves your Mac is what Smart Arrange sends to TypeSafe for ranking, described below.

- **Window information.** To arrange windows, the app reads the names of open apps and the titles and positions of their windows through the macOS Accessibility API. Each time you press Smart Arrange, the app sends the app names, window titles and recent window switches to TypeSafe's API (api.typesafe.ai), whose Jev model decides which windows matter; window positions are not sent, and nothing is sent when you do not press it. Builds without a TypeSafe key (none built in and none entered in Settings) send nothing and rank windows on your Mac. A key you enter is kept in your macOS Keychain.
- **Local files.** Your saved layouts, layout preferences and a short activity log are kept in the app's own folder on your Mac. Deleting the app deletes them.
- **Update check.** Once a day the app asks the developer's store whether a newer version exists; that request sends only the app's version number, and it can be turned off in Settings.
- **No analytics, advertising or tracking.**

Questions: open an issue at https://github.com/modenl/spectacle/issues.

---

# Modern Spectacle 隐私政策

更新日期：2026 年 10 月 23 日

Modern Spectacle 的开发者不收集、不保存、不出售、不分享你的数据。唯一离开你 Mac 的数据，是智能排列发给 TypeSafe 用于排序的内容，见下文。

- **窗口信息。** 为了排列窗口，应用通过 macOS 辅助功能接口读取已打开应用的名称，以及窗口的标题和位置。每次按智能排列时，应用会把应用名、窗口标题和最近的窗口切换发给 TypeSafe 的接口（api.typesafe.ai），由它的 Jev 模型判断哪些窗口重要；窗口位置不发送，不按快捷键时什么都不发送。没有 TypeSafe Key 的版本（既没有内置、设置里也没填）不发送任何内容，在本机排序。你填的 Key 保存在 macOS 钥匙串里。
- **本地文件。** 保存的布局、布局偏好和简短的运行日志保存在应用自己的文件夹里，删除应用即一并删除。
- **更新检查。** 应用每天向开发者的商店检查一次是否有新版本，请求里只有版本号，可以在设置里关闭。
- **没有统计、广告或追踪。**

问题请在 https://github.com/modenl/spectacle/issues 提出。
