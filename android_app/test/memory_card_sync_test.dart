import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:kincare_android/offline_store.dart';
import 'package:kincare_android/offline_sync.dart';

class _LocalSupabaseServer {
  static const url = 'http://supabase.mock';
  final String ownerId;
  final String deckId;
  final Map<String, Map<String, dynamic>> cards = {};
  bool failBeforeInsert = false;
  bool loseInsertResponse = false;
  int insertAttempts = 0;

  _LocalSupabaseServer({required this.ownerId, required this.deckId});

  String get supabaseUrl => url;

  http.Client get httpClient => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    try {
      final table =
          request.url.pathSegments.isEmpty ? '' : request.url.pathSegments.last;
      if (request.method == 'GET' && table == 'caregivers') {
        return _respond(request, 200, [
          {'id': ownerId}
        ]);
      }
      if (request.method == 'GET' && table == 'memory_decks') {
        return _respond(request, 200, [
          {
            'id': deckId,
            'created_by_caregiver_id': ownerId,
          }
        ]);
      }
      if (table == 'memory_cards' && request.method == 'GET') {
        final filter = request.url.queryParameters['id'];
        final id = filter != null && filter.startsWith('eq.')
            ? filter.substring(3)
            : null;
        final row = id == null ? null : cards[id];
        return _respond(request, 200, row == null ? <Object>[] : [row]);
      }
      if (table == 'memory_cards' && request.method == 'POST') {
        insertAttempts++;
        final value =
            Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        if (failBeforeInsert) {
          return _respond(
              request, 503, {'message': 'simulated temporary outage'});
        }
        cards.putIfAbsent(value['id'].toString(), () => value);
        if (loseInsertResponse) {
          loseInsertResponse = false;
          return _respond(request, 500, {'message': 'simulated lost response'});
        }
        return _respond(request, 201, null);
      }
      return _respond(request, 404, {'message': 'unexpected test request'});
    } catch (_) {
      return _respond(request, 500, {'message': 'local test server error'});
    }
  }

  http.Response _respond(http.Request request, int status, Object? body) =>
      http.Response(
        body == null ? '' : jsonEncode(body),
        status,
        request: request,
        headers: const {'content-type': 'application/json'},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = await Directory.systemTemp.createTemp('kincare_card_sync_');
    await databaseFactory.setDatabasesPath(tempDir.path);
  });

  tearDownAll(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<({OfflineStore store, SupabaseClient client, OfflineSyncService sync})>
      createHarness(_LocalSupabaseServer remote, String name) async {
    final store = OfflineStore.forTesting(
        '${tempDir.path}${Platform.pathSeparator}$name.db');
    final client = SupabaseClient(remote.supabaseUrl, 'test-anon-key',
        httpClient: remote.httpClient);
    final sync = OfflineSyncService.forTesting(
      client: client,
      store: store,
      ownerId: remote.ownerId,
      networkAvailable: () async => true,
      internetAvailable: () async => true,
      currentUserId: () => remote.ownerId,
    );
    return (store: store, client: client, sync: sync);
  }

  Future<void> seedCard(
      OfflineStore store, String ownerId, String deckId, String cardId) async {
    final deck = <String, dynamic>{
      'id': deckId,
      'elderly_profile_id': 'profile-$deckId',
      'created_by_caregiver_id': ownerId,
      'title': 'Dadi',
      'language_code': 'hi',
    };
    await store.cacheDeck(ownerId, 'profile-$deckId', deck, []);
    await store.saveCardLocal(ownerId, deckId, {
      'id': cardId,
      'deck_id': deckId,
      'photo_asset_id': 'photo-$cardId',
      'question_audio_asset_id': 'question-audio-$cardId',
      'answer_audio_asset_id': 'answer-audio-$cardId',
      'question_text': 'What do you remember?',
      'answer_context': 'A family memory.',
      'display_order': 0,
    });
  }

  test('failed card sync retains card and exposes a retryable error state',
      () async {
    final remote = _LocalSupabaseServer(
        ownerId: 'test-owner-failure', deckId: 'test-deck-failure');
    final harness = await createHarness(remote, 'failed_card');
    addTearDown(harness.client.dispose);
    addTearDown(harness.sync.dispose);
    addTearDown(() async => (await harness.store.database).close());
    await seedCard(harness.store, remote.ownerId, remote.deckId, 'failed-card');

    remote.failBeforeInsert = true;
    await harness.sync.syncNow(forceRetry: true);

    final failedCard =
        (await harness.store.readCards(remote.ownerId, remote.deckId)).single;
    expect(failedCard['id'], 'failed-card');
    expect(failedCard['_sync_state'], 'failed');
    expect(harness.sync.snapshot.failed, 1);
    final failedOutbox =
        (await harness.store.nextOutbox(remote.ownerId, force: true))
            .where((row) => row['entity_id'] == 'failed-card')
            .single;
    expect(failedOutbox['state'], 'failed');
    expect(failedOutbox['id'], 'card:failed-card');
    expect(failedOutbox['last_error'], isNotEmpty);

    remote.failBeforeInsert = false;
    await harness.sync.syncNow(forceRetry: true);
    expect(remote.insertAttempts, 2);
    expect(remote.cards, hasLength(1));
    expect(
        (await harness.store.readCards(remote.ownerId, remote.deckId))
            .single['_sync_state'],
        'synced');
    expect(
        await harness.store.nextOutbox(remote.ownerId, force: true), isEmpty);
  });

  test(
      'lost insert response is confirmed by stable ID and retry creates one row',
      () async {
    final remote = _LocalSupabaseServer(
        ownerId: 'test-owner-idempotent', deckId: 'test-deck-idempotent');
    final harness = await createHarness(remote, 'idempotent_card');
    addTearDown(harness.client.dispose);
    addTearDown(harness.sync.dispose);
    addTearDown(() async => (await harness.store.database).close());
    await seedCard(
        harness.store, remote.ownerId, remote.deckId, 'idempotent-card');

    remote.loseInsertResponse = true;
    await harness.sync.syncNow(forceRetry: true);

    expect(remote.insertAttempts, 1);
    expect(remote.cards, hasLength(1));
    expect(
        (await harness.store.readCards(remote.ownerId, remote.deckId))
            .single['_sync_state'],
        'synced');

    await harness.sync.syncNow(forceRetry: true);
    expect(remote.insertAttempts, 1);
    expect(remote.cards, hasLength(1));
    expect(
        await harness.store.nextOutbox(remote.ownerId, force: true), isEmpty);
  });
}
