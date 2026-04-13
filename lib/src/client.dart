import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'device_info.dart';
import 'event_queue.dart';
import 'http_client.dart';
import 'navigator_observer.dart';
import 'session_tracker.dart';

/// Configuration for the Logpane SDK.
class LogpaneConfig {
  /// The Logpane API endpoint.
  static const String _defaultEndpoint = 'https://api.logpane.dev';

  /// The base URL of the Logpane API server.
  final String endpoint;

  /// The project API key for authentication.
  final String apiKey;

  /// Interval in seconds between automatic queue flushes. Default: 30.
  final int flushIntervalSeconds;

  /// Maximum number of events per batch. Default: 50.
  final int maxBatchSize;

  /// Maximum number of events stored locally. Default: 1000.
  final int maxQueueSize;

  /// Source identifier for multi-source tracking. Default: ''.
  final String source;

  /// Whether to collect device information (platform, model, OS version, etc.).
  /// When false, events will have empty device fields but still include
  /// session and page context. Default: true.
  final bool collectDeviceInfo;

  const LogpaneConfig({
    required this.apiKey,
    this.endpoint = _defaultEndpoint,
    this.flushIntervalSeconds = 30,
    this.maxBatchSize = 50,
    this.maxQueueSize = 1000,
    this.source = '',
    this.collectDeviceInfo = true,
  });
}

/// Main Logpane SDK class providing analytics and error tracking.
///
/// Initialize with [Logpane.init] before accessing [Logpane.instance].
class Logpane with WidgetsBindingObserver {
  static const String sdkVersion = '0.1.3';

  static Logpane? _instance;

  /// Returns the initialized Logpane instance.
  ///
  /// Throws [StateError] if [init] has not been called.
  static Logpane get instance {
    if (_instance == null) {
      throw StateError(
        'Logpane has not been initialized. Call Logpane.init() first.',
      );
    }
    return _instance!;
  }

  /// Returns true if the SDK has been fully initialized.
  static bool get isInitialized => _instance?._initialized ?? false;

  final LogpaneConfig _config;
  final EventQueue _eventQueue;
  final SessionTracker _sessionTracker;
  final LogpaneHttpClient _httpClient;
  final LogpaneNavigatorObserver _navigatorObserver;

  DeviceInfoCollector? _deviceInfo;

  bool _enabled = true;
  bool _initialized = false;
  String? _userId;
  Map<String, dynamic>? _userTraits;
  String? _anonymousId;

  Timer? _flushTimer;

  Logpane._({
    required LogpaneConfig config,
    required EventQueue eventQueue,
    required SessionTracker sessionTracker,
    required LogpaneHttpClient httpClient,
    required LogpaneNavigatorObserver navigatorObserver,
  })  : _config = config,
        _eventQueue = eventQueue,
        _sessionTracker = sessionTracker,
        _httpClient = httpClient,
        _navigatorObserver = navigatorObserver;

  /// Initializes the Logpane SDK.
  ///
  /// Must be called before accessing [instance]. Typically called in main()
  /// after [WidgetsFlutterBinding.ensureInitialized].
  static Future<Logpane> init({
    required String apiKey,
    String source = '',
    int flushIntervalSeconds = 30,
    int maxBatchSize = 50,
    int maxQueueSize = 1000,
    bool collectDeviceInfo = true,
  }) async {
    if (_instance != null && _instance!._initialized) {
      return _instance!;
    }

    const endpoint = LogpaneConfig._defaultEndpoint;

    final config = LogpaneConfig(
      apiKey: apiKey,
      source: source,
      flushIntervalSeconds: flushIntervalSeconds,
      maxBatchSize: maxBatchSize,
      maxQueueSize: maxQueueSize,
      collectDeviceInfo: collectDeviceInfo,
    );

    final eventQueue = EventQueue(maxQueueSize: maxQueueSize);
    final sessionTracker = SessionTracker();
    final httpClient = LogpaneHttpClient(
      endpoint: endpoint,
      apiKey: apiKey,
    );

    final instance = Logpane._(
      config: config,
      eventQueue: eventQueue,
      sessionTracker: sessionTracker,
      httpClient: httpClient,
      navigatorObserver: LogpaneNavigatorObserver(
        onScreenView: (screenName) {
          if (_instance != null && _instance!._initialized) {
            _instance!.trackScreen(screenName);
          }
        },
      ),
    );

    try {
      // Initialize all components before exposing the instance.
      await eventQueue.initialize();
      await sessionTracker.initialize();

      if (config.collectDeviceInfo) {
        final deviceInfo = DeviceInfoCollector();
        await deviceInfo.initialize();
        instance._deviceInfo = deviceInfo;
      }

      instance._anonymousId = await sessionTracker.getAnonymousId();

      // Set _instance only after all initialization is complete.
      _instance = instance;
      instance._initialized = true;

      // Track session start.
      await instance._trackSessionStart();

      // Start the periodic flush timer.
      instance._startFlushTimer();

      // Observe app lifecycle for session management and flushing.
      WidgetsBinding.instance.addObserver(instance);
    } catch (e) {
      // If initialization fails, ensure we don't leave a half-baked instance.
      debugPrint('Logpane: initialization failed: $e');
      _instance = null;
      instance._initialized = false;
      rethrow;
    }

    return instance;
  }

