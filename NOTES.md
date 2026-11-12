# NOTES

只保存已验证事实；当前执行状态与结果见 HANDOFF。

- 2026-11-12：Flutter内存压力通知在常规图片缓存清理后才到observer；缓存数字是清理后的快照，live images可能仍被widget持有。按原节流后采集固定非负整数，采样失败保留警告，不能据此断言OOM。

- FlutterError 与 PlatformDispatcher 是不同来源；root onError 不自动接收 child isolate 错误。SDK 不创建新 zone，保留原处理器与返回值；child 需显式注册，且在 resume 前建立监听。
- 2026-11-10：队列记录直接持有输入 Map 会使缓存与已写 JSON 不一致；追加时冻结 JSON 快照。队列路径是目录/链接时必须判为不可读，保留源而不覆盖。
- 2026-11-10：NavigatorObserver.didRemove/didReplace 可针对后台 route，previousRoute 不能直接当可见界面；记录顶层 route，仅顶层变化才更新 screen。
- 2026-11-10：capture和Redactor各自先截断，会让长JWT失去三段结构并残留到队列；现在预算内先清洗原始栈及extras键值，后截断并解析frames。超扫描预算保留完整行、丢掉截口行；转义引号不能结束密码匹配。跨SDK纯假数据fixture用于守住安全与源码标识可读性。
