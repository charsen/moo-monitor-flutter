# Flutter 监控接入记录

本轮新建独立 SDK，并接入同级 Flutter host；共用现有反馈 token，不变更宿主版本。三仓实现使用任务分支 `feat-monitor-flutter`，提交与本地合并状态以 Git 引用为准；本轮不含推送。原生 SDK 仓仅作参考，没有修改。

## 已实现

- FlutterError、root isolate、显式 capture、暂停启动的 child isolate 转发；保留原处理器/返回值，不新增 zone。自动入口和光语使用固定消息，不上传业务错误描述。
- Android/iOS 实际平台、独立随机安装身份的 SHA-256、进程会话 ID、白名单设备字段、静态屏幕与低内存警告。第三方包不会误标记为 app code。
- 200 条/2MB 队列、同步落盘与原子轮转、不可变 JSON 快照和逐行确认；50 条/512KB 批次，超过三批继续让出事件循环后发送。
- HTTP 跳转/cookie/认证隔离，响应 128KB 上限；逐条完整回执、部分补发、身份范围撤权、跨启动 Retry-After、进程六次退避预算、关闭时取消网络/定时器。
- 节点/深度/容器/UTF-8/JSON 总预算脱敏，未知 extras 不执行 toString；保留 dropped 与 runtime/source 等诊断元数据。移除后台 route 不改变可见 screen。
- 光语 CoreBootstrap 复用原入口，SDK 不重复安装错误钩子；反馈与监控只读 ClientBuildConfig.token，默认生产 Release 启用。三份 lock 只增加 sibling SDK，没有升级已有依赖。

## 已执行验证

| 范围 | 实际结果 | 日志 |
|---|---|---|
| SDK 全量 | 32 项通过 | `/tmp/moo-monitor-flutter-tests-final-verified.log` |
| SDK 全包 analyze | 无问题；排除 ignored build 快照 | `/tmp/moo-monitor-flutter-analyze-final-verified.log` |
| host core 全量 | 39 项通过 | `/tmp/light-monitor-core-tests.log` |
| host 最终监控定向 | 3 项通过 | `/tmp/light-monitor-host-final-focused.log` |
| host runner 全量 | 2 项通过 | `/tmp/light-monitor-runner-tests.log` |
| host light 全量 | 242 通过、2 跳过、19 失败 | `/tmp/light-monitor-light-tests.log` |
| 原始 HEAD 隔离 light 全量 | 同样 242 通过、2 跳过、19 失败，失败集合完全相同 | `/tmp/light-monitor-baseline-tests.log` |
| host 源码/测试 analyze | core、light、runner 的 lib/test 无问题；core 最终复核亦通过 | `/tmp/light-monitor-analyze-final.log`、`/tmp/light-monitor-core-analyze-reviewed.log` |
| token 工具 | 5 项通过，含权限0600、不覆盖文件、平台选择、保留其它define、参数/日志不含明文 | `/tmp/light-monitor-token-tests-complete.log` |
| 真正 Gradle 属性传播 | 用已有8.14.3 + fake token验证通过，未执行Android构建 | `/tmp/light-monitor-gradle-property.log` |
| cloud AppErrorIntakeTest | 20 项 / 187 断言通过；Pint通过 | `/tmp/flutter-monitor-cloud-tests.log` |

SDK 包括真实 loopback HTTP、实际 child isolate、错误处理链、无 binding/写失败、坏行/容量/轮转、部分回执、401换token、429跨启动、503跨三次重启与预算用例。初次两条 store 回归分别暴露输入 Map 漂移、目录源误判，修复后通过；测试编译入口遗漏 foundation import 也已修正，没有将失败当作通过。

原始日志、既有失败清单及从实际输出核对的 `summary.json` 已归档到 ignored `build/review/`；不把构建缓存或测试凭据提交到 Git。

本机实际 Android/iOS 共享凭据已分别写入私有临时 JSON、在内存核对单一 FEEDBACK_TOKEN 和权限后删除，明文不输出，不发送真实请求。服务端真实 token 的线上能力/部署状态未探测。

## 既有失败与基线

host 原始 HEAD 为 `f545959`；在 ignored `build/host-baseline/` 导出其 core/ui/light/third_party，离线解析原 lock，运行同一 Flutter SDK `3.41.10-ohos-1.0.1` / Dart `3.11.5`。原始运行源码和 feature lock 已与 HEAD 回读比对，未修改断言。

19 项失败分布为 `co_reading_comments_test.dart` 5 项、`co_reading_create_test.dart` 1 项、`co_reading_group_actions_test.dart` 8 项、`co_reading_group_page_test.dart` 5 项，包含共读横向溢出和相关断言。当前/基线失败清单为 `/tmp/light-monitor-{light,baseline}-failures.json`，集合相同。未修改这些页面或测试，不宣称 host 全量全绿；待办已记录到 host TODOS。

初次直接对 host 包目录做 dart analyze 还扫描到历史 ignored runner/build 预览文件的32条info；最终对三个包的完整源码和测试目录运行 flutter analyze，无问题，未改历史预览文件。

## 交付与边界

新 SDK 初始版本0.1.0；host 保持0.0.3+9，没有新 APK/IPA、签名/安装/上传/部署或 Git 远端创建。Git 本地交付状态以分支实际引用为准，不含推送。cloud 本轮只改契约文档和测试，未改生产处理代码。构建工具和接线见 [host说明](../light-language-frontend/docs/APP-MONITOR.md) 与 [BUILD](../light-language-frontend/docs/BUILD.md)。

未执行设备/E2E、原生Java/NSException/信号、ANR、实际OOM/watchdog、AOT混淆还原、长后台调度；Application Support备份排除仍需原生适配。公开 API 不能替代这些未实现能力，后续事项见 [TODOS](TODOS.md)。
