class MonitorConfig {
  const MonitorConfig({
    required this.token,
    required this.app,
    required this.platform,
    this.endpoint = 'https://c.mooeen.com',
    this.release = '',
    this.build = '',
    this.environment = 'release',
    this.device = const {},
    this.inAppPackages = const {},
    this.maxRecords = 200,
    this.maxBytes = 2 * 1024 * 1024,
    this.memorySampleLimit = 8,
    this.detectUncleanExit = false,
    this.symbolId = '',
  });

  final String token, app, platform, endpoint, release, build, environment;
  final Map<String, String> device;
  final Set<String> inAppPackages;
  final int maxRecords, maxBytes;

  /// Bounded retained memory samples attached to low-memory events.
  final int memorySampleLimit;

  /// Emit an UncleanExit event when the previous session died after a memory
  /// warning without a clean [MooMonitor.close]. Off by default for hosts that
  /// do not call close; enable deliberately.
  final bool detectUncleanExit;

  /// Optional debug-symbol identifier (e.g. split-debug-info build hash) used
  /// by the backend to symbolicate AOT stacks.
  final String symbolId;

  bool get enabled {
    final uri = Uri.tryParse(endpoint);
    return token.trim().isNotEmpty &&
        RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(app) &&
        ['android', 'ios'].contains(platform) &&
        uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }
}
