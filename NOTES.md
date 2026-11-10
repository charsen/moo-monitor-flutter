# NOTES

只保存已验证事实；当前执行状态与结果见 HANDOFF。

- FlutterError 与 PlatformDispatcher 是不同来源；root onError 不自动接收 child isolate 错误。SDK 不创建新 zone，保留原处理器与返回值；child 需显式注册，且在 resume 前建立监听。
- 2026-11-10：队列记录直接持有输入 Map 会使缓存与已写 JSON 不一致；追加时冻结 JSON 快照。队列路径是目录/链接时必须判为不可读，保留源而不覆盖。
- 2026-11-10：NavigatorObserver.didRemove/didReplace 可针对后台 route，previousRoute 不能直接当可见界面；记录顶层 route，仅顶层变化才更新 screen。
