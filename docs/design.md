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

关闭时公共门面在第一次异步等待之前立即停止当前客户端；若安装仍在进行，等待完成后继续清理处理器和新客户端。同步构造事件期间宿主getter可以调用close，因此追加队列前再次检查active；关闭后丢弃尚未提交的事件，既有队列保留。已在途请求的迟到成功回执不确认旧队列；这些检查不提供任意宿主getter的执行超时。

先按总节点/深度/条目/字节预算遍历 extras，未知对象不调用 toString；消息、栈、payload 分别限制 8 KB / 32 KB / 8 KB，识别常见凭据、URL、私有路径。screen 只接受代码标识。光语只上报异常类型、Dart 源码栈与固定诊断消息，不发送原业务描述或 Flutter context 文案。

文本扫描最多65,536个UTF-16单元；超限只保留预算内完整行，截口整行省略，无完整行用占位符。预算内先识别完整JWT/带转义引号凭据，再限制字段字节；capture直接清洗原始栈，frames使用同一份安全栈。不能先截断栈或payload键值，再指望完整凭据正则识别残段。

Debug VM 栈可解析 package URI、函数、行列；绝对路径只保留代码文件名。AOT 混淆栈保留脱敏原文，未提供 split-debug-info 符号化，不能伪造源码行号。Web/桌面、原生 crash/ANR、OOM/watchdog/hang、脏退出推断、多 isolate 共写文件和系统后台 lease 不在首版能力内。Application Support 备份排除尚无原生适配，不宣称跨重装安装身份永久稳定。

## 依据与验证

自动入口使用固定消息，避免将任意业务异常描述写盘；显式 capture 由宿主提供可公开描述。`inAppPackages` 明确自己的 Dart 包，未知包不标记 app。`runtime/source/uptime_ms` 优先于 extras，不能被扩展字段覆盖或因超限回退丢失；source 最多 64 字节。导航只在顶层 route 改变时更新 screen，移除/替换后台 route 不改写当前界面。

按宿主固定 Flutter SDK 的 API 与以下官方说明核对，不引入 zone 以避免 binding/runApp 不同 zone：

- [Flutter errors](https://docs.flutter.dev/testing/errors)
- [PlatformDispatcher.onError](https://api.flutter.dev/flutter/dart-ui/PlatformDispatcher/onError.html)
- [Isolate.addErrorListener](https://api.dart.dev/dart-isolate/Isolate/addErrorListener.html)

SDK 单测覆盖队列/回执/退避/脱敏/处理链，真实 loopback HTTP 覆盖传输；受影响 host 包按其规则执行单测与分析。设备/E2E 不在本次新 SDK 的默认授权中。


## 内存压力的数字快照

低内存事件保持 `kind=low_memory`、`source=memory_warning`，不会推断为进程OOM。原有每进程一小时节流先执行，只有被接受的警告才采样一次，不增加轮询或后台任务。

固定数值字段为 `image_cache_bytes`、`image_cache_count`、`image_cache_live_count`、`image_cache_pending_count`、`process_rss_bytes`、`process_peak_rss_bytes`。只接受非负整数，未知键不进入事件；不读取缓存键、图片URL、路由参数、账户或图片内容。进程指标不可用时省略；采样异常仍保留原内存警告。字段放入既有有界payload扩展，不修改信封或公共门面。

Flutter先清理常规图片缓存再通知WidgetsBindingObserver，因此缓存字段是清理后的快照；live images仍可能被可见/保留组件持有。RSS是采样时进程常驻内存，peak RSS由运行时提供，二者不是Dart堆上限或系统Jetsam证据，也不代表警告发生前的图片缓存峰值。采样测试包含真实binding回调、节流、未知键/负数排除和异常隔离；具体设备行为仍需profile验证。

## 固定代码操作轨迹（2026-11-12）

`MooMonitor.breadcrumb(type, name)`只收固定代码标签：type为1–16个小写ASCII字母/数字/下划线、以字母开头；name为最多64字节、2–6段点连接的同类标识符。整串匹配且脱敏不改变原值；URL、空白/换行、数字ID段、凭据及超长值丢弃。不能将书名/账号等业务数据处理成标识符后传入。

ListQueue保持最多30条t/type/name，相邻同type/name合并并保留首次时间，采集事件时复制快照。无独立事件、无单独落盘或发送任务；只有后续被接受的事件才携带轨迹。关闭/撤权/未安装时无效。不自动关联child isolate的业务上下文。

参考[Sentry Dart Scope](https://github.com/getsentry/sentry-dart/blob/f680659cfd1471adab34ccc2ba1e43e434ee6ec2/packages/dart/lib/src/scope.dart)的有界Queue与采集故障隔离，保持同步轻量入口；不引入新zone或全局transaction scope，不采请求参数/headers/body，不增加原生crash能力。

## 常规采集的重入保护

error.toString、StackTrace.toString及自定义Map枚举会执行宿主代码。capture在这些读取之前进入客户端级同步保护，finally解除；同一root isolate内的嵌套采集静默返回，不打印诊断日志、不增加dropped。实际序列化失败仍按原规则记dropped，之后正常采集可继续。保护没有跨await持有，也不建立新zone或跨isolate状态。

对照[Sentry Dart去重处理器](https://github.com/getsentry/sentry-dart/blob/f680659cfd1471adab34ccc2ba1e43e434ee6ec2/packages/dart/lib/src/deduplication/deduplication_event_processor.dart)后，本库不照搬按对象hash保留历史窗口的方案；一次采集返回后，合法后续调用（含复用同一异常或hash相同的不同异常）继续保留独立event_id/count=1。这里仅防同步重入，不合并业务重试，也不消除先后两个独立hook对同一错误的转发。宿主属性仍同步执行，不是执行超时或沙箱机制。
