import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:kincare_android/offline_cache_preparation.dart';
import 'package:kincare_android/offline_store.dart';

Future<void> createV1(Database db, int version) async {
  for (final sql in [
    'CREATE TABLE profiles (caregiver_id TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, cached_at TEXT NOT NULL, PRIMARY KEY(caregiver_id,id))',
    'CREATE TABLE decks (caregiver_id TEXT NOT NULL,id TEXT NOT NULL,profile_id TEXT NOT NULL,payload TEXT NOT NULL,cached_at TEXT NOT NULL,PRIMARY KEY(caregiver_id,id))',
    'CREATE TABLE cards (caregiver_id TEXT NOT NULL,id TEXT NOT NULL,deck_id TEXT NOT NULL,payload TEXT NOT NULL,cached_at TEXT NOT NULL,PRIMARY KEY(caregiver_id,id))',
    'CREATE TABLE devices (caregiver_id TEXT NOT NULL,device_uuid TEXT NOT NULL,device_id TEXT NOT NULL,revoked_at TEXT,PRIMARY KEY(caregiver_id,device_uuid))',
    'CREATE TABLE media_files (caregiver_id TEXT NOT NULL,asset_id TEXT NOT NULL,local_path TEXT NOT NULL,mime_type TEXT,PRIMARY KEY(caregiver_id,asset_id))',
    "CREATE TABLE sessions (id TEXT PRIMARY KEY,caregiver_id TEXT NOT NULL,profile_id TEXT NOT NULL,activity_key TEXT NOT NULL,activity_type_id TEXT,device_id TEXT,memory_deck_id TEXT,started_at TEXT NOT NULL,completed_at TEXT,status TEXT NOT NULL,sync_state TEXT NOT NULL DEFAULT 'pending')",
    "CREATE TABLE responses (id TEXT PRIMARY KEY,session_id TEXT NOT NULL,caregiver_id TEXT NOT NULL,response_index INTEGER NOT NULL,payload TEXT NOT NULL,is_correct INTEGER,responded_at TEXT NOT NULL,sync_state TEXT NOT NULL DEFAULT 'pending')",
    "CREATE TABLE sync_outbox (id TEXT PRIMARY KEY,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,caregiver_id TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,next_retry_at TEXT,last_error TEXT,updated_at TEXT NOT NULL)",
    'CREATE TABLE sync_meta (caregiver_id TEXT PRIMARY KEY,last_synced_at TEXT)',
    'CREATE INDEX outbox_owner_state_idx ON sync_outbox(caregiver_id,state,next_retry_at)',
    'CREATE INDEX sessions_owner_idx ON sessions(caregiver_id,profile_id,started_at)',
    'CREATE INDEX responses_session_idx ON responses(session_id,response_index)',
  ]) {
    await db.execute(sql);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = await Directory.systemTemp.createTemp('kincare_phase5_sqlite_');
    await databaseFactory.setDatabasesPath(tempDir.path);
    final v1 = await databaseFactory.openDatabase(
      '${tempDir.path}${Platform.pathSeparator}kincare_offline.db',
      options: OpenDatabaseOptions(version: 1, onCreate: createV1),
    );
    await v1.insert('sessions', {
      'id': 'preexisting-session',
      'caregiver_id': 'owner-a',
      'profile_id': 'profile-a',
      'activity_key': 'odd_one_out',
      'started_at': '2026-01-01T00:00:00Z',
      'status': 'completed',
    });
    await v1.insert('decks', {
      'caregiver_id': 'owner-a',
      'id': 'legacy-deck',
      'profile_id': 'profile-a',
      'payload': '{"id":"legacy-deck"}',
      'cached_at': '2026-01-01T00:00:00Z',
    });
    await v1.insert('cards', {
      'caregiver_id': 'owner-a',
      'id': 'legacy-card',
      'deck_id': 'legacy-deck',
      'payload': '{"id":"legacy-card"}',
      'cached_at': '2026-01-01T00:00:00Z',
    });
    await v1.insert('sync_outbox', {
      'id': 'session:preexisting-session',
      'entity_type': 'session',
      'entity_id': 'preexisting-session',
      'caregiver_id': 'owner-a',
      'state': 'pending',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    await v1.insert('responses', {
      'id': 'preexisting-response',
      'session_id': 'preexisting-session',
      'caregiver_id': 'owner-a',
      'response_index': 0,
      'payload': '{"ok":true}',
      'responded_at': '2026-01-01T00:01:00Z',
    });
    await v1.close();
  });

  tearDownAll(() async {
    await OfflineStore.instance.database.then((db) => db.close());
    await tempDir.delete(recursive: true);
  });

  test('fresh SQLite initialization creates the complete version 4 schema',
      () async {
    final freshPath =
        '${tempDir.path}${Platform.pathSeparator}fresh_offline.db';
    final store = OfflineStore.forTesting(freshPath);
    final db = await store.database;
    expect(await db.getVersion(), 4);
    final tables =
        await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
    expect(
      tables.map((row) => row['name']).toSet(),
      containsAll([
        'profiles',
        'decks',
        'cards',
        'devices',
        'media_files',
        'sessions',
        'responses',
        'sync_outbox',
        'sync_meta',
        'caregiver_cache',
        'cached_activity_sessions',
        'cached_activity_responses',
        'cache_manifest',
      ]),
    );
    expect(await db.rawQuery('PRAGMA foreign_key_list(cards)'), isNotEmpty);
    expect(await db.rawQuery('PRAGMA foreign_key_list(responses)'), isNotEmpty);
    await db.close();
  });

  test(
      'v1 upgrade is additive; local writes, rollback, cache and owner scope work',
      () async {
    final store = OfflineStore.instance;
    final db = await store.database;
    expect(await db.getVersion(), 4);
    final tables =
        await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
    final names = tables.map((row) => row['name']).toSet();
    expect(
        names,
        containsAll([
          'sessions',
          'responses',
          'sync_outbox',
          'caregiver_cache',
          'cache_manifest',
          'cached_activity_sessions',
          'cached_activity_responses'
        ]));
    expect(await store.readSession('preexisting-session'), isNotNull);
    expect(
        (await store.readResponses('preexisting-response'))
            .single['session_id'],
        'preexisting-session');
    final foreignKeys = await db.rawQuery('PRAGMA foreign_key_list(responses)');
    expect(foreignKeys.any((row) => row['table'] == 'sessions'), isTrue);
    final cardForeignKeys = await db.rawQuery('PRAGMA foreign_key_list(cards)');
    expect(cardForeignKeys.any((row) => row['table'] == 'decks'), isTrue);
    expect((await store.readCards('owner-a', 'legacy-deck')).single['id'],
        'legacy-card');
    await expectLater(
      db.insert('responses', {
        'id': 'orphan-response',
        'session_id': 'missing-session',
        'caregiver_id': 'owner-a',
        'response_index': 0,
        'payload': '{}',
        'responded_at': '2026-01-01T00:00:00Z',
      }),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      db.insert('cards', {
        'caregiver_id': 'owner-a',
        'id': 'orphan-card',
        'deck_id': 'missing-deck',
        'payload': '{}',
        'cached_at': '2026-01-01T00:00:00Z',
      }),
      throwsA(isA<Exception>()),
    );
    expect((await store.nextOutbox('owner-a', force: true)).single['entity_id'],
        'preexisting-session');

    await store.createSession(
        id: 'session-b',
        caregiverId: 'owner-a',
        profileId: 'profile-a',
        activityKey: 'odd_one_out',
        activityTypeId: 'type-1',
        deviceId: 'device-a',
        startedAt: '2026-02-01T00:00:00Z');
    await store.createSession(
        id: 'session-c',
        caregiverId: 'owner-a',
        profileId: 'profile-a',
        activityKey: 'sorting',
        activityTypeId: 'type-2',
        deviceId: 'device-a',
        startedAt: '2026-02-02T00:00:00Z');
    await store.saveResponses('session-c', 'owner-a', [
      {
        'id': 'collision',
        'response_index': 0,
        'response_payload': {'x': 0},
        'is_correct': true
      },
    ]);
    await expectLater(
        store.saveResponses('session-b', 'owner-a', [
          {
            'id': 'rollback-me',
            'response_index': 0,
            'response_payload': {'x': 1},
            'is_correct': true
          },
          {
            'id': 'collision',
            'response_index': 1,
            'response_payload': {'x': 2},
            'is_correct': false
          },
        ]),
        throwsStateError);
    expect(await store.readResponses('rollback-me'), isEmpty);
    expect(
        (await db.query('sync_outbox',
            where: 'entity_id = ?', whereArgs: ['rollback-me'])),
        isEmpty);

    await store.setCacheItem(
        'owner-a', 'deck', 'deck-a', 'partial', 'asset missing');
    await store.setCacheItem('owner-b', 'deck', 'deck-a', 'ready');
    final ownerA = await store.cacheItems('owner-a');
    expect(ownerA.single['state'], 'partial');
    expect((await store.cacheItems('owner-b')).single['state'], 'ready');
    expect(ownerA, hasLength(1));

    await store.cacheHistory('owner-a', [
      {
        'id': 'history-a',
        'caregiver_id': 'owner-a',
        'elderly_profile_id': 'profile-a',
        'status': 'completed'
      },
      {
        'id': 'history-b',
        'caregiver_id': 'owner-b',
        'elderly_profile_id': 'profile-b',
        'status': 'completed'
      },
    ], [
      {
        'id': 'response-a',
        'session_id': 'history-a',
        'response_index': 0,
        'response_payload': {'schema_version': 1}
      },
      {
        'id': 'response-b',
        'session_id': 'history-b',
        'response_index': 0,
        'response_payload': {'schema_version': 1}
      },
    ]);
    expect(
        (await store.cachedHistory('owner-a', ['profile-a']))
            .map((r) => r['id']),
        ['history-a']);
    final responseRows =
        await store.cachedResponses('owner-a', ['history-a', 'history-b']);
    expect(responseRows, hasLength(1));
    expect(responseRows.single['session_id'], 'history-a');

    await store.cacheCaregiver('owner-a', {'display_name': 'Caregiver A'});
    await store.cacheCaregiver('owner-b', {'display_name': 'Caregiver B'});
    expect(
        (await store.readCaregiver('owner-a'))?['display_name'], 'Caregiver A');
    expect(await store.readCaregiver('owner-c'), isNull);

    await store.cacheDeck('owner-a', 'profile-a', {
      'id': 'deck-a',
      'title': 'A'
    }, [
      {'id': 'card-a', 'display_order': 0, 'question_text': 'Question'},
    ]);
    final localDecks = await store.readDecks('owner-a', 'profile-a');
    final localDeck = localDecks.singleWhere((deck) => deck['id'] == 'deck-a');
    expect(localDeck['id'], 'deck-a');
    expect(localDeck['_offline_status'], 'partial');
    await store.cacheDeckMetadata(
        'owner-a', 'profile-a', {'id': 'deck-a', 'title': 'Updated title'});
    expect(await store.readCards('owner-a', 'deck-a'), hasLength(1));
    expect(await store.readDecks('owner-b', 'profile-a'), isEmpty);
    expect((await store.readCards('owner-a', 'deck-a')).single['id'], 'card-a');

    final mediaFile =
        File('${tempDir.path}${Platform.pathSeparator}cached-photo.bin');
    await mediaFile.writeAsBytes([1, 2, 3]);
    await db.insert('media_files', {
      'caregiver_id': 'owner-a',
      'asset_id': 'asset-a',
      'local_path': mediaFile.path,
      'mime_type': 'image/jpeg'
    });
    expect(await store.mediaPath('owner-a', 'asset-a'), mediaFile.path);
    expect(await store.mediaPath('owner-b', 'asset-a'), isNull);

    var downloads = 0;
    final verifiedPath = await store.cacheMediaIfNeeded(
      'owner-a',
      'asset-verified',
      () async {
        downloads++;
        return [10, 20, 30, 40];
      },
      'audio/mpeg',
      extension: 'mp3',
      expectedBytes: 4,
      rootPath: tempDir.path,
    );
    expect(await File(verifiedPath).readAsBytes(), [10, 20, 30, 40]);
    expect(await store.allMediaCached('owner-a', ['asset-verified']), isTrue);
    expect(await store.allMediaCached('owner-a', ['asset-verified', 'missing']),
        isFalse);
    final reusedPath = await store.cacheMediaIfNeeded(
      'owner-a',
      'asset-verified',
      () async {
        downloads++;
        return [99];
      },
      'audio/mpeg',
      extension: 'mp3',
      rootPath: tempDir.path,
    );
    expect(reusedPath, verifiedPath);
    expect(downloads, 1,
        reason: 'A verified media file must be reused on retry.');

    final stalePart = File(
        '${tempDir.path}${Platform.pathSeparator}media${Platform.pathSeparator}owner-a${Platform.pathSeparator}asset-stale.mp3.part-old');
    await stalePart.parent.create(recursive: true);
    await stalePart.writeAsBytes([1]);
    await stalePart
        .setLastModified(DateTime.now().subtract(const Duration(hours: 2)));
    await store.cacheMediaIfNeeded(
      'owner-a',
      'asset-stale',
      () async => [2, 3],
      'audio/mpeg',
      extension: 'mp3',
      rootPath: tempDir.path,
    );
    expect(await stalePart.exists(), isFalse);

    var concurrentDownloads = 0;
    Future<String> concurrentCache() => store.cacheMediaIfNeeded(
          'owner-a',
          'asset-concurrent',
          () async {
            concurrentDownloads++;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return [5, 6, 7];
          },
          'audio/mpeg',
          extension: 'mp3',
          rootPath: tempDir.path,
        );
    final concurrentPaths = await Future.wait([
      concurrentCache(),
      concurrentCache(),
    ]);
    expect(concurrentPaths.first, concurrentPaths.last);
    expect(concurrentDownloads, 1);

    await expectLater(
      store.cacheMediaIfNeeded(
        'owner-a',
        'asset-empty',
        () async => <int>[],
        'audio/mpeg',
        extension: 'mp3',
        rootPath: tempDir.path,
      ),
      throwsStateError,
    );
    expect(await store.mediaPath('owner-a', 'asset-empty'), isNull);

    await db.insert('sessions', {
      'id': 'synced-session',
      'caregiver_id': 'owner-a',
      'profile_id': 'profile-a',
      'activity_key': 'odd_one_out',
      'started_at': '2026-03-01T00:00:00Z',
      'completed_at': '2026-03-01T00:01:00Z',
      'status': 'completed',
      'sync_state': 'synced',
    });
    await db.insert('sync_outbox', {
      'id': 'session:synced-session',
      'entity_type': 'session',
      'entity_id': 'synced-session',
      'caregiver_id': 'owner-a',
      'state': 'synced',
      'updated_at': '2026-03-01T00:01:00Z',
    });
    await store.saveResponses('session-b', 'owner-a', [
      {
        'id': 'pending-response',
        'response_index': 0,
        'response_payload': {'pending': true},
        'is_correct': null
      },
    ]);
    await store.clearSyncedCache('owner-a');
    expect(await store.readSession('preexisting-session'), isNotNull);
    expect(await store.readSession('synced-session'), isNull);
    expect((await store.readResponses('pending-response')).single['session_id'],
        'session-b');
    expect(
        (await store.nextOutbox('owner-a', force: true))
            .any((r) => r['entity_id'] == 'preexisting-session'),
        isTrue);
    expect(
        (await store.nextOutbox('owner-a', force: true))
            .any((r) => r['entity_id'] == 'pending-response'),
        isTrue);
    expect(await store.readProfiles('owner-a'), isEmpty);
    expect(await store.mediaPath('owner-a', 'asset-a'), isNull);
    expect(await store.mediaPath('owner-a', 'asset-verified'), isNull);
  });

  test('historical pagination fetches every row beyond 500 without duplicates',
      () async {
    final sourceRows = List<int>.generate(1207, (i) => i);
    final requestedOffsets = <int>[];
    final result = await fetchAllPages<int>((from, to) async {
      requestedOffsets.add(from);
      if (from >= sourceRows.length) return [];
      return sourceRows.sublist(from, (to + 1).clamp(0, sourceRows.length));
    });

    expect(requestedOffsets, [0, 500, 1000]);
    expect(result, hasLength(1207));
    expect(result.toSet(), hasLength(1207));
    expect(result.first, 0);
    expect(result.last, 1206);
  });

  test(
      'outbox retries transition safely and retain one stable entry per activity',
      () async {
    final store = OfflineStore.instance;
    await store.createSession(
      id: 'sync-state-session',
      caregiverId: 'owner-sync',
      profileId: 'profile-sync',
      activityKey: 'odd_one_out',
      activityTypeId: 'type-sync',
      deviceId: 'device-sync',
      startedAt: '2026-04-01T00:00:00Z',
    );
    await store.finishSession('sync-state-session', 'completed',
        completedAt: '2026-04-01T00:01:00Z');

    final outbox = await store.nextOutbox('owner-sync', force: true);
    expect(outbox.where((row) => row['entity_id'] == 'sync-state-session'),
        hasLength(1));
    await store.markFailed(
        'session', 'sync-state-session', 'temporary failure');
    expect((await store.readSession('sync-state-session'))?['sync_state'],
        'failed');
    expect((await store.nextOutbox('owner-sync', force: true)).single['state'],
        'failed');

    final marked = await store.markSynced(
      'session',
      'sync-state-session',
      expectedStatus: 'completed',
      expectedCompletedAt: '2026-04-01T00:01:00Z',
    );
    expect(marked, isTrue);
    expect((await store.readSession('sync-state-session'))?['sync_state'],
        'synced');
    expect(await store.nextOutbox('owner-sync', force: true), isEmpty);

    await store.createSession(
      id: 'interrupted-session',
      caregiverId: 'owner-sync',
      profileId: 'profile-sync',
      activityKey: 'sorting',
      activityTypeId: 'type-sorting',
      deviceId: 'device-sync',
      startedAt: '2026-04-02T00:00:00Z',
    );
    final beforeCompletion = await store.readSession('interrupted-session');
    await store.finishSession('interrupted-session', 'completed',
        completedAt: '2026-04-02T00:02:00Z');
    final staleAcknowledgement = await store.markSynced(
      'session',
      'interrupted-session',
      expectedStatus: beforeCompletion?['status']?.toString(),
      expectedCompletedAt: beforeCompletion?['completed_at']?.toString(),
    );
    expect(staleAcknowledgement, isFalse);
    expect((await store.readSession('interrupted-session'))?['sync_state'],
        'pending');
  });

  test(
      'cache manifest reflects partial and ready deck states after verification',
      () async {
    final store = OfflineStore.instance;
    await store.cacheDeck('owner-c', 'profile-c', {
      'id': 'deck-c'
    }, [
      {'id': 'card-c', 'photo_asset_id': 'photo-c'},
    ]);
    await store.setCacheItem(
        'owner-c', 'deck', 'deck-c', 'partial', 'Photo missing.');
    expect(
        (await store.readDecks('owner-c', 'profile-c'))
            .single['_offline_status'],
        'partial');

    await store.cacheMedia('owner-c', 'photo-c', [1, 2, 3], 'image/jpeg',
        extension: 'jpg', rootPath: tempDir.path);
    expect(await store.allMediaCached('owner-c', ['photo-c']), isTrue);
    await store.setCacheItem('owner-c', 'deck', 'deck-c', 'ready');
    expect(
        (await store.readDecks('owner-c', 'profile-c'))
            .single['_offline_status'],
        'ready');
  });

  test('cache progress reports pending work and explicit preparation states',
      () {
    const preparing = CachePreparationSnapshot(2, 5, 0, true);
    expect(preparing.status, CachePreparationStatus.preparing);
    expect(preparing.pending, 3);
    expect(preparing.progress, 0.4);

    const partial = CachePreparationSnapshot(5, 5, 2, false);
    expect(partial.status, CachePreparationStatus.partiallyReady);
    expect(partial.pending, 0);

    const waiting = CachePreparationSnapshot(0, 0, 0, false,
        explicitStatus: CachePreparationStatus.waitingForConnection);
    expect(waiting.status, CachePreparationStatus.waitingForConnection);

    const retrying = CachePreparationSnapshot(1, 4, 0, true,
        explicitStatus: CachePreparationStatus.retrying);
    expect(retrying.status, CachePreparationStatus.retrying);
  });
}
