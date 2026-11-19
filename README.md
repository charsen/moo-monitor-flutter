# moo-monitor-flutter

Flutter Android/iOS 的 Dart 异常采集与持久补传。同一个 Flutter App 的 Android/iOS 反馈与监控共用同一枚客户端 token，具备 `feedback`、`app_errors` 能力。

```dart
WidgetsFlutterBinding.ensureInitialized();
await MooMonitor.install(MonitorConfig(
  token: const String.fromEnvironment('FEEDBACK_TOKEN'),
  app: 'example-app', platform: Platform.isIOS ? 'ios' : 'android',
  release: '1.0.0', build: '1',
  inAppPackages: const {'example'},
));
runApp(const App());
```

> SDK 只在 Android / iOS 安装；Web、桌面不会安装。宿主不要把 `Platform.isIOS` 之类的直接判断放到 Web 会执行的路径上（可用 `kIsWeb` 先拦）。

宿主已有统一异常入口时使用 `installHandlers: false` 并调用 `MooMonitor.capture(error, stack, message: '固定诊断描述', source: 'flutter_framework')`，避免重复上报。默认钩子保留 Flutter/PlatformDispatcher 原处理链与返回值，不创建新 zone。子 isolate 在 paused 启动后用 `observeIsolate` 注册，再 resume；结束时 `stopObservingIsolate`。

只支持实际 `android` / `ios` 平台，不把 Flutter 当 OS。框架、root/child isolate 异常记为 `handled`；低内存警告单独记录，不宣称进程崩溃、OOM 或原生信号已捕获。原生 Java/NSException/信号适配另见 [TODOS](TODOS.md)。

token 只用于项目与能力认证。SDK 每条记录携带 `MonitorConfig.platform`；光语接线从手机运行环境自动识别并填写该字段，后端按字段校验/存储平台，不从 token 推断 OS。构建读取统一 Flutter 共享凭据，详见 [host接线](../light-language-frontend/docs/APP-MONITOR.md)。

默认自动入口使用固定消息，保留异常类型与栈；显式 capture 应传可公开的固定诊断描述。`inAppPackages` 由宿主列出自己的 Dart 包，仅这些包标记 `frames.app=true`，不把第三方依赖猜作应用代码。

空 token 不安装、不读写目录、不联网。首次安装/运行需宿主已初始化 binding。只传固定 screen 标识，不传路由参数、书名、内容、账号或凭据。消息模式脱敏不等于理解任意自然语言，宿主应传固定诊断描述。

详见 [设计](docs/design.md)、[验证记录](HANDOFF.md)；移动上报唯一契约在同级 `moo-scaffold-cloud/docs/app-monitor.md`。源码同时维护于 [Gitee](https://gitee.com/charsen/moo-monitor-flutter) 和 [GitHub](https://github.com/charsen/moo-monitor-flutter)，两端均为公开仓库，同一分支直接推送到两端；不发布到 pub.dev，host 使用 sibling path 依赖。

新增可选配置：`detectUncleanExit`（默认 false；宿主开启后在“上次带内存警告且未干净退出”时上报 `UncleanExit`）、`memorySampleLimit`（默认 8）、`symbolId`（AOT 符号化标识，写入 `context.symbol_id`）。低内存事件额外携带 `warnings_in_session` 与有界 `memory_samples` 序列。

原生事件转发：宿主原生层（MetricKit/信号/Java/NSException）捕获后调用 `MooMonitor.captureNative(kind:..., name:..., message:..., extras:...)` 交给本 SDK 上报；本 SDK 不安装原生处理器。

## 原生事件通道（MethodChannel）

原生插件捕获（崩溃/ANR/信号）后可经 MethodChannel 转发：方法名 `captureNative`，参数 `{kind, name, message?, source?, extras?}`（kind: crash/anr/hang/handled/termination/webview_gone）。宿主在 install 后调用 `MooMonitor.bindNativeChannel(channel)` 绑定。SDK 只解析、脱敏、有界化与投递，不安装任何原生处理器。

## 原生插件骨架（最小）

本包现为 Flutter 插件：iOS `MooMonitorFlutterPlugin`（未捕获 ObjC 异常写入 Application Support 待发文件）与 Android `MooMonitorFlutterPlugin`（包装默认 UncaughtExceptionHandler 写 filesDir 待发文件）在 native 侧记录，Dart 绑定 `moo_monitor/native` 通道并调用 `flushPending` 回放。宿主示例：`MooMonitor.bindNativeChannel(MethodChannel('moo_monitor/native'))` 后 `invokeMethod('flushPending')`。信号/MetricKit/NDK/ANR 仍为 TODO，不得宣称已覆盖原生崩溃。

## AOT 符号上传（tools/upload-symbols.sh）

Flutter 用 `flutter build ipa --split-debug-info=<dir>` 产出 AOT 符号目录后，用本仓 `tools/upload-symbols.sh` 上传到 Cloud 符号库，供崩溃栈符号化。符号上传是「monitor SDK + cloud」配套能力：不接本 SDK、不用 Cloud 的 App 不需要它。

```bash
MONITOR_TOKEN=<具备 app_errors 或 app_symbols 能力的 token> \
  tools/upload-symbols.sh <symbols 目录> <release> <build> [endpoint]
```

三步直传（cloud 只签票据、文件本体直达七牛、不经 cloud）：1) `POST /api/v1/uploads/tickets` 取票据；2) multipart 直传七牛；3) `POST /api/v1/uploads/{upload_id}/confirm` 核验落盘。契约（`business=app_symbols`、`kind=flutter`）见 `moo-scaffold-cloud/docs/QINIU-DIRECT-UPLOAD.md`。宿主在自己的发布流程里按 sibling 路径直接调用本脚本（与 iOS/Android 的 `upload-dsyms.sh` / `upload-mapping.mjs` 同构），本仓不内置任何宿主的 token，token 全程经环境变量传入、不打印。
