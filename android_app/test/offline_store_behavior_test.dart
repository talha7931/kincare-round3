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

Future<void> createV4(Database db, int version) async {
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
    attempts INTEGER NOT NULL DEFAULT 0, next_retry_at TEXT, last_error TEXT,
    updated_at TEXT NOT NULL)''');
  await db.execute(
      'CREATE TABLE sync_meta (caregiver_id TEXT PRIMARY KEY, last_synced_at TEXT)');
  await db.execute(
      'CREATE INDEX outbox_owner_state_idx ON sync_outbox(caregiver_id,state,next_retry_at)');
  await db.execute(
      'CREATE INDEX sessions_owner_idx ON sessions(caregiver_id,profile_id,started_at)');
  await db.execute(
      'CREATE INDEX responses_session_idx ON responses(session_id,response_index)');
  await db.execute('''CREATE TABLE caregiver_cache (
    caregiver_id TEXT PRIMARY KEY, payload TEXT NOT NULL, cached_at TEXT NOT NULL)''');
  await db.execute('''CREATE TABLE cached_activity_sessions (
    id TEXT PRIMARY KEY, caregiver_id TEXT NOT NULL, profile_id TEXT NOT NULL,
    payload TEXT NOT NULL, cached_at TEXT NOT NULL)''');
  await db.execute('''CREATE TABLE cached_activity_responses (
    id TEXT PRIMARY KEY, caregiver_id TEXT NOT NULL, session_id TEXT NOT NULL,
    payload TEXT NOT NULL, cached_at TEXT NOT NULL)''');
  await db.execute('''CREATE TABLE cache_manifest (
    caregiver_id TEXT NOT NULL, item_type TEXT NOT NULL, item_id TEXT NOT NULL,
    state TEXT NOT NULL, error TEXT, updated_at TEXT NOT NULL,
    PRIMARY KEY(caregiver_id,item_type,item_id))''');
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

  test('fresh SQLite initialization creates the complete version 5 schema',
      () async {
    final freshPath =
        '${tempDir.path}${Platform.pathSeparator}fresh_offline.db';
    final store = OfflineStore.forTesting(freshPath);
    final db = await store.database;
    expect(await db.getVersion(), 5);
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
        'game_checkpoints',
        'sync_conflicts',
      ]),
    );
    expect(await db.rawQuery('PRAGMA foreign_key_list(cards)'), isNotEmpty);
    expect(await db.rawQuery('PRAGMA foreign_key_list(responses)'), isNotEmpty);
    await db.close();
  });

  test('v4 to v5 upgrade preserves activity, media and retry state', () async {
    final path = '${tempDir.path}${Platform.pathSeparator}v4_upgrade.db';
    final mediaPath = '${tempDir.path}${Platform.pathSeparator}legacy.mp3';
    await File(mediaPath).writeAsBytes([1, 2, 3]);
    final legacy = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(version: 4, onCreate: createV4));
    await legacy.insert('sessions', {
      'id': 'v4-session',
      'caregiver_id': 'owner-v4',
      'profile_id': 'profile-v4',
      'activity_key': 'memory_decks',
      'started_at': '2026-01-01T00:00:00Z',
      'status': 'in_progress',
    });
    await legacy.insert('responses', {
      'id': 'v4-response',
      'session_id': 'v4-session',
      'caregiver_id': 'owner-v4',
      'response_index': 0,
      'payload': '{"draft":true}',
      'responded_at': '2026-01-01T00:01:00Z',
    });
    await legacy.insert('media_files', {
      'caregiver_id': 'owner-v4',
      'asset_id': 'v4-asset',
      'local_path': mediaPath,
      'mime_type': 'audio/mpeg',
    });
    await legacy.insert('sync_outbox', {
      'id': 'response:v4-response',
      'entity_type': 'response',
      'entity_id': 'v4-response',
      'caregiver_id': 'owner-v4',
      'state': 'failed',
      'attempts': 2,
      'next_retry_at': '2026-01-02T00:00:00Z',
      'last_error': 'keep this retry state',
      'updated_at': '2026-01-01T00:01:00Z',
    });
    await legacy.insert('cached_activity_sessions', {
      'id': 'cached-v4',
      'caregiver_id': 'owner-v4',
      'profile_id': 'profile-v4',
      'payload': '{"id":"cached-v4"}',
      'cached_at': '2026-01-01T00:00:00Z',
    });
    await legacy.close();

    final store = OfflineStore.forTesting(path);
    final db = await store.database;
    expect(await db.getVersion(), 5);
    expect((await store.readSession('v4-session'))?['status'], 'in_progress');
    expect((await store.readResponses('v4-response')).single['payload'],
        '{"draft":true}');
    final outbox = await db.query('sync_outbox',
        where: 'entity_id = ?', whereArgs: ['v4-response']);
    expect(outbox.single['state'], 'failed');
    expect(outbox.single['attempts'], 2);
    expect(outbox.single['operation'], 'upsert');
    expect((await store.mediaRecord('owner-v4', 'v4-asset'))?['local_path'],
        mediaPath);
    expect(await File(mediaPath).exists(), isTrue);
    expect(await db.rawQuery('PRAGMA foreign_key_list(responses)'), isNotEmpty);
    final columns = await db.rawQuery('PRAGMA table_info(media_files)');
    expect(columns.map((row) => row['name']),
        containsAll(['upload_state', 'storage_path', 'file_size']));
    await db.close();
  });

  test('local profile, deck, card and media survive restart and cache refresh',
      () async {
    final path = '${tempDir.path}${Platform.pathSeparator}local_first.db';
    final store = OfflineStore.forTesting(path);
    final db = await store.database;
    await store.saveProfile('owner-local', {
      'id': 'profile-local',
      'caregiver_id': 'owner-local',
      'display_name': 'Local name',
      'preferred_language': 'hi',
    });
    await store.cacheProfiles('owner-local', [
      {
        'id': 'profile-local',
        'caregiver_id': 'owner-local',
        'display_name': 'Old cloud name',
        'preferred_language': 'en',
      }
    ]);
    expect((await store.readProfiles('owner-local')).single['display_name'],
        'Local name');
    expect(await store.readProfiles('owner-other'), isEmpty);

    final deck = {
      'id': 'deck-local',
      'elderly_profile_id': 'profile-local',
      'created_by_caregiver_id': 'owner-local',
      'title': 'Family memories',
      'language_code': 'hi',
      'created_at': '2026-05-01T00:00:00Z',
    };
    await store.saveDeckLocal('owner-local', 'profile-local', deck);
    final source = File('${tempDir.path}${Platform.pathSeparator}photo.jpg');
    await source.writeAsBytes([5, 6, 7, 8]);
    final mediaPath = await store.importLocalMedia(
      ownerId: 'owner-local',
      assetId: 'asset-local',
      profileId: 'profile-local',
      deckId: 'deck-local',
      cardId: 'card-local',
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      source: source,
      rootPath: tempDir.path,
    );
    await store.saveCardLocal('owner-local', 'deck-local', {
      'id': 'card-local',
      'deck_id': 'deck-local',
      'photo_asset_id': 'asset-local',
      'question_audio_asset_id': null,
      'answer_audio_asset_id': null,
      'question_text': 'What do you remember?',
      'answer_context': 'A story from home.',
      'display_order': 0,
    });
    await store.saveCardLocal('owner-local', 'deck-local', {
      'id': 'card-second',
      'deck_id': 'deck-local',
      'photo_asset_id': null,
      'question_text': 'Which memory comes next?',
      'answer_context': 'The next story.',
      'display_order': 1,
    });
    await store.reorderCardsLocal(
        'owner-local', 'deck-local', ['card-second', 'card-local']);
    expect(await File(mediaPath).readAsBytes(), [5, 6, 7, 8]);
    expect(await store.mediaPath('owner-other', 'asset-local'), isNull);
    final rows = await store.nextOutbox('owner-local', force: true);
    final typeOrder = rows.map((row) => row['entity_type']).toList();
    expect(typeOrder.indexOf('profile'), lessThan(typeOrder.indexOf('media')));
    expect(typeOrder.indexOf('media'), lessThan(typeOrder.indexOf('deck')));
    expect(typeOrder.indexOf('deck'), lessThan(typeOrder.indexOf('card')));

    await db.insert('sessions', {
      'id': 'checkpoint-session',
      'caregiver_id': 'owner-local',
      'profile_id': 'profile-local',
      'activity_key': 'everyday_object_sorting',
      'started_at': '2026-05-01T00:00:00Z',
      'status': 'in_progress',
    });
    await store.saveGameCheckpoint(
        caregiverId: 'owner-local',
        sessionId: 'checkpoint-session',
        gameKey: 'everyday_object_sorting',
        payload: {
          'placements': {'apple': 'fruit'},
          'odd_responses': {
            '0': {
              'id': 'odd-draft-0',
              'session_id': 'checkpoint-session',
              'response_index': 0,
              'response_payload': {
                'activity_type': 'odd_one_out',
                'selected_item_id': 'apple',
              },
              'is_correct': true,
            }
          },
        });
    await db.close();

    final reopened = OfflineStore.forTesting(path);
    expect(
        (await reopened.readDecks('owner-local', 'profile-local'))
            .single['title'],
        'Family memories');
    final reorderedCards =
        await reopened.readCards('owner-local', 'deck-local');
    expect(reorderedCards.map((card) => card['id']),
        ['card-second', 'card-local']);
    expect(reorderedCards.first['display_order'], 0);
    expect(await reopened.mediaPath('owner-local', 'asset-local'), mediaPath);
    expect(
        (await reopened.readGameCheckpoint(
            'owner-local', 'checkpoint-session'))?['placements'],
        {'apple': 'fruit'});
    expect(
        ((await reopened.readGameCheckpoint(
                'owner-local', 'checkpoint-session'))?['odd_responses']
            as Map)['0']['response_payload']['selected_item_id'],
        'apple');
    await (await reopened.database).close();
    final pendingPath = '${tempDir.path}${Platform.pathSeparator}pending.db';
    final pendingStore = OfflineStore.forTesting(pendingPath);
    final pendingDb = await pendingStore.database;
    await pendingStore.saveProfile('owner-pending', {
      'id': 'profile-pending',
      'caregiver_id': 'owner-pending',
      'display_name': 'Pending',
      'preferred_language': 'hi',
    });
    await pendingStore.clearSyncedCache('owner-pending');
    expect((await pendingStore.readProfiles('owner-pending')), hasLength(1));
    await pendingDb.close();
  });

  test('stale deck refresh cannot remove a card synchronized after fetch began',
      () async {
    final path = '${tempDir.path}${Platform.pathSeparator}card_refresh_race.db';
    final store = OfflineStore.forTesting(path);
    final db = await store.database;
    addTearDown(db.close);
    const ownerId = 'card-race-owner';
    const profileId = 'card-race-profile';
    const deckId = 'card-race-deck';
    const cardId = 'card-race-card';
    final deck = <String, dynamic>{
      'id': deckId,
      'elderly_profile_id': profileId,
      'created_by_caregiver_id': ownerId,
      'title': 'Dadi',
      'language_code': 'hi',
      'created_at': '2026-11-25T00:00:00Z',
    };
    await store.cacheDeck(ownerId, profileId, deck, []);

    await store.saveCardLocal(ownerId, deckId, {
      'id': cardId,
      'deck_id': deckId,
      'photo_asset_id': 'race-photo',
      'question_audio_asset_id': 'race-question-audio',
      'answer_audio_asset_id': 'race-answer-audio',
      'question_text': 'What do you remember about this photo?',
      'answer_context': 'A family memory.',
      'display_order': 0,
    });

    // A screen starts a cloud fetch while the card is still pending. Sync can
    // finish before that older, empty response is applied to the local cache.
    final snapshotStartedAt = DateTime.now().toUtc();
    await store.cacheDeck(ownerId, profileId, deck, [],
        remoteSnapshotStartedAt: snapshotStartedAt);
    final pendingCards = await store.readCards(ownerId, deckId);
    expect(pendingCards, hasLength(1));
    expect(pendingCards.single['_sync_state'], 'pending_create');

    final syncSnapshot = await store.syncEntity(ownerId, 'card', cardId);
    expect(syncSnapshot, isNotNull);
    await store.markEntitySynced(
      ownerId,
      'card',
      cardId,
      'upsert',
      expectedRevision: syncSnapshot!['sync_revision'] as String,
    );
    final syncedCard = await store.syncEntity(ownerId, 'card', cardId);
    expect(syncedCard?['sync_state'], 'synced');
    expect(
        DateTime.parse(syncedCard!['cached_at'] as String)
            .toUtc()
            .isBefore(snapshotStartedAt),
        isFalse);
    expect(
        (await store.nextOutbox(ownerId, force: true))
            .where((row) => row['entity_id'] == cardId),
        isEmpty);

    await store.cacheDeck(ownerId, profileId, deck, [],
        remoteSnapshotStartedAt: snapshotStartedAt);
    final visibleCards = await store.readCards(ownerId, deckId);
    expect(visibleCards, hasLength(1));
    expect(visibleCards.single['id'], cardId);
    expect(visibleCards.single['deck_id'], deckId);
    expect(visibleCards.single['photo_asset_id'], 'race-photo');
    expect(visibleCards.single['question_text'],
        'What do you remember about this photo?');
    expect(visibleCards.single['answer_context'], 'A family memory.');

    // A later authoritative cloud refresh that includes the card should keep
    // the same local identity and content.
    await store.cacheDeck(ownerId, profileId, deck, [
      {
        'id': cardId,
        'deck_id': deckId,
        'photo_asset_id': 'race-photo',
        'question_audio_asset_id': 'race-question-audio',
        'answer_audio_asset_id': 'race-answer-audio',
        'question_text': 'What do you remember about this photo?',
        'answer_context': 'A family memory.',
        'display_order': 0,
      }
    ]);
    expect(await store.readCards(ownerId, deckId), hasLength(1));
    await store.cacheDeck(ownerId, profileId, deck, [],
        remoteSnapshotStartedAt:
            DateTime.now().toUtc().add(const Duration(seconds: 1)));
    expect(await store.readCards(ownerId, deckId), isEmpty);
    await db.close();
  });

  test(
      'failed card sync keeps content visible and retries one stable outbox row',
      () async {
    final path = '${tempDir.path}${Platform.pathSeparator}card_retry_state.db';
    final store = OfflineStore.forTesting(path);
    final db = await store.database;
    addTearDown(db.close);
    const ownerId = 'card-retry-owner';
    const profileId = 'card-retry-profile';
    const deckId = 'card-retry-deck';
    const cardId = 'card-retry-card';
    final deck = <String, dynamic>{
      'id': deckId,
      'elderly_profile_id': profileId,
      'created_by_caregiver_id': ownerId,
      'title': 'Dadi',
      'language_code': 'hi',
    };
    await store.cacheDeck(ownerId, profileId, deck, []);
    final card = <String, dynamic>{
      'id': cardId,
      'deck_id': deckId,
      'photo_asset_id': 'retry-photo',
      'question_audio_asset_id': 'retry-question-audio',
      'answer_audio_asset_id': 'retry-answer-audio',
      'question_text': 'Who is in this photograph?',
      'answer_context': 'A family gathering.',
      'display_order': 0,
    };

    await expectLater(
      store.saveCardLocal(ownerId, deckId, {...card, 'deck_id': 'wrong-deck'}),
      throwsStateError,
    );
    expect(await store.readCards(ownerId, deckId), isEmpty);
    expect(await store.nextOutbox(ownerId, force: true), isEmpty);

    await store.saveCardLocal(ownerId, deckId, card);
    await store.markFailed('card', cardId, 'Temporary media upload failure',
        caregiverId: ownerId);
    final visible = await store.readCards(ownerId, deckId);
    expect(visible, hasLength(1));
    expect(visible.single['question_text'], 'Who is in this photograph?');
    expect(visible.single['answer_context'], 'A family gathering.');
    expect(visible.single['photo_asset_id'], 'retry-photo');
    expect(visible.single['_sync_state'], 'failed');

    final retryRows = await store.nextOutbox(ownerId, force: true);
    final cardRetryRows =
        retryRows.where((row) => row['entity_id'] == cardId).toList();
    expect(cardRetryRows, hasLength(1));
    expect(cardRetryRows.single['id'], 'card:$cardId');
    expect(cardRetryRows.single['state'], 'failed');
    expect(
        cardRetryRows.single['last_error'], 'Temporary media upload failure');

    final snapshot = await store.syncEntity(ownerId, 'card', cardId);
    await store.markEntitySynced(
      ownerId,
      'card',
      cardId,
      'upsert',
      expectedRevision: snapshot!['sync_revision'] as String,
    );
    expect(await store.nextOutbox(ownerId, force: true), isEmpty);
    expect((await store.readCards(ownerId, deckId)).single['_sync_state'],
        'synced');
  });

  test('offline caregiver and profile CRUD preserve owner and history',
      () async {
    final store = OfflineStore.forTesting(
        '${tempDir.path}${Platform.pathSeparator}local_crud.db');
    final db = await store.database;
    await store.saveCaregiverLocal('owner-crud', {
      'id': 'owner-crud',
      'display_name': 'Local caregiver',
    });
    await store.cacheCaregiver('owner-crud', {
      'id': 'owner-crud',
      'display_name': 'Older cloud name',
    });
    expect((await store.readCaregiver('owner-crud'))?['display_name'],
        'Local caregiver');
    expect(await store.readCaregiver('another-caregiver'), isNull);

    await store.saveProfile('owner-crud', {
      'id': 'profile-crud',
      'caregiver_id': 'owner-crud',
      'display_name': 'Before edit',
      'preferred_language': 'hi',
    });
    await store.saveProfile('owner-crud', {
      'id': 'profile-crud',
      'caregiver_id': 'owner-crud',
      'display_name': 'After edit',
      'preferred_language': 'hi',
    });
    expect((await store.readProfiles('owner-crud')).single['display_name'],
        'After edit');
    await store.saveDeckLocal('owner-crud', 'profile-crud', {
      'id': 'deck-crud',
      'elderly_profile_id': 'profile-crud',
      'created_by_caregiver_id': 'owner-crud',
      'title': 'Local deck',
      'language_code': 'hi',
    });
    await store.saveCardLocal('owner-crud', 'deck-crud', {
      'id': 'card-crud',
      'deck_id': 'deck-crud',
      'question_text': 'A local question',
      'answer_context': 'A local story',
      'display_order': 0,
    });
    await store.createSession(
        id: 'history-crud',
        caregiverId: 'owner-crud',
        profileId: 'profile-crud',
        activityKey: 'memory_decks',
        activityTypeId: null,
        deviceId: 'device-crud',
        memoryDeckId: 'deck-crud',
        startedAt: '2026-06-01T00:00:00Z');
    await store.saveResponses('history-crud', 'owner-crud', [
      {
        'id': 'response-crud',
        'response_index': 0,
        'response_payload': {'card_id': 'card-crud', 'text': 'My memory'},
      }
    ]);

    await store.deleteProfile('owner-crud', 'profile-crud');
    expect(await store.readProfiles('owner-crud'), isEmpty);
    expect(await store.readProfiles('another-caregiver'), isEmpty);
    expect(await store.readDecks('owner-crud', 'profile-crud'), isEmpty);
    expect(await store.readCards('owner-crud', 'deck-crud'), isEmpty);
    expect(await store.readSession('history-crud'), isNotNull);
    expect(await store.readResponses('response-crud'), hasLength(1));
    final deletions = (await store.nextOutbox('owner-crud', force: true))
        .where((row) => row['operation'] == 'delete')
        .map((row) => row['entity_type'])
        .toSet();
    expect(deletions, containsAll(['profile', 'deck', 'card']));
    await db.close();
    final reopened = OfflineStore.forTesting(
        '${tempDir.path}${Platform.pathSeparator}local_crud.db');
    expect((await reopened.readCaregiver('owner-crud'))?['display_name'],
        'Local caregiver');
    expect(await reopened.readCaregiver('another-caregiver'), isNull);
    expect(await reopened.readSession('history-crud'), isNotNull);
    await (await reopened.database).close();
  });

  test('entity plus outbox writes and session completion roll back atomically',
      () async {
    final store = OfflineStore.forTesting(
        '${tempDir.path}${Platform.pathSeparator}rollback.db');
    final db = await store.database;
    await db.execute(
        '''CREATE TRIGGER fail_profile_queue BEFORE INSERT ON sync_outbox
      WHEN NEW.entity_id = 'rollback-profile'
      BEGIN SELECT RAISE(ABORT, 'forced queue failure'); END''');
    await expectLater(
        store.saveProfile('owner-tx', {
          'id': 'rollback-profile',
          'caregiver_id': 'owner-tx',
          'display_name': 'Must roll back',
          'preferred_language': 'hi',
        }),
        throwsA(isA<Exception>()));
    expect(await store.readProfiles('owner-tx'), isEmpty);
    expect(
        await db.query('sync_outbox',
            where: 'entity_id = ?', whereArgs: ['rollback-profile']),
        isEmpty);
    await db.execute('DROP TRIGGER fail_profile_queue');

    await store.createSession(
        id: 'atomic-session',
        caregiverId: 'owner-tx',
        profileId: 'profile-tx',
        activityKey: 'memory_decks',
        activityTypeId: null,
        deviceId: 'device-tx',
        memoryDeckId: 'deck-tx',
        startedAt: '2026-06-01T00:00:00Z');
    await db.execute(
        '''CREATE TRIGGER fail_response_queue BEFORE INSERT ON sync_outbox
      WHEN NEW.entity_type = 'response'
      BEGIN SELECT RAISE(ABORT, 'forced response queue failure'); END''');
    final response = {
      'id': 'atomic-response',
      'response_index': 0,
      'response_payload': {
        'activity_type': 'memory_decks',
        'card_id': 'card-tx'
      },
      'is_correct': null,
    };
    await expectLater(
        store.completeSessionWithResponses(
            'atomic-session', 'owner-tx', [response]),
        throwsA(isA<Exception>()));
    expect(
        (await store.readSession('atomic-session'))?['status'], 'in_progress');
    expect(await store.readResponses('atomic-response'), isEmpty);
    await db.execute('DROP TRIGGER fail_response_queue');

    await store
        .completeSessionWithResponses('atomic-session', 'owner-tx', [response]);
    await store
        .completeSessionWithResponses('atomic-session', 'owner-tx', [response]);
    expect((await store.readSession('atomic-session'))?['status'], 'completed');
    expect(await store.readResponses('atomic-response'), hasLength(1));
    expect(
        (await db.query('sync_outbox',
                where: 'entity_id = ?', whereArgs: ['atomic-response']))
            .length,
        1);
    await db.close();
  });

  test(
      'v1 upgrade is additive; local writes, rollback, cache and owner scope work',
      () async {
    final store = OfflineStore.instance;
    final db = await store.database;
    expect(await db.getVersion(), 5);
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
