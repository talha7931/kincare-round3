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
    _database = await openDatabase(path, version: 5, onConfigure: (db) async {
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
      await _migrateV5(db);
    }, onUpgrade: (db, oldVersion, newVersion) async {
      // Additive-only migrations. Existing activity/outbox rows are untouched.
      if (oldVersion < 2) await _createCacheTables(db);
      if (oldVersion < 3) await _migrateResponseForeignKey(db);
      if (oldVersion < 4) await _migrateCardForeignKey(db);
      if (oldVersion < 5) await _migrateV5(db);
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

  /// Adds only local-first metadata. Existing cache/activity rows are retained.
  Future<void> _migrateV5(DatabaseExecutor db) async {
    await db.execute(
        "ALTER TABLE caregiver_cache ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'synced'");
    await db
        .execute('ALTER TABLE caregiver_cache ADD COLUMN base_payload TEXT');
    for (final table in ['profiles', 'decks', 'cards']) {
      await db.execute(
          'ALTER TABLE $table ADD COLUMN sync_state TEXT NOT NULL DEFAULT \'synced\'');
      await db.execute('ALTER TABLE $table ADD COLUMN base_payload TEXT');
      await db.execute('ALTER TABLE $table ADD COLUMN deleted_at TEXT');
    }
    await db.execute(
        "ALTER TABLE sync_outbox ADD COLUMN operation TEXT NOT NULL DEFAULT 'upsert'");
    await db.execute('ALTER TABLE media_files ADD COLUMN profile_id TEXT');
    await db.execute('ALTER TABLE media_files ADD COLUMN deck_id TEXT');
    await db.execute('ALTER TABLE media_files ADD COLUMN card_id TEXT');
    await db.execute('ALTER TABLE media_files ADD COLUMN media_type TEXT');
    await db.execute('ALTER TABLE media_files ADD COLUMN storage_bucket TEXT');
    await db.execute('ALTER TABLE media_files ADD COLUMN storage_path TEXT');
    await db.execute('ALTER TABLE media_files ADD COLUMN file_size INTEGER');
    await db.execute('ALTER TABLE media_files ADD COLUMN content_hash TEXT');
    await db.execute(
        "ALTER TABLE media_files ADD COLUMN upload_state TEXT NOT NULL DEFAULT 'cached'");
    await db.execute(
        'ALTER TABLE media_files ADD COLUMN upload_attempts INTEGER NOT NULL DEFAULT 0');
    await db.execute('ALTER TABLE media_files ADD COLUMN last_error TEXT');
    await db.execute(
        'ALTER TABLE responses ADD COLUMN response_audio_asset_id TEXT');
    await db.execute('''CREATE TABLE game_checkpoints (
      caregiver_id TEXT NOT NULL, session_id TEXT NOT NULL, game_key TEXT NOT NULL,
      payload TEXT NOT NULL, updated_at TEXT NOT NULL,
      PRIMARY KEY(caregiver_id, session_id),
      FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE)''');
    await db.execute('''CREATE TABLE sync_conflicts (
      caregiver_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
      operation TEXT NOT NULL, local_payload TEXT NOT NULL, remote_payload TEXT NOT NULL,
      created_at TEXT NOT NULL, PRIMARY KEY(caregiver_id, entity_type, entity_id))''');
    await db.execute(
        'CREATE INDEX entity_sync_owner_state_idx ON sync_outbox(caregiver_id, state, operation, updated_at)');
    await db.execute(
        'CREATE INDEX checkpoints_profile_idx ON sessions(caregiver_id, profile_id, activity_key, status)');
  }

  Future<void> cacheCaregiver(String ownerId, Map<String, dynamic> row) async {
    final db = await database;
    final existing = await db.query('caregiver_cache',
        where: 'caregiver_id = ?', whereArgs: [ownerId], limit: 1);
    if (existing.isNotEmpty && existing.first['sync_state'] != 'synced') return;
    final payload = jsonEncode(row);
    await db.insert(
        'caregiver_cache',
        {
          'caregiver_id': ownerId,
          'payload': payload,
          'base_payload': payload,
          'sync_state': 'synced',
          'cached_at': DateTime.now().toUtc().toIso8601String()
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> readCaregiver(String ownerId) async {
    final rows = await (await database).query('caregiver_cache',
        columns: ['payload'],
        where: 'caregiver_id = ?',
        whereArgs: [ownerId],
        limit: 1);
    if (rows.isEmpty) return null;
    return {
      ...Map<String, dynamic>.from(
          jsonDecode(rows.first['payload']! as String) as Map),
      '_sync_state': rows.first['sync_state'],
    };
  }

  Future<void> saveCaregiverLocal(
      String ownerId, Map<String, dynamic> caregiver) async {
    if (caregiver['id']?.toString() != ownerId) {
      throw StateError(
          'Caregiver identity does not match the signed-in account.');
    }
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('caregiver_cache',
          where: 'caregiver_id = ?', whereArgs: [ownerId], limit: 1);
      final existingPayload = rows.isEmpty ? null : rows.first['payload'];
      final base =
          rows.isEmpty ? null : rows.first['base_payload'] ?? existingPayload;
      await txn.insert(
          'caregiver_cache',
          {
            'caregiver_id': ownerId,
            'payload': jsonEncode(caregiver),
            'base_payload': base,
            'sync_state':
                rows.isEmpty || rows.first['sync_state'] == 'pending_create'
                    ? 'pending_create'
                    : 'pending_update',
            'cached_at': DateTime.now().toUtc().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _queueEntity(txn, 'caregiver', ownerId, ownerId, 'upsert');
    });
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
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      final existing = await txn
          .query('profiles', where: 'caregiver_id = ?', whereArgs: [ownerId]);
      final remoteById = {for (final row in rows) row['id'].toString(): row};
      for (final cached in existing) {
        final id = cached['id'].toString();
        if (cached['sync_state'] == 'synced' && !remoteById.containsKey(id)) {
          await txn.delete('profiles',
              where: 'caregiver_id = ? AND id = ?', whereArgs: [ownerId, id]);
        }
      }
      for (final row in rows) {
        final id = row['id'].toString();
        final cached = existing.where((item) => item['id'] == id).firstOrNull;
        if (cached != null && cached['sync_state'] != 'synced') continue;
        final payload = jsonEncode(row);
        await txn.insert(
            'profiles',
            {
              'caregiver_id': ownerId,
              'id': id,
              'payload': payload,
              'base_payload': payload,
              'sync_state': 'synced',
              'deleted_at': null,
              'cached_at': now
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<Map<String, dynamic>>> readProfiles(String ownerId) async {
    final rows = await (await database).query('profiles',
        where: 'caregiver_id = ? AND deleted_at IS NULL',
        whereArgs: [ownerId],
        orderBy: 'cached_at DESC');
    return rows
        .map((row) => {
              ...Map<String, dynamic>.from(
                  jsonDecode(row['payload']! as String) as Map),
              '_sync_state': row['sync_state'],
            })
        .toList();
  }

  Future<void> saveProfile(String ownerId, Map<String, dynamic> profile) async {
    final db = await database;
    final id = profile['id'].toString();
    if (id.isEmpty || profile['caregiver_id']?.toString() != ownerId) {
      throw StateError(
          'Profile ownership does not match the signed-in caregiver.');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      final current = await txn.query('profiles',
          where: 'caregiver_id = ? AND id = ?',
          whereArgs: [ownerId, id],
          limit: 1);
      final wasLocalCreate = current.isEmpty ||
          current.first['sync_state'] == 'pending_create' ||
          current.first['sync_state'] == 'local_only';
      final base = current.isEmpty
          ? null
          : current.first['base_payload'] ?? current.first['payload'];
      await txn.insert(
          'profiles',
          {
            'caregiver_id': ownerId,
            'id': id,
            'payload': jsonEncode(profile),
            'base_payload': base,
            'sync_state': wasLocalCreate ? 'pending_create' : 'pending_update',
            'deleted_at': null,
            'cached_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _queueEntity(txn, 'profile', id, ownerId, 'upsert');
    });
  }

  Future<void> deleteProfile(String ownerId, String profileId) async {
    final db = await database;
    await db.transaction((txn) async {
      final row = await txn.query('profiles',
          where: 'caregiver_id = ? AND id = ?',
          whereArgs: [ownerId, profileId],
          limit: 1);
      if (row.isEmpty) return;
      final decks = await txn.query('decks',
          columns: ['id'],
          where: 'caregiver_id = ? AND profile_id = ? AND deleted_at IS NULL',
          whereArgs: [ownerId, profileId]);
      final now = DateTime.now().toUtc().toIso8601String();
      for (final deck in decks) {
        final deckId = deck['id'].toString();
        final cards = await txn.query('cards',
            columns: ['id'],
            where: 'caregiver_id = ? AND deck_id = ? AND deleted_at IS NULL',
            whereArgs: [ownerId, deckId]);
        for (final card in cards) {
          final cardId = card['id'].toString();
          await txn.update(
              'cards', {'sync_state': 'pending_delete', 'deleted_at': now},
              where: 'caregiver_id = ? AND id = ?',
              whereArgs: [ownerId, cardId]);
          await _queueEntity(txn, 'card', cardId, ownerId, 'delete');
        }
        await txn.update(
            'decks', {'sync_state': 'pending_delete', 'deleted_at': now},
            where: 'caregiver_id = ? AND id = ?', whereArgs: [ownerId, deckId]);
        await _queueEntity(txn, 'deck', deckId, ownerId, 'delete');
      }
      await txn.update(
          'profiles',
          {
            'sync_state': 'pending_delete',
            'deleted_at': now,
          },
          where: 'caregiver_id = ? AND id = ?',
          whereArgs: [ownerId, profileId]);
      await _queueEntity(txn, 'profile', profileId, ownerId, 'delete');
    });
  }

  Future<Map<String, Object?>?> syncEntity(
      String ownerId, String type, String id) async {
    final table = _tableForEntity(type);
    final identityColumn = type == 'media'
        ? 'asset_id'
        : type == 'caregiver'
            ? 'caregiver_id'
            : 'id';
    final rows = await (await database).query(table,
        where: 'caregiver_id = ? AND $identityColumn = ?',
        whereArgs: [ownerId, id],
        limit: 1);
    if (rows.isEmpty) return null;
    final row = Map<String, Object?>.from(rows.first);
    if (type == 'media') {
      row['sync_revision'] = jsonEncode([
        row['local_path'],
        row['file_size'],
        row['storage_path'],
        row['mime_type']
      ]);
      row['decoded_payload'] = {
        'id': row['asset_id'],
        'elderly_profile_id': row['profile_id'],
        'uploaded_by_caregiver_id': ownerId,
        'storage_bucket': row['storage_bucket'],
        'storage_path': row['storage_path'],
        'media_type': row['media_type'],
        'mime_type': row['mime_type'],
      };
      row['decoded_base_payload'] = null;
    } else {
      row['sync_revision'] = row['payload'];
      row['decoded_payload'] =
          jsonDecode(row['payload']! as String) as Map<String, dynamic>;
      row['decoded_base_payload'] = row['base_payload'] == null
          ? null
          : jsonDecode(row['base_payload']! as String) as Map<String, dynamic>;
    }
    return row;
  }

  Future<void> markEntitySynced(
      String ownerId, String type, String id, String operation,
      {String? expectedRevision}) async {
    final db = await database;
    await db.transaction((txn) async {
      final table = _tableForEntity(type);
      final identity = type == 'media'
          ? 'asset_id'
          : type == 'caregiver'
              ? 'caregiver_id'
              : 'id';
      if (operation == 'delete') {
        final current = await txn.query(table,
            where: 'caregiver_id = ? AND $identity = ?',
            whereArgs: [ownerId, id],
            limit: 1);
        if (current.isEmpty) return;
        final revision = type == 'media'
            ? jsonEncode([
                current.first['local_path'],
                current.first['file_size'],
                current.first['storage_path'],
                current.first['mime_type']
              ])
            : current.first['payload'] as String;
        if (expectedRevision != null && revision != expectedRevision) {
          if (type == 'media') {
            await txn.update(
                'media_files', {'upload_state': 'pending', 'last_error': null},
                where: 'caregiver_id = ? AND asset_id = ?',
                whereArgs: [ownerId, id]);
          } else {
            await txn.update(
                table,
                {
                  'sync_state': 'pending_create',
                  'base_payload': null,
                  if (type != 'caregiver') 'deleted_at': null,
                },
                where: 'caregiver_id = ? AND $identity = ?',
                whereArgs: [ownerId, id]);
          }
          await txn.update(
              'sync_outbox',
              {
                'operation': type == 'media' ? 'upload' : 'upsert',
                'state': 'pending',
                'last_error': null,
                'next_retry_at': null,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              },
              where: 'caregiver_id = ? AND entity_type = ? AND entity_id = ?',
              whereArgs: [ownerId, type, id]);
          return;
        }
        await txn.delete(table,
            where: 'caregiver_id = ? AND $identity = ?',
            whereArgs: [ownerId, id]);
      } else if (type == 'media') {
        final current = await txn.query('media_files',
            columns: ['local_path', 'file_size', 'storage_path'],
            where: 'caregiver_id = ? AND asset_id = ?',
            whereArgs: [ownerId, id],
            limit: 1);
        if (current.isEmpty) return;
        final revision = jsonEncode([
          current.first['local_path'],
          current.first['file_size'],
          current.first['storage_path'],
          current.first['mime_type']
        ]);
        if (expectedRevision != null && revision != expectedRevision) {
          await txn.update(
              'media_files',
              {
                'upload_state': 'pending',
                'last_error': null,
              },
              where: 'caregiver_id = ? AND asset_id = ?',
              whereArgs: [ownerId, id]);
          await txn.update(
              'sync_outbox',
              {
                'operation': 'upload',
                'state': 'pending',
                'last_error': null,
                'next_retry_at': null,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              },
              where: 'caregiver_id = ? AND entity_type = ? AND entity_id = ?',
              whereArgs: [ownerId, type, id]);
          return;
        }
        await txn.update(
            'media_files', {'upload_state': 'uploaded', 'last_error': null},
            where: 'caregiver_id = ? AND asset_id = ?',
            whereArgs: [ownerId, id]);
      } else {
        final rows = await txn.query(table,
            columns: ['payload'],
            where: 'caregiver_id = ? AND $identity = ?',
            whereArgs: [ownerId, id],
            limit: 1);
        if (rows.isNotEmpty) {
          final currentPayload = rows.first['payload'] as String;
          if (expectedRevision != null && currentPayload != expectedRevision) {
            await txn.update(
                table,
                {
                  'sync_state': 'pending_update',
                  'base_payload': expectedRevision,
                  if (type != 'caregiver') 'deleted_at': null,
                },
                where: 'caregiver_id = ? AND $identity = ?',
                whereArgs: [ownerId, id]);
            await txn.update(
                'sync_outbox',
                {
                  'operation': 'upsert',
                  'state': 'pending',
                  'last_error': null,
                  'next_retry_at': null,
                  'updated_at': DateTime.now().toUtc().toIso8601String(),
                },
                where: 'caregiver_id = ? AND entity_type = ? AND entity_id = ?',
                whereArgs: [ownerId, type, id]);
            return;
          }
          await txn.update(
              table,
              {
                'sync_state': 'synced',
                'base_payload': rows.first['payload'],
                if (type == 'card')
                  'cached_at': DateTime.now().toUtc().toIso8601String(),
                if (type != 'caregiver') 'deleted_at': null,
              },
              where: 'caregiver_id = ? AND $identity = ?',
              whereArgs: [ownerId, id]);
        }
      }
      await txn.update(
          'sync_outbox',
          {
            'state': 'synced',
            'last_error': null,
            'next_retry_at': null,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'caregiver_id = ? AND entity_type = ? AND entity_id = ?',
          whereArgs: [ownerId, type, id]);
    });
  }

  Future<List<Map<String, dynamic>>> conflicts(String ownerId) async =>
      (await (await database).query('sync_conflicts',
              where: 'caregiver_id = ?', whereArgs: [ownerId]))
          .map((row) => {
                ...row,
                'local_payload': jsonDecode(row['local_payload']! as String),
                'remote_payload': jsonDecode(row['remote_payload']! as String),
              })
          .toList();

  Future<void> resolveConflict(String ownerId, String type, String id,
      {required bool keepLocal}) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('sync_conflicts',
          where: 'caregiver_id = ? AND entity_type = ? AND entity_id = ?',
          whereArgs: [ownerId, type, id],
          limit: 1);
      if (rows.isEmpty) return;
      final conflict = rows.first;
      final remote = Map<String, dynamic>.from(
          jsonDecode(conflict['remote_payload']! as String) as Map);
      final operation =
          keepLocal ? conflict['operation']!.toString() : 'upsert';
      final table = _tableForEntity(type);
      if (type == 'media') {
        if (!keepLocal) {
          await txn.update(
              'media_files',
              {
                'storage_bucket': remote['storage_bucket'],
                'storage_path': remote['storage_path'],
                'upload_state': 'uploaded',
                'last_error': null,
              },
              where: 'caregiver_id = ? AND asset_id = ?',
              whereArgs: [ownerId, id]);
        }
      } else if (keepLocal) {
        final remoteDeleted = remote['_remote_deleted'] == true;
        final identity = type == 'caregiver' ? 'caregiver_id' : 'id';
        await txn.update(
            table,
            {
              'base_payload': remoteDeleted ? null : jsonEncode(remote),
              'sync_state': operation == 'delete'
                  ? 'pending_delete'
                  : remoteDeleted
                      ? 'pending_create'
                      : 'pending_update',
              if (type != 'caregiver')
                'deleted_at': operation == 'delete'
                    ? DateTime.now().toUtc().toIso8601String()
                    : null,
            },
            where: 'caregiver_id = ? AND $identity = ?',
            whereArgs: [ownerId, id]);
      } else if (remote['_remote_deleted'] == true) {
        final identity = type == 'caregiver' ? 'caregiver_id' : 'id';
        await txn.update(
            table,
            {
              'sync_state': 'synced',
              if (type != 'caregiver')
                'deleted_at': DateTime.now().toUtc().toIso8601String(),
            },
            where: 'caregiver_id = ? AND $identity = ?',
            whereArgs: [ownerId, id]);
      } else {
        final payload = jsonEncode(remote);
        final identity = type == 'caregiver' ? 'caregiver_id' : 'id';
        await txn.update(
            table,
            {
              'payload': payload,
              'base_payload': payload,
              'sync_state': 'synced',
              if (type != 'caregiver') 'deleted_at': null,
              'cached_at': DateTime.now().toUtc().toIso8601String(),
            },
            where: 'caregiver_id = ? AND $identity = ?',
            whereArgs: [ownerId, id]);
      }
      if (keepLocal) {
        await txn.update(
            'sync_outbox',
            {
              'operation': operation,
              'state': 'pending',
              'attempts': 0,
              'next_retry_at': null,
              'last_error': null,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            },
            where: 'caregiver_id = ? AND entity_type = ? AND entity_id = ?',
            whereArgs: [ownerId, type, id]);
      } else {
        await txn.update('sync_outbox',
            {'state': 'synced', 'last_error': null, 'next_retry_at': null},
            where: 'caregiver_id = ? AND entity_type = ? AND entity_id = ?',
            whereArgs: [ownerId, type, id]);
      }
      await txn.delete('sync_conflicts',
          where: 'caregiver_id = ? AND entity_type = ? AND entity_id = ?',
          whereArgs: [ownerId, type, id]);
    });
  }

  Future<void> recordConflict(
      String ownerId,
      String type,
      String id,
      String operation,
      Map<String, dynamic> local,
      Map<String, dynamic> remote) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      await txn.insert(
          'sync_conflicts',
          {
            'caregiver_id': ownerId,
            'entity_type': type,
            'entity_id': id,
            'operation': operation,
            'local_payload': jsonEncode(local),
            'remote_payload': jsonEncode(remote),
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      if (type == 'media') {
        await txn.update(
            'media_files',
            {
              'upload_state': 'conflict',
              'last_error': 'Review the conflicting cloud media record.'
            },
            where: 'caregiver_id = ? AND asset_id = ?',
            whereArgs: [ownerId, id]);
      } else {
        final identity = type == 'caregiver' ? 'caregiver_id' : 'id';
        await txn.update(_tableForEntity(type), {'sync_state': 'conflict'},
            where: 'caregiver_id = ? AND $identity = ?',
            whereArgs: [ownerId, id]);
      }
      await txn.update(
          'sync_outbox',
          {
            'state': 'conflict',
            'last_error': 'A newer cloud version needs review.',
            'updated_at': now
          },
          where: 'caregiver_id = ? AND entity_type = ? AND entity_id = ?',
          whereArgs: [ownerId, type, id]);
    });
  }

  Future<void> cacheDeck(String ownerId, String profileId,
      Map<String, dynamic> deck, List<Map<String, dynamic>> cards,
      {DateTime? remoteSnapshotStartedAt}) async {
    final db = await database;
    await db.transaction((txn) async {
      final deckId = deck['id'].toString();
      final now = DateTime.now().toUtc().toIso8601String();
      final existingDeck = await txn.query('decks',
          where: 'caregiver_id = ? AND id = ?',
          whereArgs: [ownerId, deckId],
          limit: 1);
      if (existingDeck.isEmpty ||
          existingDeck.first['sync_state'] == 'synced') {
        final payload = jsonEncode(deck);
        final values = {
          'profile_id': profileId,
          'payload': payload,
          'base_payload': payload,
          'sync_state': 'synced',
          'deleted_at': null,
          'cached_at': now
        };
        if (existingDeck.isEmpty) {
          await txn.insert('decks', {
            'caregiver_id': ownerId,
            'id': deckId,
            ...values,
          });
        } else {
          // INSERT OR REPLACE deletes the parent row first. With foreign keys
          // enabled that cascades and removes every locally cached card.
          await txn.update('decks', values,
              where: 'caregiver_id = ? AND id = ?',
              whereArgs: [ownerId, deckId]);
        }
      }
      final existingCards = await txn.query('cards',
          where: 'caregiver_id = ? AND deck_id = ?',
          whereArgs: [ownerId, deckId]);
      final remoteIds = {for (final card in cards) card['id'].toString()};
      for (final old in existingCards) {
        final cachedAt =
            DateTime.tryParse(old['cached_at']?.toString() ?? '')?.toUtc();
        final snapshotStartedAt = remoteSnapshotStartedAt?.toUtc();
        if (old['sync_state'] == 'synced' &&
            !remoteIds.contains(old['id'].toString()) &&
            cachedAt != null &&
            snapshotStartedAt != null &&
            cachedAt.isBefore(snapshotStartedAt)) {
          await txn.delete('cards',
              where: 'caregiver_id = ? AND id = ?',
              whereArgs: [ownerId, old['id']]);
        }
      }
      for (final card in cards) {
        final cardId = card['id'].toString();
        final existing =
            existingCards.where((item) => item['id'] == cardId).firstOrNull;
        if (existing != null && existing['sync_state'] != 'synced') continue;
        final payload = jsonEncode(card);
        await txn.insert(
            'cards',
            {
              'caregiver_id': ownerId,
              'id': cardId,
              'deck_id': deckId,
              'payload': payload,
              'base_payload': payload,
              'sync_state': 'synced',
              'deleted_at': null,
              'cached_at': now
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> cacheDeckMetadata(
          String ownerId, String profileId, Map<String, dynamic> deck) async =>
      (await database).transaction((txn) async {
        final id = deck['id'].toString();
        final existing = await txn.query('decks',
            columns: ['sync_state'],
            where: 'caregiver_id = ? AND id = ?',
            whereArgs: [ownerId, id],
            limit: 1);
        if (existing.isNotEmpty && existing.first['sync_state'] != 'synced') {
          return;
        }
        final payload = jsonEncode(deck);
        final values = {
          'profile_id': profileId,
          'payload': payload,
          'base_payload': payload,
          'sync_state': 'synced',
          'deleted_at': null,
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
        where: 'caregiver_id = ? AND profile_id = ? AND deleted_at IS NULL',
        whereArgs: [ownerId, profileId],
        orderBy: 'cached_at DESC');
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final deck = Map<String, dynamic>.from(
          jsonDecode(row['payload']! as String) as Map);
      deck['_sync_state'] = row['sync_state'];
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
    final db = await database;
    final rows = await db.query('cards',
        where: 'caregiver_id = ? AND deck_id = ? AND deleted_at IS NULL',
        whereArgs: [ownerId, deckId]);
    final cards = <Map<String, dynamic>>[];
    for (final row in rows) {
      final card = Map<String, dynamic>.from(
          jsonDecode(row['payload']! as String) as Map);
      card['_sync_state'] = row['sync_state'];
      cards.add(card);
    }
    cards.sort((a, b) => ((a['display_order'] as num?)?.toInt() ?? 0)
        .compareTo((b['display_order'] as num?)?.toInt() ?? 0));
    return cards;
  }

  Future<void> saveDeckLocal(
      String ownerId, String profileId, Map<String, dynamic> deck) async {
    final db = await database;
    final id = deck['id'].toString();
    if (id.isEmpty ||
        deck['elderly_profile_id']?.toString() != profileId ||
        deck['created_by_caregiver_id']?.toString() != ownerId) {
      throw StateError('Deck ownership does not match the selected profile.');
    }
    await db.transaction((txn) async {
      final profile = await txn.query('profiles',
          columns: ['id'],
          where: 'caregiver_id = ? AND id = ? AND deleted_at IS NULL',
          whereArgs: [ownerId, profileId],
          limit: 1);
      if (profile.isEmpty) {
        throw StateError(
            'The selected profile is not saved for this caregiver.');
      }
      final rows = await txn.query('decks',
          where: 'caregiver_id = ? AND id = ?',
          whereArgs: [ownerId, id],
          limit: 1);
      final create = rows.isEmpty ||
          rows.first['sync_state'] == 'pending_create' ||
          rows.first['sync_state'] == 'local_only';
      final base = rows.isEmpty
          ? null
          : rows.first['base_payload'] ?? rows.first['payload'];
      await txn.insert(
          'decks',
          {
            'caregiver_id': ownerId,
            'id': id,
            'profile_id': profileId,
            'payload': jsonEncode(deck),
            'base_payload': base,
            'sync_state': create ? 'pending_create' : 'pending_update',
            'deleted_at': null,
            'cached_at': DateTime.now().toUtc().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _queueEntity(txn, 'deck', id, ownerId, 'upsert');
    });
  }

  Future<void> deleteDeckLocal(String ownerId, String deckId) async {
    final db = await database;
    await db.transaction((txn) async {
      final now = DateTime.now().toUtc().toIso8601String();
      final children = await txn.query('cards',
          columns: ['id'],
          where: 'caregiver_id = ? AND deck_id = ?',
          whereArgs: [ownerId, deckId]);
      for (final card in children) {
        final id = card['id'].toString();
        await txn.update(
            'cards', {'sync_state': 'pending_delete', 'deleted_at': now},
            where: 'caregiver_id = ? AND id = ?', whereArgs: [ownerId, id]);
        await _queueEntity(txn, 'card', id, ownerId, 'delete');
      }
      await txn.update(
          'decks', {'sync_state': 'pending_delete', 'deleted_at': now},
          where: 'caregiver_id = ? AND id = ?', whereArgs: [ownerId, deckId]);
      await _queueEntity(txn, 'deck', deckId, ownerId, 'delete');
    });
  }

  Future<void> saveCardLocal(
      String ownerId, String deckId, Map<String, dynamic> card) async {
    final db = await database;
    final id = card['id']?.toString() ?? '';
    if (id.isEmpty || card['deck_id']?.toString() != deckId) {
      throw StateError('The card ID and deck relationship are invalid.');
    }
    await db.transaction((txn) async {
      final deck = await txn.query('decks',
          where: 'caregiver_id = ? AND id = ? AND deleted_at IS NULL',
          whereArgs: [ownerId, deckId],
          limit: 1);
      if (deck.isEmpty) throw StateError('The local deck is unavailable.');
      final rows = await txn.query('cards',
          where: 'caregiver_id = ? AND id = ?',
          whereArgs: [ownerId, id],
          limit: 1);
      final create = rows.isEmpty ||
          rows.first['sync_state'] == 'pending_create' ||
          rows.first['sync_state'] == 'local_only';
      final base = rows.isEmpty
          ? null
          : rows.first['base_payload'] ?? rows.first['payload'];
      await txn.insert(
          'cards',
          {
            'caregiver_id': ownerId,
            'id': id,
            'deck_id': deckId,
            'payload': jsonEncode(card),
            'base_payload': base,
            'sync_state': create ? 'pending_create' : 'pending_update',
            'deleted_at': null,
            'cached_at': DateTime.now().toUtc().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _queueEntity(txn, 'card', id, ownerId, 'upsert');
    });
  }

  Future<void> reorderCardsLocal(
      String ownerId, String deckId, List<String> orderedCardIds) async {
    if (orderedCardIds.toSet().length != orderedCardIds.length) {
      throw ArgumentError('A card can appear only once in a deck order.');
    }
    final db = await database;
    await db.transaction((txn) async {
      final deck = await txn.query('decks',
          columns: ['id'],
          where: 'caregiver_id = ? AND id = ? AND deleted_at IS NULL',
          whereArgs: [ownerId, deckId],
          limit: 1);
      if (deck.isEmpty) throw StateError('The local deck is unavailable.');
      final existing = await txn.query('cards',
          where: 'caregiver_id = ? AND deck_id = ? AND deleted_at IS NULL',
          whereArgs: [ownerId, deckId]);
      final byId = {for (final row in existing) row['id'].toString(): row};
      if (byId.length != orderedCardIds.length ||
          !byId.keys.toSet().containsAll(orderedCardIds)) {
        throw StateError(
            'The card order does not match the saved cards in this deck.');
      }
      for (var index = 0; index < orderedCardIds.length; index++) {
        final id = orderedCardIds[index];
        final row = byId[id]!;
        final payload = Map<String, dynamic>.from(
            jsonDecode(row['payload']! as String) as Map);
        payload['display_order'] = index;
        final state = row['sync_state']?.toString();
        await txn.update(
            'cards',
            {
              'payload': jsonEncode(payload),
              'base_payload': row['base_payload'] ?? row['payload'],
              'sync_state': state == 'pending_create' || state == 'local_only'
                  ? 'pending_create'
                  : 'pending_update',
              'cached_at': DateTime.now().toUtc().toIso8601String(),
            },
            where: 'caregiver_id = ? AND id = ?',
            whereArgs: [ownerId, id]);
        await _queueEntity(txn, 'card', id, ownerId, 'upsert');
      }
    });
  }

  Future<void> deleteCardLocal(String ownerId, String cardId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
          'cards',
          {
            'sync_state': 'pending_delete',
            'deleted_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'caregiver_id = ? AND id = ?',
          whereArgs: [ownerId, cardId]);
      await _queueEntity(txn, 'card', cardId, ownerId, 'delete');
    });
  }

  Future<String> cacheMedia(
      String ownerId, String assetId, List<int> bytes, String? mimeType,
      {String? extension,
      int? expectedBytes,
      String? rootPath,
      String uploadState = 'cached'}) async {
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
                'mime_type': mimeType,
                'file_size': existingLength,
                'upload_state': uploadState,
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
          'mime_type': mimeType,
          'file_size': bytes.length,
          'upload_state': uploadState,
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

  Future<Map<String, Object?>?> mediaRecord(
      String ownerId, String assetId) async {
    final rows = await (await database).query('media_files',
        where: 'caregiver_id = ? AND asset_id = ?',
        whereArgs: [ownerId, assetId],
        limit: 1);
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  /// Copies a picker/recorder file into durable app-private storage and queues
  /// its upload in the same SQLite transaction as its metadata.
  Future<String> importLocalMedia({
    required String ownerId,
    required String assetId,
    required String profileId,
    required String mediaType,
    required String mimeType,
    required File source,
    String? deckId,
    String? cardId,
    String bucket = 'kincare-media',
    String? rootPath,
  }) async {
    if (!await source.exists())
      throw StateError('The selected media is missing.');
    final sourceLength = await source.length();
    if (sourceLength <= 0) throw StateError('The selected media is empty.');
    final root = rootPath == null
        ? await getApplicationSupportDirectory()
        : Directory(rootPath);
    final extension =
        source.path.split('.').last.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final directory = Directory(
        '${root.path}${Platform.pathSeparator}media${Platform.pathSeparator}$ownerId');
    await directory.create(recursive: true);
    final destination = File(
        '${directory.path}${Platform.pathSeparator}$assetId.${extension.isEmpty ? 'bin' : extension}');
    final temporary = File(
        '${destination.path}.part-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await source.copy(temporary.path);
      if (await temporary.length() != sourceLength) {
        throw StateError('The selected media could not be copied completely.');
      }
      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    final storagePath =
        '$profileId/$assetId.${extension.isEmpty ? 'bin' : extension}';
    final db = await database;
    try {
      await db.transaction((txn) async {
        final profile = await txn.query('profiles',
            columns: ['id'],
            where: 'caregiver_id = ? AND id = ? AND deleted_at IS NULL',
            whereArgs: [ownerId, profileId],
            limit: 1);
        if (profile.isEmpty) {
          throw StateError(
              'The media profile is not saved for this caregiver.');
        }
        if (deckId != null) {
          final deck = await txn.query('decks',
              columns: ['id'],
              where:
                  'caregiver_id = ? AND id = ? AND profile_id = ? AND deleted_at IS NULL',
              whereArgs: [ownerId, deckId, profileId],
              limit: 1);
          if (deck.isEmpty) {
            throw StateError('The media deck is not saved for this caregiver.');
          }
        }
        await txn.insert(
            'media_files',
            {
              'caregiver_id': ownerId,
              'asset_id': assetId,
              'local_path': destination.path,
              'mime_type': mimeType,
              'profile_id': profileId,
              'deck_id': deckId,
              'card_id': cardId,
              'media_type': mediaType,
              'storage_bucket': bucket,
              'storage_path': storagePath,
              'file_size': sourceLength,
              'upload_state': 'pending',
              'upload_attempts': 0,
              'last_error': null,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await _queueEntity(txn, 'media', assetId, ownerId, 'upload');
      });
    } catch (_) {
      // Keep the durable source file. The user can retry or recover the draft.
      rethrow;
    }
    return destination.path;
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
              'response_audio_asset_id': value['response_audio_asset_id'],
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
      if (status != 'in_progress') {
        await txn.delete('game_checkpoints',
            where: 'session_id = ?', whereArgs: [id]);
      }
    });
  }

  Future<void> completeSessionWithResponses(
      String sessionId, String caregiverId, List<Map<String, dynamic>> values,
      {String? completedAt}) async {
    final db = await database;
    await db.transaction((txn) async {
      final session = await txn.query('sessions',
          where: 'id = ? AND caregiver_id = ?',
          whereArgs: [sessionId, caregiverId],
          limit: 1);
      if (session.isEmpty)
        throw StateError('Activity session was not found locally.');
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
              'response_audio_asset_id': value['response_audio_asset_id'],
              'responded_at': value['responded_at'] ??
                  DateTime.now().toUtc().toIso8601String(),
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
      await txn.update(
          'sessions',
          {
            'status': 'completed',
            'completed_at':
                completedAt ?? DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ? AND caregiver_id = ?',
          whereArgs: [sessionId, caregiverId]);
      await _queue(txn, sessionId, 'session', sessionId, caregiverId);
      await txn.delete('game_checkpoints',
          where: 'caregiver_id = ? AND session_id = ?',
          whereArgs: [caregiverId, sessionId]);
    });
  }

  Future<void> saveGameCheckpoint({
    required String caregiverId,
    required String sessionId,
    required String gameKey,
    required Map<String, dynamic> payload,
  }) async {
    await (await database).insert(
        'game_checkpoints',
        {
          'caregiver_id': caregiverId,
          'session_id': sessionId,
          'game_key': gameKey,
          'payload': jsonEncode(payload),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> readGameCheckpoint(
      String caregiverId, String sessionId) async {
    final rows = await (await database).query('game_checkpoints',
        where: 'caregiver_id = ? AND session_id = ?',
        whereArgs: [caregiverId, sessionId],
        limit: 1);
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(
        jsonDecode(rows.first['payload']! as String) as Map);
  }

  Future<Map<String, Object?>?> resumableSession(
      String ownerId, String profileId, String activityKey) async {
    final rows = await (await database).query('sessions',
        where:
            'caregiver_id = ? AND profile_id = ? AND activity_key = ? AND status = ?',
        whereArgs: [ownerId, profileId, activityKey, 'in_progress'],
        orderBy: 'started_at DESC',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> resumableDeckSession(
      String ownerId, String profileId, String deckId) async {
    final rows = await (await database).query('sessions',
        where:
            'caregiver_id = ? AND profile_id = ? AND activity_key = ? AND memory_deck_id = ? AND status = ?',
        whereArgs: [ownerId, profileId, 'memory_decks', deckId, 'in_progress'],
        orderBy: 'started_at DESC',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> nextOutbox(String ownerId,
      {required bool force}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    return (await database).query('sync_outbox',
        where:
            'caregiver_id = ? AND state NOT IN (?, ?) AND (? = 1 OR next_retry_at IS NULL OR next_retry_at <= ?)',
        whereArgs: [ownerId, 'synced', 'conflict', force ? 1 : 0, now],
        orderBy: '''
          CASE WHEN operation = 'delete' THEN 1 ELSE 0 END,
          CASE
            WHEN operation = 'delete' THEN CASE entity_type
              WHEN 'card' THEN 0 WHEN 'deck' THEN 1 WHEN 'profile' THEN 2
              WHEN 'media' THEN 3 WHEN 'caregiver' THEN 4 WHEN 'response' THEN 5 WHEN 'session' THEN 6 ELSE 7 END
            ELSE CASE entity_type
              WHEN 'caregiver' THEN 0 WHEN 'profile' THEN 1 WHEN 'media' THEN 2
              WHEN 'deck' THEN 3 WHEN 'card' THEN 4 WHEN 'session' THEN 5 WHEN 'response' THEN 6 ELSE 7 END
          END,
          updated_at ASC''');
  }

  Future<Map<String, Object?>?> readSession(String id) async {
    final rows = await (await database)
        .query('sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> readResponses(String id) => (database
      .then((db) => db.query('responses', where: 'id = ?', whereArgs: [id])));

  Future<bool> markSynced(String entityType, String entityId,
      {String? expectedStatus,
      String? expectedCompletedAt,
      String? caregiverId}) async {
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
              where:
                  'entity_id = ? AND entity_type = ?${caregiverId == null ? '' : ' AND caregiver_id = ?'}',
              whereArgs: [
                entityId,
                entityType,
                if (caregiverId != null) caregiverId
              ]);
          await txn.update('sessions', {'sync_state': 'pending'},
              where:
                  'id = ?${caregiverId == null ? '' : ' AND caregiver_id = ?'}',
              whereArgs: [entityId, if (caregiverId != null) caregiverId]);
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
          where:
              'entity_id = ? AND entity_type = ?${caregiverId == null ? '' : ' AND caregiver_id = ?'}',
          whereArgs: [
            entityId,
            entityType,
            if (caregiverId != null) caregiverId
          ]);
      final table = entityType == 'session' ? 'sessions' : 'responses';
      await txn.update(table, {'sync_state': 'synced'},
          where: 'id = ?${caregiverId == null ? '' : ' AND caregiver_id = ?'}',
          whereArgs: [entityId, if (caregiverId != null) caregiverId]);
    });
    return unchanged;
  }

  Future<void> markFailed(String entityType, String entityId, String error,
      {String? caregiverId}) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('sync_outbox',
          columns: ['attempts'],
          where:
              'entity_id = ? AND entity_type = ?${caregiverId == null ? '' : ' AND caregiver_id = ?'}',
          whereArgs: [
            entityId,
            entityType,
            if (caregiverId != null) caregiverId
          ],
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
          where:
              'entity_id = ? AND entity_type = ?${caregiverId == null ? '' : ' AND caregiver_id = ?'}',
          whereArgs: [
            entityId,
            entityType,
            if (caregiverId != null) caregiverId
          ]);
      if (entityType == 'session' || entityType == 'response') {
        await txn.update(entityType == 'session' ? 'sessions' : 'responses',
            {'sync_state': 'failed'},
            where: 'id = ?', whereArgs: [entityId]);
      } else if (entityType == 'media') {
        await txn.update(
            'media_files',
            {
              'upload_state': 'failed',
              'last_error': error,
              'upload_attempts': (rows.first['attempts'] as int) + 1
            },
            where: 'asset_id = ? AND caregiver_id = ?',
            whereArgs: [entityId, caregiverId]);
      } else {
        final identity = entityType == 'caregiver' ? 'caregiver_id' : 'id';
        await txn.update(_tableForEntity(entityType), {'sync_state': 'failed'},
            where: '$identity = ? AND caregiver_id = ?',
            whereArgs: [entityId, caregiverId]);
      }
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
      final hasPendingContent = pending.any((item) => const {
            'caregiver',
            'profile',
            'deck',
            'card',
            'media'
          }.contains(item['entity_type']));
      if (!hasPendingContent) {
        final media = await txn.query('media_files',
            columns: ['local_path'],
            where: 'caregiver_id = ?',
            whereArgs: [ownerId]);
        cachedMediaPaths.addAll(media
            .map((row) => row['local_path'] as String)
            .where((path) => path.isNotEmpty));
        // Keep the local authoring graph intact whenever queued work depends on
        // it. A later sign-in by this same caregiver can safely resume sync.
        await txn.delete('cards',
            where: 'caregiver_id = ? AND sync_state = ?',
            whereArgs: [ownerId, 'synced']);
        await txn.delete('decks',
            where: 'caregiver_id = ? AND sync_state = ?',
            whereArgs: [ownerId, 'synced']);
        await txn.delete('profiles',
            where: 'caregiver_id = ? AND sync_state = ?',
            whereArgs: [ownerId, 'synced']);
        await txn.delete('media_files',
            where: 'caregiver_id = ?', whereArgs: [ownerId]);
      }
      await txn
          .delete('devices', where: 'caregiver_id = ?', whereArgs: [ownerId]);
      final cacheTables = [
        'cached_activity_sessions',
        'cached_activity_responses',
        'cache_manifest'
      ];
      if (!hasPendingContent) cacheTables.add('caregiver_cache');
      for (final table in cacheTables) {
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

  Future<void> _queueEntity(Transaction txn, String type, String id,
          String ownerId, String operation) =>
      txn.insert(
          'sync_outbox',
          {
            'id': '$type:$id',
            'entity_type': type,
            'entity_id': id,
            'caregiver_id': ownerId,
            'operation': operation,
            'state': 'pending',
            'attempts': 0,
            'next_retry_at': null,
            'last_error': null,
            'updated_at': DateTime.now().toUtc().toIso8601String()
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

  String _tableForEntity(String type) => switch (type) {
        'caregiver' => 'caregiver_cache',
        'profile' => 'profiles',
        'deck' => 'decks',
        'card' => 'cards',
        'media' => 'media_files',
        _ => throw ArgumentError.value(type, 'type', 'Unsupported entity type')
      };

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
