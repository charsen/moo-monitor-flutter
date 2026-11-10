# moo-monitor-flutter

- 只公开 MooMonitor、MonitorConfig、MonitorNavigatorObserver；lib/src 为实现。
- 唯一移动上报契约在同级 moo-scaffold-cloud/docs/app-monitor.md，不另建 wire schema。
- Android/iOS 的 Dart/Flutter 异常按实际 OS 上报；不把可恢复框架异常或 isolate 退出当作进程 crash。
- 先落盘再发送，逐条确认不可变收据；撤权保留队列并停采停发。SDK 失败不得抛给宿主。
- 不采集业务内容、原始路由参数、账号、硬件标识、偏好或凭据；未知 extras 不调用 toString。
- 原生信号/Java/NSException 不由 Dart 处理，不宣称已覆盖。未验证项记 TODOS，事实记 NOTES。
- 修改后执行包内 flutter test、flutter analyze；只格式化本次路径。无用户指令不跑设备/E2E。
