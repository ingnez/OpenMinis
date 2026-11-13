# MinisWatchWidgets

Watch App 通过目标依赖构建并嵌入这个 WidgetKit 扩展；iOS 出包流程再嵌入完整 Watch App。两个 @main 分别属于独立目标。

Watch App 收到配对手机的状态后，写入手表自己的 App Group 并刷新时间线。小组件点按打开实际任务状态页，暂停与审批经 WatchConnectivity 发给手机，手机核验当前任务标识及锁定状态后调用 Agent；只有手机确认成功才显示成功。

构建检查包含 Watch App 和小组件；配对、表盘刷新与签名安装仍需真机验收。App 与扩展都需要 group.com.openminis.app 权限。
