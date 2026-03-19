import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// HTTP client for sending batched events to the Logpane API.
///
/// Sends events via POST to /v1/ingest with:
/// - Gzip-compressed body
/// - X-API-Key header for authentication
/// - JSON content type
class LogpaneHttpClient {
  static const String _ingestPath = '/v1/ingest';
  static const Duration _timeout = Duration(seconds: 10);

  final String _endpoint;
  final String _apiKey;
  final http.Client _client;

  LogpaneHttpClient({
    required String endpoint,
    required String apiKey,
    http.Client? client,
  })  : _endpoint = endpoint.endsWith('/')
            ? endpoint.substring(0, endpoint.length - 1)
            : endpoint,
        _apiKey = apiKey,
        _client = client ?? http.Client();

  /// Sends a batch of events to the Logpane API.
  ///
  /// Returns true if the server accepted the batch (2xx response),
  /// false otherwise (network error, server error, etc.).
  ///
  /// The payload is gzip-compressed to minimize bandwidth usage,
  /// which is especially important for mobile connections.
  Future<bool> sendBatch(List<Map<String, dynamic>> events) async {
    if (events.isEmpty) return true;

    // Strip internal queue metadata before sending.
    final cleanedEvents = events.map((event) {
      final clean = Map<String, dynamic>.from(event);
      clean.remove('_queue_id');
      clean.remove('_retry_count');
      return clean;
    }).toList();

    final payload = jsonEncode({'events': cleanedEvents});

    try {
      // Gzip compress the payload.
      final compressed = gzip.encode(utf8.encode(payload));

      final uri = Uri.parse('$_endpoint$_ingestPath');

      final request = http.Request('POST', uri);
      request.headers['Content-Type'] = 'application/json';
      request.headers['Content-Encoding'] = 'gzip';
      request.headers['X-API-Key'] = _apiKey;
      request.bodyBytes = compressed;

      final streamedResponse = await _client.send(request).timeout(_timeout);
      final response = await http.Response.fromStream(streamedResponse);

      return response.statusCode >= 200 && response.statusCode < 300;
    } on SocketException {
      // No network connection.
      return false;
    } on http.ClientException {
      // HTTP client error.
      return false;
    } catch (_) {
      // Any other error (timeout, etc.).
      return false;
    }
  }

  /// Closes the underlying HTTP client.
  void close() {
    _client.close();
  }
}
