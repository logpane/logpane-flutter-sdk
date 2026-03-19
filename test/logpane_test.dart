import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:logpane/src/session_tracker.dart';
import 'package:logpane/src/navigator_observer.dart';
import 'package:logpane/src/http_client.dart';
import 'package:logpane/src/client.dart';

void main() {
  group('LogpaneConfig', () {
    test('default endpoint is api.logpane.dev', () {
      final config = LogpaneConfig(apiKey: 'test_key');
      expect(config.endpoint, equals('https://api.logpane.dev'));
    });

    test('apiKey is required', () {
      final config = LogpaneConfig(apiKey: 'lp_test_abc123');
      expect(config.apiKey, equals('lp_test_abc123'));
    });

    test('has sensible defaults', () {
      final config = LogpaneConfig(apiKey: 'test');
      expect(config.flushIntervalSeconds, equals(30));
      expect(config.maxBatchSize, equals(50));
      expect(config.maxQueueSize, equals(1000));
      expect(config.enableInDebug, isFalse);
    });
  });

  group('SessionTracker', () {
    late SessionTracker tracker;

    setUp(() {
      tracker = SessionTracker();
    });

    test('session ID is empty before initialization', () {
      expect(tracker.currentSessionId, isEmpty);
    });

    test('onResumed without backgrounding returns false', () {
      final isNew = tracker.onResumed();
      expect(isNew, isFalse);
    });

    test('onBackgrounded then immediate onResumed does not create new session', () {
      tracker.onBackgrounded();
      final isNew = tracker.onResumed();
      expect(isNew, isFalse);
    });

    test('onResumed resets background state', () {
      tracker.onBackgrounded();
      tracker.onResumed();
      // Second resume should also return false (no background recorded).
      final isNew = tracker.onResumed();
      expect(isNew, isFalse);
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

    test('callback is stored', () {
      String? captured;
      LogpaneNavigatorObserver(
        onScreenView: (name) => captured = name,
      );
      expect(captured, isNull);
    });
  });

  group('LogpaneHttpClient', () {
    test('sends gzip-compressed request with correct headers', () async {
      String? capturedContentType;
      String? capturedEncoding;
      String? capturedApiKey;
      List<int>? capturedBody;
      Uri? capturedUri;

      final mockClient = http_testing.MockClient((request) async {
        capturedContentType = request.headers['Content-Type'];
        capturedEncoding = request.headers['Content-Encoding'];
        capturedApiKey = request.headers['X-API-Key'];
        capturedBody = request.bodyBytes;
        capturedUri = request.url;
        return http.Response('{"accepted": 1}', 202);
      });

      final client = LogpaneHttpClient(
        endpoint: 'https://api.logpane.dev',
        apiKey: 'lp_test_key',
        client: mockClient,
      );

      final result = await client.sendBatch([
        {'type': 'analytics', 'data': {'event': 'test'}},
      ]);

      expect(result, isTrue);
      expect(capturedUri?.path, equals('/v1/ingest'));
      expect(capturedContentType, equals('application/json'));
      expect(capturedEncoding, equals('gzip'));
      expect(capturedApiKey, equals('lp_test_key'));

      // Verify the body is actually gzip-compressed valid JSON.
      final decompressed = utf8.decode(gzip.decode(capturedBody!));
      final payload = jsonDecode(decompressed) as Map<String, dynamic>;
      expect(payload['events'], isList);
      expect((payload['events'] as List).length, equals(1));
    });

    test('returns false on server error', () async {
      final mockClient = http_testing.MockClient(
        (_) async => http.Response('Internal Server Error', 500),
      );

      final client = LogpaneHttpClient(
        endpoint: 'https://api.logpane.dev',
        apiKey: 'test',
        client: mockClient,
      );

      final result = await client.sendBatch([
        {'type': 'analytics', 'data': {}},
      ]);

      expect(result, isFalse);
    });

    test('returns true on empty batch', () async {
      final mockClient = http_testing.MockClient(
        (_) async => http.Response('should not be called', 500),
      );

      final client = LogpaneHttpClient(
        endpoint: 'https://api.logpane.dev',
        apiKey: 'test',
        client: mockClient,
      );

      final result = await client.sendBatch([]);
      expect(result, isTrue);
    });

    test('strips queue metadata before sending', () async {
      Map<String, dynamic>? sentPayload;

      final mockClient = http_testing.MockClient((request) async {
        final decompressed = utf8.decode(gzip.decode(request.bodyBytes));
        sentPayload = jsonDecode(decompressed) as Map<String, dynamic>;
        return http.Response('{"accepted": 1}', 202);
      });

      final client = LogpaneHttpClient(
        endpoint: 'https://api.logpane.dev',
        apiKey: 'test',
        client: mockClient,
      );

      await client.sendBatch([
        {
          'type': 'analytics',
          'data': {'event': 'test'},
          '_queue_id': 42,
          '_retry_count': 2,
        },
      ]);

      final events = sentPayload!['events'] as List;
      final event = events[0] as Map<String, dynamic>;
      expect(event.containsKey('_queue_id'), isFalse);
      expect(event.containsKey('_retry_count'), isFalse);
      expect(event['type'], equals('analytics'));
    });

    test('strips trailing slash from endpoint', () async {
      Uri? capturedUri;

      final mockClient = http_testing.MockClient((request) async {
        capturedUri = request.url;
        return http.Response('{}', 202);
      });

      final client = LogpaneHttpClient(
        endpoint: 'https://api.logpane.dev/',
        apiKey: 'test',
        client: mockClient,
      );

      await client.sendBatch([{'type': 'analytics', 'data': {}}]);
      expect(capturedUri?.toString(), equals('https://api.logpane.dev/v1/ingest'));
    });

    test('returns false on network error', () async {
      final mockClient = http_testing.MockClient(
        (_) => throw const SocketException('No internet'),
      );

      final client = LogpaneHttpClient(
        endpoint: 'https://api.logpane.dev',
        apiKey: 'test',
        client: mockClient,
      );

      final result = await client.sendBatch([
        {'type': 'analytics', 'data': {}},
      ]);

      expect(result, isFalse);
    });
  });

  group('Logpane static', () {
    test('instance throws StateError before initialization', () {
      expect(
        () => Logpane.instance,
        throwsA(isA<StateError>()),
      );
    });
  });
}