  /// Returns the navigator observer for automatic screen tracking.
  ///
  /// Add this to your MaterialApp:
  /// ```dart
  /// MaterialApp(
  ///   navigatorObservers: [Logpane.instance.navigatorObserver],
  /// );
  /// ```
  NavigatorObserver get navigatorObserver => _navigatorObserver;

  /// Tracks a custom event with optional properties.
  ///
  /// ```dart
  /// Logpane.instance.track('purchase', {'item_id': 'abc', 'price': 9.99});
  /// ```
  Future<void> track(
    String eventName, [
    Map<String, dynamic>? properties,
  ]) async {
    if (!_initialized || !_enabled) return;

    try {
      final event = _buildEvent(
        type: 'analytics',
        eventName: eventName,
        eventType: 'custom',
        properties: properties,
      );

      await _enqueue(event);
    } catch (e) {
      debugPrint('Logpane: failed to track event: $e');
    }
  }

  /// Tracks a screen view event.
  ///
  /// This is called automatically by the navigator observer, but can
  /// also be called manually for screens outside the navigator stack.
  Future<void> trackScreen(
    String screenName, [
    Map<String, dynamic>? properties,
  ]) async {
    if (!_initialized || !_enabled) return;

    try {
      final mergedProperties = <String, dynamic>{
        'screen_name': screenName,
        ...?properties,
      };

      final event = _buildEvent(
        type: 'analytics',
        eventName: screenName,
        eventType: 'screen_view',
        properties: mergedProperties,
        screenName: screenName,
      );

      await _enqueue(event);
    } catch (e) {
      debugPrint('Logpane: failed to track screen: $e');
    }
  }

  /// Valid log levels for the [log] method.
  static const _validLogLevels = {'debug', 'info', 'warn', 'error', 'fatal'};

  /// Sends a log event with the specified level and message.
  ///
  /// The [level] must be one of: debug, info, warn, error, fatal.
  /// Optional [metadata] is included in the event properties.
  ///
  /// ```dart
  /// Logpane.instance.log('info', 'User completed onboarding', {
  ///   'step_count': 5,
  ///   'duration_ms': 12340,
  /// });
  /// ```
  Future<void> log(
    String level,
    String message, {
    Map<String, dynamic>? metadata,
  }) async {
    if (!_initialized || !_enabled) return;

    assert(
      _validLogLevels.contains(level),
      'Invalid log level "$level". Must be one of: ${_validLogLevels.join(', ')}',
    );

    if (!_validLogLevels.contains(level)) {
      debugPrint('Logpane: invalid log level "$level", ignoring');
      return;
    }

    try {
      final properties = <String, dynamic>{
        'level': level,
        'message': message,
        if (metadata != null) 'metadata': metadata,
      };

      final event = _buildEvent(
        type: 'log',
        eventName: level,
        eventType: 'log',
        properties: properties,
      );

      await _enqueue(event);
    } catch (e) {
      debugPrint('Logpane: failed to send log event: $e');
    }
  }

  /// Sends a debug-level log event.
  Future<void> logDebug(String message, {Map<String, dynamic>? metadata}) =>
      log('debug', message, metadata: metadata);

