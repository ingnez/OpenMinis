# MinisWatchWidgets（单独 scheme，不进主 IPA）

表盘小组件源码在这里：当前 Bot 步骤、剩余步数，点按打开状态页可暂停/批准。

**没有把这个扩展挂进 Minis 或 MinisWatch 目标**，也还没有写入 `project.pbxproj` 的依赖，以免主工程 `xcodebuild -scheme Minis` 和 `-target MinisWatch` 的出包任务因第二个 `@main` / 手表扩展签名失败。

要在 Mac 上真正装到表盘：

1. 用 Xcode 增加 watchOS Widget Extension 目标，名字 `MinisWatchWidgets`，指向本目录。
2. 不要把它设成 Minis 的依赖；只作为 MinisWatch 的可选嵌入，或只用 `MinisWatchWidgets` scheme 单独编。
3. 主 IPA 流水线保持只编 `Minis` / 单独编 `MinisWatch`。

文案和按钮的验收走 App 里「手表表盘小组件」预览页和 Linux 上的 `WatchComplicationTests`。
