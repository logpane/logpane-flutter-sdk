/// Logpane - Lightweight analytics and error tracking SDK for Flutter.
///
/// Self-hosted, privacy-friendly analytics and error tracking.
///
/// Usage:
/// ```dart
/// await Logpane.init(
///   endpoint: 'https://analytics.yourdomain.com',
///   apiKey: 'lp_live_xxxxxxxx',
/// );
///
/// Logpane.instance.track('button_clicked', {'button_id': 'cta'});
/// ```
library logpane;

export 'src/client.dart' show Logpane;