  /// Sends an info-level log event.
  Future<void> logInfo(String message, {Map<String, dynamic>? metadata}) =>
      log('info', message, metadata: metadata);

  /// Sends a warn-level log event.
  Future<void> logWarn(String message, {Map<String, dynamic>? metadata}) =>
      log('warn', message, metadata: metadata);

  /// Sends an error-level log event.
  Future<void> logError(String message, {Map<String, dynamic>? metadata}) =>
      log('error', message, metadata: metadata);

  /// Sends a fatal-level log event.
  Future<void> logFatal(String message, {Map<String, dynamic>? metadata}) =>
      log('fatal', message, metadata: metadata);

  /// Captures an error with its stack trace.
  ///
  /// ```dart
  /// try {
  ///   await riskyOperation();
  /// } catch (e, stack) {
  ///   Logpane.instance.captureError(e, stack, context: 'riskyOperation');
  /// }
  /// ```
  Future<void> captureError(
    dynamic error,
    StackTrace? stackTrace, {
    String? context,
    Map<String, dynamic>? extras,
  }) async {
    if (!_initialized || !_enabled) return;

    try {
      final event = _buildErrorEvent(
        error: error,
        stackTrace: stackTrace,
        context: context,
        extras: extras,
        handled: true,
      );

      await _enqueue(event);
    } catch (e) {
      debugPrint('Logpane: failed to capture error: $e');
    }
  }

  /// Captures a Flutter framework error.
  ///
  /// Intended to be used with [FlutterError.onError]:
  /// ```dart
  /// FlutterError.onError = (details) {
  ///   FlutterError.presentError(details);
  ///   Logpane.instance.captureFlutterError(details);
  /// };
  /// ```
  Future<void> captureFlutterError(FlutterErrorDetails details) async {
    if (!_initialized || !_enabled) return;

    try {
      final event = _buildErrorEvent(
        error: details.exception,
        stackTrace: details.stack,
        context: details.context?.toString(),
        handled: false,
      );

      await _enqueue(event);
    } catch (e) {
      debugPrint('Logpane: failed to capture Flutter error: $e');
    }
  }

  /// Identifies the current user for associating events with a user.
  ///
  /// Call this after login or when user information becomes available.
  void identify(String userId, [Map<String, dynamic>? traits]) {
    if (!_initialized) return;
    _userId = userId;
    _userTraits = traits;
  }

  /// Clears the current user identity.
  ///
  /// Call this on logout to stop associating events with the previous user.
  void reset() {
    if (!_initialized) return;
    _userId = null;
    _userTraits = null;
  }

  /// Enables or disables event tracking.
  ///
  /// When disabled, all tracking calls are silently ignored.
  /// Use this to implement an opt-out toggle in your app settings.
  void setEnabled(bool enabled) {
    _enabled = enabled;
  }

  /// Forces an immediate flush of the event queue.
  ///
  /// Normally events are flushed automatically on a timer or when the
  /// batch size threshold is reached. Call this when you need to ensure
  /// events are sent immediately (e.g., before showing a confirmation).
  Future<void> flush() async {
    if (!_initialized || !_enabled) return;

    try {
      await _flushQueue();
    } catch (e) {
      debugPrint('Logpane: failed to flush queue: $e');
    }
  }

  /// Shuts down the SDK, flushing any remaining events.
  Future<void> dispose() async {
    _flushTimer?.cancel();

    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {
      // May fail if binding is not initialized.
    }

    try {
      await _flushQueue();
    } catch (e) {
      debugPrint('Logpane: failed to flush on dispose: $e');
    }

    try {
      await _eventQueue.close();
    } catch (e) {
      debugPrint('Logpane: failed to close event queue: $e');
    }

    _initialized = false;
    _instance = null;
  }

