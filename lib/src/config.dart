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
  });

  final String token, app, platform, endpoint, release, build, environment;
  final Map<String, String> device;
  final Set<String> inAppPackages;
  final int maxRecords, maxBytes;

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
