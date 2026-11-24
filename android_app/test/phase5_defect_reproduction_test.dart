import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

void main() {
  group('Phase 5 implementation source checks (supplementary)', () {
    test('history preparation uses the paginated range helper', () {
      final code = source('lib/offline_cache_preparation.dart');
      expect(code, contains('Future<List<T>> fetchAllPages<T>'));
      expect(code, contains(".from('activity_sessions')"));
      expect(code, contains('.range(from, to)'));
      expect(code, contains('fetchAllPages<Map<String, dynamic>>'));
    });

    test('offline profile startup reads the caregiver cache', () {
      final app = source('lib/main.dart').replaceAll(RegExp(r'\s+'), ' ');
      expect(
          app,
          contains(
              'cachedCaregiver = await OfflineStore.instance.readCaregiver(widget.user.id)'));
      expect(app, contains("cachedCaregiver?['display_name']"));
    });

    test('cache preparation discovers cards and individual media units', () {
      final code = source('lib/offline_cache_preparation.dart');
      expect(code, contains('_discover(cards.length)'));
      expect(code, contains('_discover(assetIds.length)'));
      expect(code, contains("setCacheItem(owner, 'card'"));
      expect(code, contains("setCacheItem(owner, 'media'"));
    });

    test('deck readiness is stored and partial status is shown to the viewer',
        () {
      final prep = source('lib/offline_cache_preparation.dart');
      final viewer = source('lib/elderly_memory_screen.dart');
      expect(prep, contains("ready ? 'ready' : 'partial'"));
      expect(viewer, contains("deck['_offline_status']"));
      expect(viewer, contains('Some media unavailable offline'));
    });

    test('connectivity and internet and Supabase states are independent', () {
      final code = source('lib/offline_sync.dart');
      expect(code, contains('_hasNetwork = results.any'));
      expect(code, contains('_internetAvailable = internet'));
      expect(code, contains('_supabaseReachable = true'));
      expect(code, contains('_supabaseReachable = false'));
      expect(code, contains('OfflineSyncState.noInternet'));
      expect(code, contains('OfflineSyncState.supabaseUnavailable'));
    });

    test('SQLite migration declares and enforces response session ownership',
        () {
      final code = source('lib/offline_store.dart');
      expect(code, contains('PRAGMA foreign_keys = ON'));
      expect(code, contains('FOREIGN KEY(session_id) REFERENCES sessions(id)'));
      expect(code, contains('Future<void> _migrateResponseForeignKey'));
    });

    test('cache preparation and Memory Deck loading reuse verified media', () {
      final prep = source('lib/offline_cache_preparation.dart');
      final viewer = source('lib/elderly_memory_screen.dart');
      final store = source('lib/offline_store.dart');
      expect(prep, contains('store.cacheMediaIfNeeded('));
      expect(viewer, contains('_store.cacheMediaIfNeeded('));
      expect(store,
          contains('final existing = await mediaPath(ownerId, assetId)'));
      expect(store, contains('if (existing != null) return existing;'));
    });

    test('owner changes invalidate the active synchronization generation', () {
      final code = source('lib/offline_sync.dart');
      expect(
          code,
          contains(
              'if (_ownerId != null && _ownerId != ownerId) _syncGeneration++'));
      expect(code, contains('if (generation != _syncGeneration) break;'));
      expect(
          code,
          contains(
              "throw StateError('Caregiver changed before synchronization completed.')"));
    });
  });
}
