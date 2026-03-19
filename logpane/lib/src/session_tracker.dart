import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Manages session lifecycle for the Logpane SDK.
///
/// Session rules:
/// - A new UUID is generated on first app launch (anonymous ID).
/// - A new session ID is generated on each app start.
/// - If the app is backgrounded for more than 30 minutes, a new session
///   is started when the app resumes.
/// - The session ID is attached to every event automatically.
class SessionTracker {
  static const String _anonymousIdKey = 'logpane_anonymous_id';
  static const Duration _sessionTimeout = Duration(minutes: 30);

  final Uuid _uuid = const Uuid();

  String? _currentSessionId;
  String? _anonymousId;
  DateTime? _backgroundedAt;

  /// Returns the current session ID.
  ///
  /// A session ID is always available after [initialize] is called.
  String get currentSessionId => _currentSessionId ?? '';

  /// Initializes the session tracker.
  ///
  /// Loads or generates the anonymous ID and starts a new session.
  Future<void> initialize() async {
    _currentSessionId = _uuid.v4();

    final prefs = await SharedPreferences.getInstance();
    _anonymousId = prefs.getString(_anonymousIdKey);

    if (_anonymousId == null) {
      _anonymousId = _uuid.v4();
      await prefs.setString(_anonymousIdKey, _anonymousId!);
    }
  }

  /// Returns the persistent anonymous ID for this device.
  Future<String> getAnonymousId() async {
    if (_anonymousId != null) return _anonymousId!;

    final prefs = await SharedPreferences.getInstance();
    _anonymousId = prefs.getString(_anonymousIdKey);

    if (_anonymousId == null) {
      _anonymousId = _uuid.v4();
      await prefs.setString(_anonymousIdKey, _anonymousId!);
    }

    return _anonymousId!;
  }

  /// Called when the app is backgrounded.
  ///
  /// Records the time for session timeout calculation.
  void onBackgrounded() {
    _backgroundedAt = DateTime.now();
  }

  /// Called when the app is resumed from the background.
  ///
  /// Returns true if a new session should be started (i.e., the app
  /// was backgrounded for longer than the session timeout).
  bool onResumed() {
    if (_backgroundedAt == null) return false;

    final elapsed = DateTime.now().difference(_backgroundedAt!);
    _backgroundedAt = null;

    if (elapsed > _sessionTimeout) {
      _currentSessionId = _uuid.v4();
      return true;
    }

    return false;
  }
}
