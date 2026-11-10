# Flutter 监控实现

## 范围

- Android/iOS root isolate 的 FlutterError、PlatformDispatcher、主动 capture；child isolate 显式转发。
- 自动采集保持原有处理链。框架错误一般可恢复，全部以 handled 记录，不推断进程已经 crash。
- WidgetsBindingObserver 记录 resumed/paused/detached 与低内存警告，inactive 不冒充后台。NavigatorObserver 由宿主把注册的路由映射成固定代码名，不读 arguments。
- 纯 Dart/Flutter 实现，不在本轮改动原生信号处理器或复制原生 SDK；无第三方崩溃/网络库。

## 队列与网络

同一个 Flutter App 在 Android/iOS 共用一枚反馈/监控 token，身份认证与平台分类独立。SDK 按 `MonitorConfig.platform` 写入每条记录；光语宿主自动检测手机运行环境后填 `android` 或 `ios`。反馈同样由客户端检测后发送 `platform`，后端各自校验并入库，不按 token 识别平台。构建的统一入口与标签只在 host BUILD 维护，SDK 不另建按 OS 取凭据的规则。

独立 Application Support 子目录，单个 root isolate 持有。事件同步追加并 flush，普通追加缓存条数/字节；最多 200 条 / 2 MB、单条 256 KB，轮转原子替换并保留较新记录。恢复坏行与半行，读失败不覆盖源；无本地指纹合并。发送冻结原始行收据，只确认对应条目，允许发送期间追加/轮转。计数与丢弃数只反映当前进程可观察范围。

随机 UUID 生成安装身份并 SHA-256；不读取宿主安装身份、IDFA/IDFV/硬件 serial。会话另用 UUID。队列内保留事件原始时间/构建与 event_id，补发不重新标注；服务端去重仍只有有限窗口。

每批 50 条 / 512 KB、单响应 128 KB；超过三批让出事件循环后继续。并发 flush 共用同一 Future。HTTP 不跟随跳转、不使用浏览器 cookie 或登录凭据，使用系统 TLS。请求 15 秒超时并关闭连接。200 必须验证 true 布尔 ok、完整唯一整数 index 和逐条状态；只有终结项确认，其余保留。401/403 保留队列并停止采集/发送，持久标记按 endpoint/app/token 摘要隔离。429 秒数/HTTP 日期保留到期时间；普通失败按 30s/2m/8m/30m 退避，进程内最多六次。没有后台调度插件，不承诺进程退出后自动补发。

## 隐私与栈

先按总节点/深度/条目/字节预算遍历 extras，未知对象不调用 toString；消息、栈、payload 分别限制 8 KB / 32 KB / 8 KB，识别常见凭据、URL、私有路径。screen 只接受代码标识。光语只上报异常类型、Dart 源码栈与固定诊断消息，不发送原业务描述或 Flutter context 文案。

Debug VM 栈可解析 package URI、函数、行列；绝对路径只保留代码文件名。AOT 混淆栈保留脱敏原文，未提供 split-debug-info 符号化，不能伪造源码行号。Web/桌面、原生 crash/ANR、OOM/watchdog/hang、脏退出推断、多 isolate 共写文件和系统后台 lease 不在首版能力内。Application Support 备份排除尚无原生适配，不宣称跨重装安装身份永久稳定。

## 依据与验证

自动入口使用固定消息，避免将任意业务异常描述写盘；显式 capture 由宿主提供可公开描述。`inAppPackages` 明确自己的 Dart 包，未知包不标记 app。`runtime/source/uptime_ms` 优先于 extras，不能被扩展字段覆盖或因超限回退丢失；source 最多 64 字节。导航只在顶层 route 改变时更新 screen，移除/替换后台 route 不改写当前界面。

按宿主固定 Flutter SDK 的 API 与以下官方说明核对，不引入 zone 以避免 binding/runApp 不同 zone：

- [Flutter errors](https://docs.flutter.dev/testing/errors)
- [PlatformDispatcher.onError](https://api.flutter.dev/flutter/dart-ui/PlatformDispatcher/onError.html)
- [Isolate.addErrorListener](https://api.dart.dev/dart-isolate/Isolate/addErrorListener.html)

SDK 单测覆盖队列/回执/退避/脱敏/处理链，真实 loopback HTTP 覆盖传输；受影响 host 包按其规则执行单测与分析。设备/E2E 不在本次新 SDK 的默认授权中。
