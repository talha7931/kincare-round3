import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class OfflineStore {
  OfflineStore._([Future<String> Function()? databasePathProvider])
      : _databasePathProvider = databasePathProvider ?? _defaultDatabasePath;
  static final OfflineStore instance = OfflineStore._();
  static final Map<String, Future<String>> _mediaDownloadsInFlight = {};
  @visibleForTesting
  factory OfflineStore.forTesting(String databasePath) =>
      OfflineStore._(() async => databasePath);

  final Future<String> Function() _databasePathProvider;
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final path = await _databasePathProvider();
    _database = await openDatabase(path, version: 4, onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
    }, onCreate: (db, _) async {
      await db.execute('''CREATE TABLE profiles (
        caregiver_id TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
        cached_at TEXT NOT NULL, PRIMARY KEY(caregiver_id, id))''');
      await db.execute('''CREATE TABLE decks (
        caregiver_id TEXT NOT NULL, id TEXT NOT NULL, profile_id TEXT NOT NULL,
        payload TEXT NOT NULL, cached_at TEXT NOT NULL, PRIMARY KEY(caregiver_id, id))''');
      await db.execute('''CREATE TABLE cards (
        caregiver_id TEXT NOT NULL, id TEXT NOT NULL, deck_id TEXT NOT NULL,
        payload TEXT NOT NULL, cached_at TEXT NOT NULL, PRIMARY KEY(caregiver_id, id),
        FOREIGN KEY(caregiver_id, deck_id) REFERENCES decks(caregiver_id, id) ON DELETE CASCADE)''');
      await db.execute('''CREATE TABLE devices (
        caregiver_id TEXT NOT NULL, device_uuid TEXT NOT NULL, device_id TEXT NOT NULL,
        revoked_at TEXT, PRIMARY KEY(caregiver_id, device_uuid))''');
      await db.execute('''CREATE TABLE media_files (
        caregiver_id TEXT NOT NULL, asset_id TEXT NOT NULL, local_path TEXT NOT NULL,
        mime_type TEXT, PRIMARY KEY(caregiver_id, asset_id))''');
      await db.execute('''CREATE TABLE sessions (
        id TEXT PRIMARY KEY, caregiver_id TEXT NOT NULL, profile_id TEXT NOT NULL,
        activity_key TEXT NOT NULL, activity_type_id TEXT, device_id TEXT,
        memory_deck_id TEXT, started_at TEXT NOT NULL, completed_at TEXT,
        status TEXT NOT NULL, sync_state TEXT NOT NULL DEFAULT 'pending')''');
      await db.execute('''CREATE TABLE responses (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, caregiver_id TEXT NOT NULL,
        response_index INTEGER NOT NULL, payload TEXT NOT NULL, is_correct INTEGER,
        responded_at TEXT NOT NULL, sync_state TEXT NOT NULL DEFAULT 'pending',
        FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE RESTRICT)''');
      await db.execute('''CREATE TABLE sync_outbox (
        id TEXT PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
        caregiver_id TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending',
        attempts INTEGER NOT NULL DEFAULT 0, next_retry_at TEXT,
        last_error TEXT, updated_at TEXT NOT NULL)''');
      await db.execute(
          'CREATE TABLE sync_meta (caregiver_id TEXT PRIMARY KEY, last_synced_at TEXT)');
      await db.execute(
          'CREATE INDEX outbox_owner_state_idx ON sync_outbox(caregiver_id, state, next_retry_at)');
      await db.execute(
          'CREATE INDEX sessions_owner_idx ON sessions(caregiver_id, profile_id, started_at)');
      await db.execute(
          'CREATE INDEX responses_session_idx ON responses(session_id, response_index)');
      await _createCacheTables(db);
    }, onUpgrade: (db, oldVersion, newVersion) async {
      // Additive-only migrations. Existing activity/outbox rows are untouched.
      if (oldVersion < 2) await _createCacheTables(db);
      if (oldVersion < 3) await _migrateResponseForeignKey(db);
      if (oldVersion < 4) await _migrateCardForeignKey(db);
    });
    return _database!;
  }

  Future<void> _migrateResponseForeignKey(DatabaseExecutor db) async {
    final orphanRows =
        await db.rawQuery('''SELECT COUNT(*) AS n FROM responses r
      WHERE NOT EXISTS (SELECT 1 FROM sessions s WHERE s.id = r.session_id)''');
    if ((orphanRows.first['n'] as int) > 0) {
      throw StateError(
          'SQLite migration stopped safely: orphaned responses exist. Existing data was not changed.');
    }
    await db.execute('ALTER TABLE responses RENAME TO responses_before_fk');
    await db.execute('''CREATE TABLE responses (
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, caregiver_id TEXT NOT NULL,
      response_index INTEGER NOT NULL, payload TEXT NOT NULL, is_correct INTEGER,
      responded_at TEXT NOT NULL, sync_state TEXT NOT NULL DEFAULT 'pending',
      FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE RESTRICT)''');
    await db.execute('''INSERT INTO responses
      (id, session_id, caregiver_id, response_index, payload, is_correct, responded_at, sync_state)
      SELECT id, session_id, caregiver_id, response_index, payload, is_correct, responded_at, sync_state
      FROM responses_before_fk''');
    await db.execute('DROP TABLE responses_before_fk');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS responses_session_idx ON responses(session_id, response_index)');
  }

  Future<void> _migrateCardForeignKey(DatabaseExecutor db) async {
    final orphanRows = await db.rawQuery('''SELECT COUNT(*) AS n FROM cards c
      WHERE NOT EXISTS (SELECT 1 FROM decks d
        WHERE d.caregiver_id = c.caregiver_id AND d.id = c.deck_id)''');
    if ((orphanRows.first['n'] as int) > 0) {
      throw StateError(
          'SQLite migration stopped safely: orphaned cards exist. Existing data was not changed.');
    }
    await db.execute('ALTER TABLE cards RENAME TO cards_before_fk');
    await db.execute('''CREATE TABLE cards (
      caregiver_id TEXT NOT NULL, id TEXT NOT NULL, deck_id TEXT NOT NULL,
      payload TEXT NOT NULL, cached_at TEXT NOT NULL, PRIMARY KEY(caregiver_id, id),
      FOREIGN KEY(caregiver_id, deck_id) REFERENCES decks(caregiver_id, id) ON DELETE CASCADE)''');
    await db.execute('''INSERT INTO cards
      (caregiver_id, id, deck_id, payload, cached_at)
      SELECT caregiver_id, id, deck_id, payload, cached_at FROM cards_before_fk''');
    await db.execute('DROP TABLE cards_before_fk');
  }

  Future<void> _createCacheTables(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS caregiver_cache (
      caregiver_id TEXT PRIMARY KEY, payload TEXT NOT NULL, cached_at TEXT NOT NULL)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS cached_activity_sessions (
      id TEXT PRIMARY KEY, caregiver_id TEXT NOT NULL, profile_id TEXT NOT NULL,
      payload TEXT NOT NULL, cached_at TEXT NOT NULL)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS cached_activity_responses (
      id TEXT PRIMARY KEY, caregiver_id TEXT NOT NULL, session_id TEXT NOT NULL,
      payload TEXT NOT NULL, cached_at TEXT NOT NULL)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS cache_manifest (
      caregiver_id TEXT NOT NULL, item_type TEXT NOT NULL, item_id TEXT NOT NULL,
      state TEXT NOT NULL, error TEXT, updated_at TEXT NOT NULL,
      PRIMARY KEY(caregiver_id, item_type, item_id))''');
  }

  Future<void> cacheCaregiver(String ownerId, Map<String, dynamic> row) async =>
      (await database).insert(
          'caregiver_cache',
          {
            'caregiver_id': ownerId,
            'payload': jsonEncode(row),
            'cached_at': DateTime.now().toUtc().toIso8601String()
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<Map<String, dynamic>?> readCaregiver(String ownerId) async {
    final rows = await (await database).query('caregiver_cache',
        columns: ['payload'],
        where: 'caregiver_id = ?',
        whereArgs: [ownerId],
        limit: 1);
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(
        jsonDecode(rows.first['payload']! as String) as Map);
  }

  Future<void> cacheHistory(String ownerId, List<Map<String, dynamic>> sessions,
      List<Map<String, dynamic>> responses) async {
    final db = await database;
    await db.transaction((txn) async {
      final now = DateTime.now().toUtc().toIso8601String();
      for (final row in sessions) {
        if (row['caregiver_id'] != ownerId) continue;
        await txn.insert(
            'cached_activity_sessions',
            {
              'id': row['id'],
              'caregiver_id': ownerId,
              'profile_id': row['elderly_profile_id'],
              'payload': jsonEncode(row),
              'cached_at': now
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final row in responses) {
        final sessionId = row['session_id']?.toString();
        if (sessionId == null ||
            !sessions.any((s) =>
                s['id'].toString() == sessionId &&
                s['caregiver_id'] == ownerId)) {
          continue;
        }
        await txn.insert(
            'cached_activity_responses',
            {
              'id': row['id'],
              'caregiver_id': ownerId,
              'session_id': sessionId,
              'payload': jsonEncode(row),
              'cached_at': now
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> setCacheItem(
          String ownerId, String type, String id, String state,
          [String? error]) async =>
      (await database).insert(
          'cache_manifest',
          {
            'caregiver_id': ownerId,
            'item_type': type,
            'item_id': id,
            'state': state,
            'error': error,
            'updated_at': DateTime.now().toUtc().toIso8601String()
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<Map<String, Object?>>> cacheItems(String ownerId) async =>
      (await database).query('cache_manifest',
          where: 'caregiver_id = ?', whereArgs: [ownerId]);

  Future<List<Map<String, dynamic>>> cachedHistory(
      String ownerId, List<String> profileIds) async {
    if (profileIds.isEmpty) return [];
    final marks = List.filled(profileIds.length, '?').join(',');
    final rows = await (await database).rawQuery(
        'SELECT payload FROM cached_activity_sessions WHERE caregiver_id = ? AND profile_id IN ($marks) ORDER BY cached_at DESC',
        [ownerId, ...profileIds]);
    return rows
        .map((r) => Map<String, dynamic>.from(
            jsonDecode(r['payload']! as String) as Map))
        .toList();
  }

  Future<List<Map<String, dynamic>>> cachedResponses(
      String ownerId, List<String> sessionIds) async {
    if (sessionIds.isEmpty) return [];
    final marks = List.filled(sessionIds.length, '?').join(',');
    final rows = await (await database).rawQuery(
        'SELECT payload FROM cached_activity_responses WHERE caregiver_id = ? AND session_id IN ($marks)',
        [ownerId, ...sessionIds]);
    return rows
        .map((r) => Map<String, dynamic>.from(
            jsonDecode(r['payload']! as String) as Map))
        .toList();
  }

  Future<void> cacheProfiles(
      String ownerId, List<Map<String, dynamic>> rows) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().toUtc().toIso8601String();
    batch.delete('profiles', where: 'caregiver_id = ?', whereArgs: [ownerId]);
    for (final row in rows) {
      batch.insert(
          'profiles',
          {
            'caregiver_id': ownerId,
            'id': row['id'].toString(),
            'payload': jsonEncode(row),
            'cached_at': now
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> readProfiles(String ownerId) async {
    final rows = await (await database)
        .query('profiles', where: 'caregiver_id = ?', whereArgs: [ownerId]);
    return rows
        .map((row) => Map<String, dynamic>.from(
            jsonDecode(row['payload']! as String) as Map))
        .toList();
  }

  Future<void> cacheDeck(String ownerId, String profileId,
      Map<String, dynamic> deck, List<Map<String, dynamic>> cards) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
          'decks',
          {
            'caregiver_id': ownerId,
            'id': deck['id'].toString(),
            'profile_id': profileId,
            'payload': jsonEncode(deck),
            'cached_at': DateTime.now().toUtc().toIso8601String()
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('cards',
          where: 'caregiver_id = ? AND deck_id = ?',
          whereArgs: [ownerId, deck['id'].toString()]);
      for (final card in cards) {
        await txn.insert(
            'cards',
            {
              'caregiver_id': ownerId,
              'id': card['id'].toString(),
              'deck_id': deck['id'].toString(),
              'payload': jsonEncode(card),
              'cached_at': DateTime.now().toUtc().toIso8601String()
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> cacheDeckMetadata(
          String ownerId, String profileId, Map<String, dynamic> deck) async =>
      (await database).transaction((txn) async {
        final id = deck['id'].toString();
        final values = {
          'profile_id': profileId,
          'payload': jsonEncode(deck),
          'cached_at': DateTime.now().toUtc().toIso8601String()
        };
        final updated = await txn.update('decks', values,
            where: 'caregiver_id = ? AND id = ?', whereArgs: [ownerId, id]);
        if (updated == 0) {
          await txn.insert('decks', {
            'caregiver_id': ownerId,
            'id': id,
            ...values,
          });
        }
      });

  Future<List<Map<String, dynamic>>> readDecks(
      String ownerId, String profileId) async {
    final rows = await (await database).query('decks',
        where: 'caregiver_id = ? AND profile_id = ?',
        whereArgs: [ownerId, profileId],
        orderBy: 'cached_at DESC');
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final deck = Map<String, dynamic>.from(
          jsonDecode(row['payload']! as String) as Map);
      final state = await (await database).query('cache_manifest',
          columns: ['state', 'error'],
          where: 'caregiver_id = ? AND item_type = ? AND item_id = ?',
          whereArgs: [ownerId, 'deck', row['id']],
          limit: 1);
      deck['_offline_status'] =
          state.isEmpty ? 'unknown' : state.first['state'];
      deck['_offline_error'] = state.isEmpty ? null : state.first['error'];
      result.add(deck);
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> readCards(
      String ownerId, String deckId) async {
    final rows = await (await database).query('cards',
        where: 'caregiver_id = ? AND deck_id = ?',
        whereArgs: [ownerId, deckId]);
    final cards = rows
        .map((row) => Map<String, dynamic>.from(
            jsonDecode(row['payload']! as String) as Map))
        .toList();
    cards.sort((a, b) => ((a['display_order'] as num?)?.toInt() ?? 0)
        .compareTo((b['display_order'] as num?)?.toInt() ?? 0));
    return cards;
  }

  Future<String> cacheMedia(
      String ownerId, String assetId, List<int> bytes, String? mimeType,
      {String? extension, int? expectedBytes, String? rootPath}) async {
    if (bytes.isEmpty ||
        (expectedBytes != null && bytes.length != expectedBytes)) {
      throw StateError('Downloaded media failed local verification.');
    }
    final root = rootPath == null
        ? await getApplicationSupportDirectory()
        : Directory(rootPath);
    final directory = Directory(
        '${root.path}${Platform.pathSeparator}media${Platform.pathSeparator}$ownerId');
    await directory.create(recursive: true);
    final fileExtension = extension?.replaceAll(RegExp(r'[^A-Za-z0-9]'), '') ??
        (mimeType == 'audio/m4a' || mimeType == 'audio/mp4'
            ? 'm4a'
            : mimeType == 'audio/mpeg'
                ? 'mp3'
                : mimeType == 'image/png'
                    ? 'png'
                    : 'jpg');
    final file = File(
        '${directory.path}${Platform.pathSeparator}$assetId.$fileExtension');
    final stalePartCutoff =
        DateTime.now().toUtc().subtract(const Duration(hours: 1));
    try {
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File && entry.path.startsWith('${file.path}.part-')) {
          final modified = (await entry.stat()).modified.toUtc();
          if (modified.isBefore(stalePartCutoff)) await entry.delete();
        }
      }
    } on FileSystemException {
      // Stale temporary-file cleanup must not prevent a verified new download.
    }
    if (await file.exists()) {
      try {
        final existingLength = await file.length();
        if (existingLength > 0 &&
            (expectedBytes == null || existingLength == expectedBytes)) {
          await (await database).insert(
              'media_files',
              {
                'caregiver_id': ownerId,
                'asset_id': assetId,
                'local_path': file.path,
                'mime_type': mimeType
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
          return file.path;
        }
      } on FileSystemException {
        // Replace the invalid or inaccessible copy after a new file verifies.
      }
    }

    final temporary =
        File('${file.path}.part-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (await temporary.length() != bytes.length ||
          (expectedBytes != null && bytes.length != expectedBytes)) {
        throw StateError('Downloaded media failed local verification.');
      }
      // Keep a previously valid file intact until the replacement is verified.
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    await (await database).insert(
        'media_files',
        {
          'caregiver_id': ownerId,
          'asset_id': assetId,
          'local_path': file.path,
          'mime_type': mimeType
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    return file.path;
  }

  Future<String?> mediaPath(String ownerId, String assetId) async {
    final rows = await (await database).query('media_files',
        columns: ['local_path'],
        where: 'caregiver_id = ? AND asset_id = ?',
        whereArgs: [ownerId, assetId],
        limit: 1);
    if (rows.isEmpty) return null;
    final path = rows.first['local_path']! as String;
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      if (await file.length() == 0) return null;
    } on FileSystemException {
      return null;
    }
    return path;
  }

  Future<bool> allMediaCached(String ownerId, List<String> assetIds) async {
    for (final id in assetIds) {
      if (await mediaPath(ownerId, id) == null) return false;
    }
    return true;
  }

  Future<String> cacheMediaIfNeeded(String ownerId, String assetId,
      Future<List<int>> Function() download, String? mimeType,
      {String? extension, int? expectedBytes, String? rootPath}) async {
    final existing = await mediaPath(ownerId, assetId);
    if (existing != null) return existing;
    final key = '$ownerId\u0000$assetId';
    final inFlight = _mediaDownloadsInFlight[key];
    if (inFlight != null) return inFlight;
    final task = () async {
      final rechecked = await mediaPath(ownerId, assetId);
      if (rechecked != null) return rechecked;
      final bytes = await download();
      return cacheMedia(ownerId, assetId, bytes, mimeType,
          extension: extension,
          expectedBytes: expectedBytes,
          rootPath: rootPath);
    }();
    _mediaDownloadsInFlight[key] = task;
    try {
      return await task;
    } finally {
      if (identical(_mediaDownloadsInFlight[key], task)) {
        _mediaDownloadsInFlight.remove(key);
      }
    }
  }

  Future<void> cacheDevice(String ownerId, String deviceUuid, String deviceId,
          String? revokedAt) async =>
      (await database).insert(
          'devices',
          {
            'caregiver_id': ownerId,
            'device_uuid': deviceUuid,
            'device_id': deviceId,
            'revoked_at': revokedAt
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<Map<String, Object?>?> readDevice(
      String ownerId, String deviceUuid) async {
    final rows = await (await database).query('devices',
        where: 'caregiver_id = ? AND device_uuid = ?',
        whereArgs: [ownerId, deviceUuid],
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> createSession(
      {required String id,
      required String caregiverId,
      required String profileId,
      required String activityKey,
      required String? activityTypeId,
      required String? deviceId,
      String? memoryDeckId,
      required String startedAt}) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
          'sessions',
          {
            'id': id,
            'caregiver_id': caregiverId,
            'profile_id': profileId,
            'activity_key': activityKey,
            'activity_type_id': activityTypeId,
            'device_id': deviceId,
            'memory_deck_id': memoryDeckId,
            'started_at': startedAt,
            'status': 'in_progress'
          },
          conflictAlgorithm: ConflictAlgorithm.abort);
      await _queue(txn, id, 'session', id, caregiverId);
    });
  }

  Future<void> saveResponses(String sessionId, String caregiverId,
      List<Map<String, dynamic>> values) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final value in values) {
        final id = value['id'].toString();
        await txn.insert(
            'responses',
            {
              'id': id,
              'session_id': sessionId,
              'caregiver_id': caregiverId,
              'response_index': value['response_index'] as int,
              'payload': jsonEncode(value['response_payload']),
              'is_correct': value['is_correct'] == null
                  ? null
                  : (value['is_correct'] == true ? 1 : 0),
              'responded_at': value['responded_at'] ??
                  DateTime.now().toUtc().toIso8601String()
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
        final exists = await txn.query('responses',
            columns: ['id'],
            where: 'id = ? AND session_id = ?',
            whereArgs: [id, sessionId],
            limit: 1);
        if (exists.isEmpty) {
          throw StateError(
              'A response ID is already attached to another session.');
        }
        await _queue(txn, id, 'response', id, caregiverId);
      }
    });
  }

  Future<void> finishSession(String id, String status,
      {String? completedAt}) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('sessions',
          where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) {
        throw StateError('Activity session was not found locally.');
      }
      final current = rows.first['status'] as String;
      if (current != 'in_progress' && current != status) {
        throw StateError(
            'A completed activity cannot be changed to a different final status.');
      }
      await txn.update(
          'sessions', {'status': status, 'completed_at': completedAt},
          where: 'id = ?', whereArgs: [id]);
      await _queue(
          txn, id, 'session', id, rows.first['caregiver_id'] as String);
    });
  }

  Future<List<Map<String, Object?>>> nextOutbox(String ownerId,
      {required bool force}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    return (await database).query('sync_outbox',
        where:
            'caregiver_id = ? AND state != ? AND (? = 1 OR next_retry_at IS NULL OR next_retry_at <= ?)',
        whereArgs: [ownerId, 'synced', force ? 1 : 0, now],
        orderBy:
            "CASE entity_type WHEN 'session' THEN 0 ELSE 1 END, updated_at ASC");
  }

  Future<Map<String, Object?>?> readSession(String id) async {
    final rows = await (await database)
        .query('sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> readResponses(String id) => (database
      .then((db) => db.query('responses', where: 'id = ?', whereArgs: [id])));

  Future<bool> markSynced(String entityType, String entityId,
      {String? expectedStatus, String? expectedCompletedAt}) async {
    final db = await database;
    var unchanged = true;
    await db.transaction((txn) async {
      if (entityType == 'session') {
        final current = await txn.query('sessions',
            columns: ['status', 'completed_at'],
            where: 'id = ?',
            whereArgs: [entityId],
            limit: 1);
        if (current.isEmpty ||
            current.first['status'] != expectedStatus ||
            current.first['completed_at'] != expectedCompletedAt) {
          unchanged = false;
          await txn.update(
              'sync_outbox',
              {
                'state': 'pending',
                'next_retry_at': null,
                'updated_at': DateTime.now().toUtc().toIso8601String()
              },
              where: 'entity_id = ? AND entity_type = ?',
              whereArgs: [entityId, entityType]);
          await txn.update('sessions', {'sync_state': 'pending'},
              where: 'id = ?', whereArgs: [entityId]);
          return;
        }
      }
      await txn.update(
          'sync_outbox',
          {
            'state': 'synced',
            'last_error': null,
            'next_retry_at': null,
            'updated_at': DateTime.now().toUtc().toIso8601String()
          },
          where: 'entity_id = ? AND entity_type = ?',
          whereArgs: [entityId, entityType]);
      final table = entityType == 'session' ? 'sessions' : 'responses';
      final column = entityType == 'session' ? 'id' : 'id';
      await txn.update(table, {'sync_state': 'synced'},
          where: '$column = ?', whereArgs: [entityId]);
    });
    return unchanged;
  }

  Future<void> markFailed(
      String entityType, String entityId, String error) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('sync_outbox',
          columns: ['attempts'],
          where: 'entity_id = ? AND entity_type = ?',
          whereArgs: [entityId, entityType],
          limit: 1);
      if (rows.isEmpty) return;
      final attempts = (rows.first['attempts'] as int) + 1;
      final delayMinutes = [2, 5, 15, 30, 60][attempts.clamp(1, 5) - 1];
      await txn.update(
          'sync_outbox',
          {
            'state': 'failed',
            'attempts': attempts,
            'last_error': error,
            'next_retry_at': DateTime.now()
                .toUtc()
                .add(Duration(minutes: delayMinutes))
                .toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String()
          },
          where: 'entity_id = ? AND entity_type = ?',
          whereArgs: [entityId, entityType]);
      await txn.update(entityType == 'session' ? 'sessions' : 'responses',
          {'sync_state': 'failed'},
          where: 'id = ?', whereArgs: [entityId]);
    });
  }

  Future<Map<String, int>> outboxCounts(String ownerId) async {
    final rows = await (await database).rawQuery(
        'SELECT state, COUNT(*) AS n FROM sync_outbox WHERE caregiver_id = ? AND state != ? GROUP BY state',
        [ownerId, 'synced']);
    return {for (final row in rows) row['state'] as String: row['n'] as int};
  }

  Future<void> markLastSynced(String ownerId) async => (await database).insert(
      'sync_meta',
      {
        'caregiver_id': ownerId,
        'last_synced_at': DateTime.now().toUtc().toIso8601String()
      },
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<String?> lastSyncedAt(String ownerId) async {
    final rows = await (await database).query('sync_meta',
        columns: ['last_synced_at'],
        where: 'caregiver_id = ?',
        whereArgs: [ownerId],
        limit: 1);
    return rows.isEmpty ? null : rows.first['last_synced_at'] as String?;
  }

  Future<List<Map<String, Object?>>> localSessions(
      String ownerId, List<String> profileIds) async {
    if (profileIds.isEmpty) return [];
    final placeholders = List.filled(profileIds.length, '?').join(',');
    return (await database).rawQuery(
        'SELECT * FROM sessions WHERE caregiver_id = ? AND profile_id IN ($placeholders) ORDER BY started_at DESC',
        [ownerId, ...profileIds]);
  }

  Future<void> clearSyncedCache(String ownerId) async {
    final db = await database;
    final cachedMediaPaths = <String>[];
    await db.transaction((txn) async {
      final media = await txn.query('media_files',
          columns: ['local_path'],
          where: 'caregiver_id = ?',
          whereArgs: [ownerId]);
      cachedMediaPaths.addAll(media
          .map((row) => row['local_path'] as String)
          .where((path) => path.isNotEmpty));
      final pending = await txn.query('sync_outbox',
          columns: ['entity_type', 'entity_id'],
          where: 'caregiver_id = ? AND state != ?',
          whereArgs: [ownerId, 'synced']);
      final protectedSessions = <String>{};
      for (final item in pending) {
        if (item['entity_type'] == 'session') {
          protectedSessions.add(item['entity_id']! as String);
        } else if (item['entity_type'] == 'response') {
          final response = await txn.query('responses',
              columns: ['session_id'],
              where: 'id = ? AND caregiver_id = ?',
              whereArgs: [item['entity_id'], ownerId],
              limit: 1);
          if (response.isNotEmpty) {
            protectedSessions.add(response.first['session_id']! as String);
          }
        }
      }
      final sessions = await txn.query('sessions',
          columns: ['id'],
          where: 'caregiver_id = ? AND sync_state = ?',
          whereArgs: [ownerId, 'synced']);
      for (final session in sessions) {
        final id = session['id']! as String;
        if (!protectedSessions.contains(id)) {
          await txn
              .delete('responses', where: 'session_id = ?', whereArgs: [id]);
          await txn.delete('sessions', where: 'id = ?', whereArgs: [id]);
        }
      }
      await txn.delete('sync_outbox',
          where: 'caregiver_id = ? AND state = ?',
          whereArgs: [ownerId, 'synced']);
      for (final table in [
        'profiles',
        'decks',
        'cards',
        'media_files',
        'devices'
      ]) {
        await txn
            .delete(table, where: 'caregiver_id = ?', whereArgs: [ownerId]);
      }
      for (final table in [
        'caregiver_cache',
        'cached_activity_sessions',
        'cached_activity_responses',
        'cache_manifest'
      ]) {
        await txn
            .delete(table, where: 'caregiver_id = ?', whereArgs: [ownerId]);
      }
      await txn
          .delete('sync_meta', where: 'caregiver_id = ?', whereArgs: [ownerId]);
    });
    for (final path in cachedMediaPaths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // A locked/missing cache file must not block sign-out or queued data.
      }
    }
  }

  Future<List<Map<String, Object?>>> localResponses(String sessionId) async =>
      (await database).query('responses',
          where: 'session_id = ?',
          whereArgs: [sessionId],
          orderBy: 'response_index');

  Future<void> _queue(Transaction txn, String id, String type, String entityId,
          String ownerId) =>
      txn.insert(
          'sync_outbox',
          {
            'id': '$type:$id',
            'entity_type': type,
            'entity_id': entityId,
            'caregiver_id': ownerId,
            'state': 'pending',
            'updated_at': DateTime.now().toUtc().toIso8601String()
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<String> _defaultDatabasePath() async =>
    '${await getDatabasesPath()}${Platform.pathSeparator}kincare_offline.db';
