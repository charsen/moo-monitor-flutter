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

宿主已有统一异常入口时使用 `installHandlers: false` 并调用 `MooMonitor.capture(error, stack, message: '固定诊断描述', source: 'flutter_framework')`，避免重复上报。默认钩子保留 Flutter/PlatformDispatcher 原处理链与返回值，不创建新 zone。子 isolate 在 paused 启动后用 `observeIsolate` 注册，再 resume；结束时 `stopObservingIsolate`。

只支持实际 `android` / `ios` 平台，不把 Flutter 当 OS。框架、root/child isolate 异常记为 `handled`；低内存警告单独记录，不宣称进程崩溃、OOM 或原生信号已捕获。原生 Java/NSException/信号适配另见 [TODOS](TODOS.md)。

token 只用于项目与能力认证。SDK 每条记录携带 `MonitorConfig.platform`；光语接线从手机运行环境自动识别并填写该字段，后端按字段校验/存储平台，不从 token 推断 OS。构建读取统一 Flutter 共享凭据，详见 [host接线](../light-language-frontend/docs/APP-MONITOR.md)。

默认自动入口使用固定消息，保留异常类型与栈；显式 capture 应传可公开的固定诊断描述。`inAppPackages` 由宿主列出自己的 Dart 包，仅这些包标记 `frames.app=true`，不把第三方依赖猜作应用代码。

空 token 不安装、不读写目录、不联网。首次安装/运行需宿主已初始化 binding。只传固定 screen 标识，不传路由参数、书名、内容、账号或凭据。消息模式脱敏不等于理解任意自然语言，宿主应传固定诊断描述。

详见 [设计](docs/design.md)、[验证记录](HANDOFF.md)；移动上报唯一契约在同级 `moo-scaffold-cloud/docs/app-monitor.md`。源码同时维护于 [Gitee](https://gitee.com/charsen/moo-monitor-flutter)（需仓库访问权限）和 [GitHub](https://github.com/charsen/moo-monitor-flutter)，同一分支直接推送到两端；不发布到 pub.dev，host 使用 sibling path 依赖。