  // -- App Lifecycle --

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_initialized) return;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _onAppBackgrounded();
        break;
      case AppLifecycleState.resumed:
        _onAppResumed();
        break;
      default:
        break;
    }
  }

  void _onAppBackgrounded() {
    _sessionTracker.onBackgrounded();
    _flushQueue();
  }

  void _onAppResumed() {
    final isNewSession = _sessionTracker.onResumed();
    if (isNewSession) {
      _trackSessionEnd();
      _trackSessionStart();
    }
  }

  // -- Internal Methods --

  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(
      Duration(seconds: _config.flushIntervalSeconds),
      (_) => _flushQueue(),
    );
  }

  Future<void> _enqueue(Map<String, dynamic> event) async {
    await _eventQueue.add(event);

    // Flush if batch size threshold reached.
    if (_eventQueue.pendingCount >= _config.maxBatchSize) {
      await _flushQueue();
    }
  }

  Future<void> _flushQueue() async {
    try {
      final events = await _eventQueue.drain(_config.maxBatchSize);
      if (events.isEmpty) return;

      final success = await _httpClient.sendBatch(events);
      if (!success) {
        await _eventQueue.requeue(events);
      }
    } catch (e) {
      debugPrint('Logpane: flush failed: $e');
    }
  }

  Future<void> _trackSessionStart() async {
    final event = _buildEvent(
      type: 'analytics',
      eventName: 'session_start',
      eventType: 'session_start',
    );
    await _enqueue(event);
  }

  Future<void> _trackSessionEnd() async {
    final event = _buildEvent(
      type: 'analytics',
      eventName: 'session_end',
      eventType: 'session_end',
    );
    await _enqueue(event);
  }

  Map<String, dynamic> _buildEvent({
    required String type,
    required String eventName,
    required String eventType,
    Map<String, dynamic>? properties,
    String? screenName,
  }) {
    return {
      'type': type,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'source': _config.source,
      'data': {
        'event': eventName,
        'event_type': eventType,
        'properties': properties ?? {},
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'session_id': _sessionTracker.currentSessionId,
        'user_id': _userId,
        'anonymous_id': _anonymousId,
        if (_userTraits != null) 'user_traits': _userTraits,
        if (screenName != null) 'screen_name': screenName,
        'context': _buildContext(),
      },
    };
  }

  Map<String, dynamic> _buildErrorEvent({
    required dynamic error,
    StackTrace? stackTrace,
    String? context,
    Map<String, dynamic>? extras,
    required bool handled,
  }) {
    final frames = _parseStackTrace(stackTrace);
    final exceptionType = error.runtimeType.toString();
    final message = error.toString();

    return {
      'type': 'error',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'source': _config.source,
      'data': {
        'exception_type': exceptionType,
        'message': message,
        'stacktrace': frames,
        'handled': handled,
        if (context != null) 'context_info': context,
        if (extras != null) 'extra': extras,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'session_id': _sessionTracker.currentSessionId,
        'user_id': _userId,
        'anonymous_id': _anonymousId,
        'device_context': _buildContext(),
      },
    };
  }

  Map<String, dynamic> _buildContext() {
    final info = _deviceInfo?.info;
    if (info == null) {
      return {
        'sdk_version': sdkVersion,
        'environment': kDebugMode ? 'debug' : 'production',
      };
    }
    return {
      'app': {
        'version': info.appVersion,
        'build': info.buildNumber,
        'package': info.packageName,
      },
      'device': {
        'platform': info.platform,
        'model': info.model,
        'os_version': info.osVersion,
        'is_physical': info.isPhysicalDevice,
      },
      'locale': info.locale,
      'sdk_version': sdkVersion,
      'environment': kDebugMode ? 'debug' : 'production',
    };
  }

  List<Map<String, dynamic>> _parseStackTrace(StackTrace? stackTrace) {
    if (stackTrace == null) return [];

    final lines = stackTrace.toString().split('\n');
    final frames = <Map<String, dynamic>>[];

    // Dart stack trace format:
    // #0      MyClass.myMethod (package:my_app/my_class.dart:42:10)
    final frameRegex = RegExp(
      r'#(\d+)\s+(.+?)\s+\((.+?):(\d+):(\d+)\)',
    );

    for (final line in lines) {
      final match = frameRegex.firstMatch(line);
      if (match == null) continue;

      final file = match.group(3) ?? '';
      final isInApp = file.startsWith('package:') &&
          !file.contains('flutter/') &&
          !file.contains('dart:');

      frames.add({
        'index': int.tryParse(match.group(1) ?? '0') ?? 0,
        'function': match.group(2) ?? '',
        'file': file,
        'line': int.tryParse(match.group(4) ?? '0') ?? 0,
        'column': int.tryParse(match.group(5) ?? '0') ?? 0,
        'in_app': isInApp,
      });
    }

    return frames;
  }
}
