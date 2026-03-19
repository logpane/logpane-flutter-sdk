import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

/// SQLite-backed offline event queue.
///
/// Events are written to a local SQLite database immediately on creation.
/// They persist across app restarts and are flushed to the server in batches.
///
/// Queue behavior:
/// - Capped at [maxQueueSize] events (oldest dropped when exceeded)
/// - Events with 5+ failed retries are dropped
/// - Uses WAL mode for better concurrent read/write performance
class EventQueue {
  static const String _dbName = 'lp_analytics.db';
  static const String _tableName = 'event_queue';
  static const int _maxRetries = 5;

  final int maxQueueSize;

  Database? _db;

  EventQueue({this.maxQueueSize = 1000});

  /// Initializes the SQLite database and creates the events table.
  Future<void> initialize() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            payload TEXT NOT NULL,
            retry_count INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_queue_created ON $_tableName (created_at ASC)',
        );
      },
      onOpen: (db) async {
        // Enable WAL mode for better concurrent performance.
        await db.execute('PRAGMA journal_mode=WAL');
      },
    );

    // Clean up events that have exceeded the retry limit.
    await _pruneFailedEvents();

    // Enforce queue size cap.
    await _enforceQueueCap();
  }

  /// Returns the number of events currently in the queue.
  int get pendingCount => _pendingCount;
  int _pendingCount = 0;

  /// Adds an event to the queue.
  ///
  /// The event is stored as a JSON-encoded string in SQLite.
  /// If the queue is at capacity, the oldest event is removed first.
  Future<void> add(Map<String, dynamic> event) async {
    final db = _db;
    if (db == null) return;

    await db.insert(_tableName, {
      'payload': jsonEncode(event),
      'retry_count': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });

    _pendingCount++;

    await _enforceQueueCap();
  }

  /// Drains up to [limit] events from the queue.
  ///
  /// Events are removed from the database and returned. If sending fails,
  /// the caller should call [requeue] to put them back with an incremented
  /// retry count.
  Future<List<Map<String, dynamic>>> drain(int limit) async {
    final db = _db;
    if (db == null) return [];

    final rows = await db.query(
      _tableName,
      orderBy: 'created_at ASC',
      limit: limit,
    );

    if (rows.isEmpty) return [];

    final ids = rows.map((r) => r['id'] as int).toList();
    final events = <Map<String, dynamic>>[];

    for (final row in rows) {
      try {
        final payload = jsonDecode(row['payload'] as String);
        if (payload is Map<String, dynamic>) {
          // Attach the queue metadata for requeue handling.
          payload['_queue_id'] = row['id'];
          payload['_retry_count'] = row['retry_count'] as int;
          events.add(payload);
        }
      } catch (_) {
        // Skip malformed events.
      }
    }

    // Delete drained events from the queue.
    await db.delete(
      _tableName,
      where: 'id IN (${ids.map((_) => '?').join(', ')})',
      whereArgs: ids,
    );

    _pendingCount = await _countEvents();

    return events;
  }

  /// Puts events back in the queue after a failed flush.
  ///
  /// Each event's retry count is incremented. Events exceeding the
  /// maximum retry count are dropped.
  Future<void> requeue(List<Map<String, dynamic>> events) async {
    final db = _db;
    if (db == null) return;

    final batch = db.batch();

    for (final event in events) {
      final retryCount = (event['_retry_count'] as int? ?? 0) + 1;

      if (retryCount >= _maxRetries) {
        // Drop events that have exceeded the retry limit.
        continue;
      }

      // Remove queue metadata before re-storing.
      final cleanEvent = Map<String, dynamic>.from(event)
        ..remove('_queue_id')
        ..remove('_retry_count');

      batch.insert(_tableName, {
        'payload': jsonEncode(cleanEvent),
        'retry_count': retryCount,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    }

    await batch.commit(noResult: true);
    _pendingCount = await _countEvents();
  }

  /// Closes the database connection.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Removes events that have exceeded the maximum retry count.
  Future<void> _pruneFailedEvents() async {
    final db = _db;
    if (db == null) return;

    await db.delete(
      _tableName,
      where: 'retry_count >= ?',
      whereArgs: [_maxRetries],
    );

    _pendingCount = await _countEvents();
  }

  /// Enforces the queue size cap by removing the oldest events.
  Future<void> _enforceQueueCap() async {
    final db = _db;
    if (db == null) return;

    final count = await _countEvents();
    if (count <= maxQueueSize) {
      _pendingCount = count;
      return;
    }

    final excess = count - maxQueueSize;
    await db.execute('''
      DELETE FROM $_tableName WHERE id IN (
        SELECT id FROM $_tableName ORDER BY created_at ASC LIMIT ?
      )
    ''', [excess]);

    _pendingCount = maxQueueSize;
  }

  Future<int> _countEvents() async {
    final db = _db;
    if (db == null) return 0;

    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM $_tableName',
    );

    return Sqflite.firstIntValue(result) ?? 0;
  }
}
