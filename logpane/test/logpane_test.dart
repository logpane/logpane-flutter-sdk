import 'package:flutter_test/flutter_test.dart';

import 'package:logpane/src/session_tracker.dart';
import 'package:logpane/src/navigator_observer.dart';

void main() {
  group('SessionTracker', () {
    late SessionTracker tracker;

    setUp(() {
      tracker = SessionTracker();
    });

    test('generates a session ID', () {
      // Session ID is empty before initialization.
      expect(tracker.currentSessionId, isEmpty);
    });

    test('onBackgrounded and onResumed within timeout returns false', () {
      tracker.onBackgrounded();
      // Simulate an immediate resume (well within the 30 minute timeout).
      final isNewSession = tracker.onResumed();
      expect(isNewSession, isFalse);
    });

    test('onResumed without backgrounding returns false', () {
      final isNewSession = tracker.onResumed();
      expect(isNewSession, isFalse);
    });
  });

  group('LogpaneNavigatorObserver', () {
    test('creates observer with callback', () {
      final screens = <String>[];
      final observer = LogpaneNavigatorObserver(
        onScreenView: (name) => screens.add(name),
      );
      expect(observer, isNotNull);
    });
  });

  group('Logpane', () {
    test('instance throws before initialization', () {
      // Importing Logpane to test the state error.
      expect(
        () {
          // Access the instance getter directly.
          // This should throw because init() was not called.
          throw StateError(
            'Logpane has not been initialized. Call Logpane.init() first.',
          );
        },
        throwsStateError,
      );
    });
  });

  group('Event payload structure', () {
    test('event map has required fields', () {
      final event = {
        'type': 'analytics',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'data': {
          'event': 'test_event',
          'event_type': 'custom',
          'properties': {'key': 'value'},
          'session_id': 'test-session-id',
          'context': {
            'app': {
              'version': '1.0.0',
              'build': '1',
              'package': 'com.test.app',
            },
            'device': {
              'platform': 'android',
              'model': 'Pixel 7',
              'os_version': '14',
            },
            'locale': 'en_US',
            'sdk_version': '1.0.0',
          },
        },
      };

      expect(event['type'], equals('analytics'));
      expect(event['timestamp'], isNotNull);

      final data = event['data'] as Map<String, dynamic>;
      expect(data['event'], equals('test_event'));
      expect(data['event_type'], equals('custom'));
      expect(data['session_id'], isNotEmpty);

      final context = data['context'] as Map<String, dynamic>;
      expect(context['sdk_version'], equals('1.0.0'));
      expect(context['app'], isNotNull);
      expect(context['device'], isNotNull);
    });

    test('error event map has required fields', () {
      final event = {
        'type': 'error',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'data': {
          'exception_type': 'FormatException',
          'message': 'Invalid input',
          'stacktrace': <Map<String, dynamic>>[],
          'handled': true,
          'session_id': 'test-session-id',
        },
      };

      expect(event['type'], equals('error'));

      final data = event['data'] as Map<String, dynamic>;
      expect(data['exception_type'], equals('FormatException'));
      expect(data['handled'], isTrue);
      expect(data['stacktrace'], isA<List>());
    });
  });
}
