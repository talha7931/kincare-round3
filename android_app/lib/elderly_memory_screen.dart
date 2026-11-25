import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'app_theme.dart';
import 'offline_sync.dart';
import 'offline_store.dart';

/// Elderly-facing Memory Deck and Memory Card viewer.
/// Implements the accessible reminiscence experience specified in Phase 2.
class ElderlyMemoryScreen extends StatefulWidget {
  final Map<String, dynamic> selectedProfile;
  final VoidCallback onBack;
  final VoidCallback onHome;

  const ElderlyMemoryScreen({
    super.key,
    required this.selectedProfile,
    required this.onBack,
    required this.onHome,
  });

  @override
  State<ElderlyMemoryScreen> createState() => _ElderlyMemoryScreenState();
}

class _ElderlyMemoryScreenState extends State<ElderlyMemoryScreen> {
  final _client = Supabase.instance.client;
  final _store = OfflineStore.instance;
  String get _caregiverId => _client.auth.currentUser?.id ?? '';

  List<Map<String, dynamic>> _decks = [];
  Map<String, dynamic>? _activeDeck;
  List<Map<String, dynamic>> _cards = [];
  int _cardIndex = 0;
  bool _storyRevealed = false;
  String? _sessionId;
  final TextEditingController _responseController = TextEditingController();
  final AudioRecorder _responseRecorder = AudioRecorder();
  bool _recordingResponse = false;
  String? _recordingPath;
  String? _responseAudioAssetId;
  final Map<String, Map<String, dynamic>> _draftResponses = {};

  bool _loadingDecks = true;
  bool _loadingCards = false;
  String? _error;

  // Signed URL caches
  final Map<String, String> _urlCache = {};

  // Audio player
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _currentlyPlayingRole; // 'question' or 'answer'
  StreamSubscription? _playerCompleteSub;

  @override
  void initState() {
    super.initState();
    _playerCompleteSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() => _currentlyPlayingRole = null);
      }
    });
    _loadDecks();
  }

  @override
  void dispose() {
    _playerCompleteSub?.cancel();
    _audioPlayer.dispose();
    _responseController.dispose();
    _responseRecorder.dispose();
    super.dispose();
  }

  Future<String?> _resolveSignedUrl(String? assetId) async {
    if (assetId == null || assetId.isEmpty) return null;
    if (_urlCache.containsKey(assetId)) return _urlCache[assetId];

    final localPath = await _store.mediaPath(_caregiverId, assetId);
    if (localPath != null) {
      _urlCache[assetId] = localPath;
      return localPath;
    }

    try {
      final row = await _client
          .from('media_assets')
          .select('storage_path, storage_bucket, mime_type')
          .eq('id', assetId)
          .maybeSingle();

      if (row == null || row['storage_path'] == null) return null;
      final storagePath = row['storage_path'].toString();

      final bucket = row['storage_bucket']?.toString() ?? 'kincare-media';
      final signedUrl =
          await _client.storage.from(bucket).createSignedUrl(storagePath, 3600);

      try {
        final extension = storagePath.split('.').last;
        final cachedPath = await _store.cacheMediaIfNeeded(
          _caregiverId,
          assetId,
          () => _client.storage.from(bucket).download(storagePath),
          row['mime_type']?.toString(),
          extension: extension,
        );
        _urlCache[assetId] = cachedPath;
        return cachedPath;
      } catch (_) {
        // Signed playback remains available if the local media copy fails.
      }

      _urlCache[assetId] = signedUrl;
      return signedUrl;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadDecks() async {
    final profileId = widget.selectedProfile['id']?.toString();
    if (profileId == null) {
      setState(() {
        _loadingDecks = false;
        _error = 'No profile selected.';
      });
      return;
    }

    setState(() {
      _loadingDecks = true;
      _error = null;
    });

    try {
      final data = await _client
          .from('memory_decks')
          .select(
              'id, elderly_profile_id, created_by_caregiver_id, title, language_code, created_at, updated_at')
          .eq('elderly_profile_id', profileId)
          .order('created_at');

      final deckList = List<Map<String, dynamic>>.from(data);

      for (final deck in deckList) {
        final countResult = await _client
            .from('memory_cards')
            .select('id')
            .eq('deck_id', deck['id']);
        deck['_card_count'] = (countResult as List).length;
        await _store.cacheDeckMetadata(_caregiverId, profileId, deck);
      }
      final localDecks = await _store.readDecks(_caregiverId, profileId);
      for (final deck in localDecks) {
        deck['_card_count'] =
            (await _store.readCards(_caregiverId, deck['id'].toString()))
                .length;
      }

      setState(() {
        _decks = localDecks;
        _loadingDecks = false;
      });
    } catch (e) {
      final cachedDecks = await _store.readDecks(_caregiverId, profileId);
      for (final deck in cachedDecks) {
        deck['_card_count'] =
            (await _store.readCards(_caregiverId, deck['id'].toString()))
                .length;
      }
      setState(() {
        _decks = cachedDecks;
        _error = cachedDecks.isEmpty ? 'Unable to load memory decks: $e' : null;
        _loadingDecks = false;
      });
    }
  }

  Future<void> _openDeck(Map<String, dynamic> deck) async {
    await _stopAudio();
    setState(() {
      _activeDeck = deck;
      _loadingCards = true;
      _cardIndex = 0;
      _storyRevealed = false;
      _cards = [];
      _sessionId = null;
      _draftResponses.clear();
      _responseController.clear();
      _responseAudioAssetId = null;
    });

    try {
      final cardSnapshotStartedAt = DateTime.now().toUtc();
      final cardRows = await _client
          .from('memory_cards')
          .select(
              'id, deck_id, photo_asset_id, question_audio_asset_id, answer_audio_asset_id, question_text, answer_context, display_order')
          .eq('deck_id', deck['id'])
          .order('display_order')
          .timeout(const Duration(seconds: 8));

      final loadedCards = List<Map<String, dynamic>>.from(cardRows);
      await _store.cacheDeck(
          _caregiverId,
          deck['elderly_profile_id']?.toString() ??
              widget.selectedProfile['id'].toString(),
          deck,
          loadedCards,
          remoteSnapshotStartedAt: cardSnapshotStartedAt);
      final visibleCards =
          await _store.readCards(_caregiverId, deck['id'].toString());

      // Pre-fetch signed URL for the first photo
      if (visibleCards.isNotEmpty) {
        final firstPhotoId = visibleCards.first['photo_asset_id']?.toString();
        if (firstPhotoId != null) {
          await _resolveSignedUrl(firstPhotoId);
        }
      }
      unawaited(_cacheDeckMedia(visibleCards));

      setState(() {
        _cards = visibleCards;
        _loadingCards = false;
      });
      if (visibleCards.isNotEmpty) await _beginOrRestoreDeckSession(deck);
    } catch (e) {
      final cachedCards =
          await _store.readCards(_caregiverId, deck['id'].toString());
      setState(() {
        _cards = cachedCards;
        _error = cachedCards.isEmpty ? 'Unable to load cards: $e' : null;
        _loadingCards = false;
      });
      if (cachedCards.isNotEmpty) {
        try {
          await _beginOrRestoreDeckSession(deck);
        } catch (activityError) {
          if (mounted) setState(() => _error = activityError.toString());
        }
      }
    }
  }

  Future<void> _beginOrRestoreDeckSession(Map<String, dynamic> deck) async {
    final ownerId = _caregiverId;
    final profileId = widget.selectedProfile['id'].toString();
    final deckId = deck['id'].toString();
    if (ownerId.isEmpty) throw StateError('Caregiver identity is unavailable.');
    final existing =
        await _store.resumableDeckSession(ownerId, profileId, deckId);
    if (existing != null) {
      final sessionId = existing['id']!.toString();
      final checkpoint = await _store.readGameCheckpoint(ownerId, sessionId);
      final responseDrafts = <String, Map<String, dynamic>>{};
      final rawResponses = checkpoint?['responses'];
      if (rawResponses is Map) {
        for (final entry in rawResponses.entries) {
          if (entry.value is Map) {
            responseDrafts[entry.key.toString()] =
                Map<String, dynamic>.from(entry.value as Map);
          }
        }
      }
      final index = (checkpoint?['card_index'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      setState(() {
        _sessionId = sessionId;
        _cardIndex = index.clamp(0, _cards.length - 1);
        _draftResponses
          ..clear()
          ..addAll(responseDrafts);
        final current = _draftResponses[_cards[_cardIndex]['id'].toString()];
        _responseController.text =
            current?['response_payload']?['text']?.toString() ?? '';
        _responseAudioAssetId = current?['response_audio_asset_id']?.toString();
        _storyRevealed = false;
      });
      return;
    }

    final preferences = await SharedPreferences.getInstance();
    var deviceUuid = preferences.getString('kincare.device_uuid');
    if (deviceUuid == null || deviceUuid.isEmpty) {
      deviceUuid = const Uuid().v4();
      await preferences.setString('kincare.device_uuid', deviceUuid);
    }
    String? deviceId;
    String? activityTypeId;
    final network = await Connectivity().checkConnectivity();
    final hasNetwork =
        network.any((result) => result != ConnectivityResult.none);
    if (hasNetwork) {
      try {
        final device = await _client
            .from('enrolled_devices')
            .upsert({
              'caregiver_id': ownerId,
              'device_uuid': deviceUuid,
              'device_name': 'KinCare Android device',
              'last_seen_at': DateTime.now().toUtc().toIso8601String(),
            }, onConflict: 'caregiver_id,device_uuid')
            .select('id, revoked_at')
            .single();
        if (device['revoked_at'] != null) {
          throw StateError('This enrolled device was revoked.');
        }
        deviceId = device['id'].toString();
        await _store.cacheDevice(ownerId, deviceUuid, deviceId, null);
        try {
          final activity = await _client
              .from('activity_types')
              .select('id')
              .eq('stable_key', 'memory_decks')
              .maybeSingle();
          activityTypeId = activity?['id']?.toString();
        } catch (_) {}
      } catch (error) {
        final cached = await _store.readDevice(ownerId, deviceUuid);
        if (cached == null || cached['revoked_at'] != null) rethrow;
        deviceId = cached['device_id']?.toString();
      }
    } else {
      final cached = await _store.readDevice(ownerId, deviceUuid);
      if (cached == null || cached['revoked_at'] != null) {
        throw StateError(
            'Connect this device once before starting an offline Memory Deck activity.');
      }
      deviceId = cached['device_id']?.toString();
    }
    final sessionId = const Uuid().v4();
    await _store.createSession(
      id: sessionId,
      caregiverId: ownerId,
      profileId: profileId,
      activityKey: 'memory_decks',
      activityTypeId: activityTypeId,
      deviceId: deviceId,
      memoryDeckId: deckId,
      startedAt: DateTime.now().toUtc().toIso8601String(),
    );
    await _store.saveGameCheckpoint(
        caregiverId: ownerId,
        sessionId: sessionId,
        gameKey: 'memory_decks',
        payload: {'card_index': 0, 'responses': <String, dynamic>{}});
    if (mounted) setState(() => _sessionId = sessionId);
  }

  Future<void> _cacheDeckMedia(List<Map<String, dynamic>> cards) async {
    final assetIds = <String>{};
    for (final card in cards) {
      for (final key in [
        'photo_asset_id',
        'question_audio_asset_id',
        'answer_audio_asset_id'
      ]) {
        final value = card[key]?.toString();
        if (value != null && value.isNotEmpty) assetIds.add(value);
      }
    }
    if (assetIds.isEmpty) return;
    var failed = false;
    try {
      final rows = await _client
          .from('media_assets')
          .select('id, storage_bucket, storage_path, mime_type')
          .inFilter('id', assetIds.toList());
      final assetsById = {
        for (final row in List<Map<String, dynamic>>.from(rows))
          row['id'].toString(): row,
      };
      for (final assetId in assetIds) {
        final row = assetsById[assetId];
        if (row == null) {
          failed = true;
          await _store.setCacheItem(_caregiverId, 'media', assetId, 'failed',
              'Media metadata is unavailable.');
          continue;
        }
        try {
          final bucket = row['storage_bucket']?.toString() ?? 'kincare-media';
          final path = row['storage_path']?.toString();
          if (path == null || path.isEmpty) {
            throw StateError('Media path is unavailable.');
          }
          await _store.cacheMediaIfNeeded(
              _caregiverId,
              assetId,
              () => _client.storage.from(bucket).download(path),
              row['mime_type']?.toString(),
              extension: path.split('.').last);
          if (await _store.mediaPath(_caregiverId, assetId) == null) {
            throw StateError('Cached media could not be verified.');
          }
          await _store.setCacheItem(_caregiverId, 'media', assetId, 'ready');
        } catch (error) {
          failed = true;
          await _store.setCacheItem(
              _caregiverId, 'media', assetId, 'failed', error.toString());
        }
      }
    } catch (error) {
      failed = true;
      for (final assetId in assetIds) {
        await _store.setCacheItem(
            _caregiverId, 'media', assetId, 'failed', error.toString());
      }
    }
    final ready =
        !failed && await _store.allMediaCached(_caregiverId, assetIds.toList());
    final deckId = _activeDeck?['id']?.toString();
    if (deckId != null) {
      await _store.setCacheItem(
          _caregiverId,
          'deck',
          deckId,
          ready ? 'ready' : 'partial',
          ready ? null : 'Some cards or media are unavailable offline.');
    }
  }

  Future<void> _stopAudio() async {
    await _audioPlayer.stop();
    if (mounted) {
      setState(() => _currentlyPlayingRole = null);
    }
  }

  Future<void> _toggleAudio(String? assetId, String role) async {
    if (_currentlyPlayingRole == role) {
      await _stopAudio();
      return;
    }

    await _stopAudio();
    final path = await _resolveSignedUrl(assetId);
    if (path == null || path.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Audio recording could not be loaded.',
              style: TextStyle(fontSize: 18),
            ),
          ),
        );
      }
      return;
    }

    setState(() => _currentlyPlayingRole = role);
    await _audioPlayer.play(
        File(path).existsSync() ? DeviceFileSource(path) : UrlSource(path));
  }

  Future<void> _saveDeckCheckpoint({int? cardIndex}) async {
    final sessionId = _sessionId;
    final ownerId = _caregiverId;
    if (sessionId == null || ownerId.isEmpty) return;
    await _store.saveGameCheckpoint(
        caregiverId: ownerId,
        sessionId: sessionId,
        gameKey: 'memory_decks',
        payload: {
          'card_index': cardIndex ?? _cardIndex,
          'responses': _draftResponses,
        });
  }

  Future<void> _captureCurrentResponse() async {
    if (_sessionId == null || _cards.isEmpty) return;
    final card = _cards[_cardIndex];
    final cardId = card['id'].toString();
    final previous = _draftResponses[cardId];
    final text = _responseController.text.trim();
    final audioId = _responseAudioAssetId;
    final kind = audioId != null
        ? (text.isNotEmpty ? 'text_and_audio' : 'audio')
        : text.isNotEmpty
            ? 'text'
            : 'no_response';
    _draftResponses[cardId] = {
      'id': previous?['id'] ?? const Uuid().v4(),
      'response_index': _cardIndex,
      'response_payload': {
        'schema_version': 1,
        'activity_type': 'memory_decks',
        'deck_id': _activeDeck?['id'],
        'card_id': cardId,
        'response_kind': kind,
        if (text.isNotEmpty) 'text': text,
      },
      'is_correct': null,
      'response_audio_asset_id': audioId,
      'responded_at':
          previous?['responded_at'] ?? DateTime.now().toUtc().toIso8601String(),
    };
    await _saveDeckCheckpoint();
  }

  Future<void> _nextCard() async {
    await _stopAudio();
    await _captureCurrentResponse();
    if (_cardIndex < _cards.length - 1) {
      final nextIndex = _cardIndex + 1;
      final nextCard = _cards[nextIndex];
      final draft = _draftResponses[nextCard['id'].toString()];
      setState(() {
        _cardIndex = nextIndex;
        _storyRevealed = false;
        _responseController.text =
            draft?['response_payload']?['text']?.toString() ?? '';
        _responseAudioAssetId = draft?['response_audio_asset_id']?.toString();
      });
      await _saveDeckCheckpoint();
      if (nextIndex + 1 < _cards.length) {
        unawaited(_resolveSignedUrl(
            _cards[nextIndex + 1]['photo_asset_id']?.toString()));
      }
      return;
    }
    final ownerId = _caregiverId;
    if (_sessionId != null && ownerId.isNotEmpty) {
      setState(() => _loadingCards = true);
      try {
        final responses = _draftResponses.values.toList()
          ..sort((a, b) => (a['response_index'] as int)
              .compareTo(b['response_index'] as int));
        await _store.completeSessionWithResponses(
            _sessionId!, ownerId, responses);
        unawaited(OfflineSyncService(_client).initialize(ownerId));
      } catch (error) {
        if (mounted) {
          setState(() {
            _loadingCards = false;
            _error = 'Your responses are still saved on this device: $error';
          });
        }
        return;
      }
    }
    if (mounted) {
      setState(() {
        _activeDeck = null;
        _sessionId = null;
        _loadingCards = false;
        _draftResponses.clear();
        _responseController.clear();
        _responseAudioAssetId = null;
      });
    }
  }

  Future<void> _previousCard() async {
    await _stopAudio();
    await _captureCurrentResponse();
    if (_cardIndex > 0) {
      final previousIndex = _cardIndex - 1;
      final previousCard = _cards[previousIndex];
      final draft = _draftResponses[previousCard['id'].toString()];
      setState(() {
        _cardIndex = previousIndex;
        _storyRevealed = false;
        _responseController.text =
            draft?['response_payload']?['text']?.toString() ?? '';
        _responseAudioAssetId = draft?['response_audio_asset_id']?.toString();
      });
      await _saveDeckCheckpoint();
    }
  }

  Future<void> _startResponseRecording() async {
    if (await _responseRecorder.hasPermission() == false) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Microphone unavailable. You can type a response instead.')));
      }
      return;
    }
    final root = await getApplicationSupportDirectory();
    final directory =
        Directory('${root.path}${Platform.pathSeparator}pending-recordings');
    await directory.create(recursive: true);
    _recordingPath =
        '${directory.path}${Platform.pathSeparator}${const Uuid().v4()}.m4a';
    await _responseRecorder.start(const RecordConfig(), path: _recordingPath!);
    if (mounted) setState(() => _recordingResponse = true);
  }

  Future<void> _stopResponseRecording() async {
    final path = await _responseRecorder.stop();
    if (mounted) setState(() => _recordingResponse = false);
    if (path == null || _sessionId == null) return;
    try {
      final assetId = const Uuid().v4();
      final durablePath = await _store.importLocalMedia(
          ownerId: _caregiverId,
          assetId: assetId,
          profileId: widget.selectedProfile['id'].toString(),
          deckId: _activeDeck?['id']?.toString(),
          cardId: _cards[_cardIndex]['id'].toString(),
          mediaType: 'response_audio',
          mimeType: 'audio/m4a',
          source: File(path));
      if (!mounted) return;
      setState(() => _responseAudioAssetId = assetId);
      await _captureCurrentResponse();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Recording saved on this device (${File(durablePath).existsSync() ? 'ready' : 'unavailable'}).')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Recording kept for retry: $error')));
      }
    }
  }

  Future<void> _prepareToLeaveDeck() async {
    if (_recordingResponse) await _stopResponseRecording();
    await _stopAudio();
    await _captureCurrentResponse();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: KinCareSpace.x5,
        vertical: KinCareSpace.x4,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTopNav(),
              const SizedBox(height: KinCareSpace.x5),
              if (_error != null) _buildError(),
              if (_activeDeck == null)
                _buildDeckSelection()
              else
                _buildCardViewer(),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Top Navigation (Back + Home)
  // ---------------------------------------------------------------------------

  Widget _buildTopNav() {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: KinCareSenior.controlHeight,
            child: FilledButton.icon(
              onPressed: () async {
                await _stopAudio();
                if (_activeDeck != null) {
                  await _prepareToLeaveDeck();
                  setState(() => _activeDeck = null);
                } else {
                  widget.onBack();
                }
              },
              icon: const Icon(Icons.arrow_back, size: 28),
              label: Text(
                _activeDeck != null ? 'Back to Decks' : 'Activities',
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: KinCareColors.sage,
                foregroundColor: KinCareColors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: KinCareSpace.x4),
        Expanded(
          child: SizedBox(
            height: KinCareSenior.controlHeight,
            child: FilledButton.icon(
              onPressed: () async {
                await _prepareToLeaveDeck();
                widget.onHome();
              },
              icon: const Icon(Icons.home, size: 28),
              label: const Text(
                'Home',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: KinCareColors.forest,
                foregroundColor: KinCareColors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Container(
      margin: const EdgeInsets.only(bottom: KinCareSpace.x5),
      padding: const EdgeInsets.all(KinCareSpace.x5),
      decoration: BoxDecoration(
        color: KinCareColors.dangerWash,
        border: Border.all(color: KinCareColors.dangerLine, width: 2),
        borderRadius: BorderRadius.circular(KinCareRadii.lg),
      ),
      child: Text(
        _error!,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: KinCareColors.danger,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Deck Selection View
  // ---------------------------------------------------------------------------

  Widget _buildDeckSelection() {
    if (_loadingDecks) {
      return Container(
        padding: const EdgeInsets.all(KinCareSpace.x10),
        child: const Center(
          child: CircularProgressIndicator(
            strokeWidth: 4,
            color: KinCareColors.forest,
          ),
        ),
      );
    }

    if (_decks.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(KinCareSpace.x8),
        decoration: BoxDecoration(
          color: KinCareColors.white,
          borderRadius: BorderRadius.circular(KinCareRadii.xl),
          border: Border.all(color: KinCareColors.cloud, width: 2),
        ),
        child: Column(
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                color: KinCareColors.paleSage,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.photo_library_outlined,
                size: 44,
                color: KinCareColors.forest,
              ),
            ),
            const SizedBox(height: KinCareSpace.x5),
            const Text(
              'No Memory Decks Yet',
              style: TextStyle(
                fontSize: KinCareSenior.title,
                fontWeight: FontWeight.w700,
                color: KinCareColors.forest,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: KinCareSpace.x3),
            const Text(
              'Your caregiver has not added any photo decks for you yet. Please ask them to create a deck with family photographs.',
              style: TextStyle(
                fontSize: KinCareSenior.body,
                height: 1.45,
                color: KinCareColors.charcoal,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Memory Decks',
          style: const TextStyle(
            fontSize: KinCareSenior.title,
            fontWeight: FontWeight.w700,
            color: KinCareColors.forest,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: KinCareSpace.x2),
        const Text(
          'Choose a deck to view familiar photographs and memories.',
          style: TextStyle(
            fontSize: 22,
            height: 1.4,
            color: KinCareColors.charcoal,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: KinCareSpace.x6),
        for (final deck in _decks) ...[
          _buildDeckCard(deck),
          const SizedBox(height: KinCareSpace.x4),
        ],
      ],
    );
  }

  Widget _buildDeckCard(Map<String, dynamic> deck) {
    final cardCount = deck['_card_count'] as int? ?? 0;
    final lang = languageLabel(deck['language_code']);
    final offlineStatus = deck['_offline_status']?.toString();

    return Material(
      color: KinCareColors.white,
      borderRadius: BorderRadius.circular(KinCareRadii.xl),
      elevation: 0,
      child: InkWell(
        onTap: () => _openDeck(deck),
        borderRadius: BorderRadius.circular(KinCareRadii.xl),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: KinCareSpace.x6,
            vertical: KinCareSpace.x5,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(KinCareRadii.xl),
            border: Border.all(color: KinCareColors.line, width: 2),
          ),
          child: Row(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: KinCareColors.paleSage,
                  borderRadius: BorderRadius.circular(KinCareRadii.lg),
                ),
                child: const Icon(
                  Icons.photo_album,
                  size: 38,
                  color: KinCareColors.forest,
                ),
              ),
              const SizedBox(width: KinCareSpace.x5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deck['title']?.toString() ?? 'Memory Deck',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: KinCareColors.forest,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: KinCareSpace.x2,
                      runSpacing: KinCareSpace.x1,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: KinCareColors.paleSage,
                            borderRadius:
                                BorderRadius.circular(KinCareRadii.xs),
                          ),
                          child: Text(
                            '$cardCount ${cardCount == 1 ? 'photo' : 'photos'}',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: KinCareColors.forest,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: KinCareColors.cloud,
                            borderRadius:
                                BorderRadius.circular(KinCareRadii.xs),
                          ),
                          child: Text(
                            lang,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: KinCareColors.charcoal,
                            ),
                          ),
                        ),
                        if (offlineStatus != null && offlineStatus != 'ready')
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: KinCareColors.paleSage,
                              borderRadius:
                                  BorderRadius.circular(KinCareRadii.xs),
                            ),
                            child: Text(
                              offlineStatus == 'partial' ||
                                      offlineStatus == 'failed'
                                  ? 'Some media unavailable offline'
                                  : 'Offline availability unknown',
                              style: const TextStyle(
                                  fontSize: 14, color: KinCareColors.danger),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios,
                size: 28,
                color: KinCareColors.sage,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Card Viewer (The Core Feature)
  // ---------------------------------------------------------------------------

  Widget _buildCardViewer() {
    if (_loadingCards) {
      return Container(
        padding: const EdgeInsets.all(KinCareSpace.x10),
        child: const Center(
          child: CircularProgressIndicator(
            strokeWidth: 4,
            color: KinCareColors.forest,
          ),
        ),
      );
    }

    if (_cards.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(KinCareSpace.x8),
        decoration: BoxDecoration(
          color: KinCareColors.white,
          borderRadius: BorderRadius.circular(KinCareRadii.xl),
          border: Border.all(color: KinCareColors.cloud, width: 2),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.photo_outlined,
              size: 54,
              color: KinCareColors.textMuted,
            ),
            const SizedBox(height: KinCareSpace.x4),
            Text(
              _activeDeck?['title']?.toString() ?? 'Memory Deck',
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: KinCareColors.forest,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: KinCareSpace.x3),
            const Text(
              'No cards have been added to this deck yet. Ask your caregiver to upload photographs.',
              style: TextStyle(
                fontSize: 22,
                color: KinCareColors.charcoal,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final card = _cards[_cardIndex];
    final totalCards = _cards.length;
    final photoAssetId = card['photo_asset_id']?.toString();
    final questionAudioId = card['question_audio_asset_id']?.toString();
    final answerAudioId = card['answer_audio_asset_id']?.toString();
    final questionText = card['question_text']?.toString() ?? '';
    final answerContext = card['answer_context']?.toString() ?? '';

    final hasQuestionAudio =
        questionAudioId != null && questionAudioId.isNotEmpty;
    final hasAnswerAudio = answerAudioId != null && answerAudioId.isNotEmpty;
    final hasStoryContent = answerContext.isNotEmpty || hasAnswerAudio;

    return Container(
      decoration: BoxDecoration(
        color: KinCareColors.white,
        borderRadius: BorderRadius.circular(KinCareRadii.xl),
        border: Border.all(color: KinCareColors.line, width: 2),
        boxShadow: const [
          BoxShadow(
            color: Color.fromARGB(15, 24, 61, 53),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(KinCareSpace.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Deck title + Card counter
          Row(
            children: [
              Expanded(
                child: Text(
                  _activeDeck?['title']?.toString() ?? 'Memory Deck',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: KinCareColors.textMuted,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: KinCareColors.paleSage,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: KinCareColors.sage, width: 1.5),
                ),
                child: Text(
                  '${_cardIndex + 1} of $totalCards',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: KinCareColors.forest,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: KinCareSpace.x5),

          // Large Photograph
          _buildCardPhoto(photoAssetId),
          const SizedBox(height: KinCareSpace.x6),

          // Question Text (26–28 px bold)
          Container(
            padding: const EdgeInsets.all(KinCareSpace.x4),
            decoration: BoxDecoration(
              color: KinCareColors.offWhite,
              borderRadius: BorderRadius.circular(KinCareRadii.lg),
              border: Border.all(color: KinCareColors.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Question',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: KinCareColors.sage,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  questionText,
                  style: const TextStyle(
                    fontSize: 26,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                    color: KinCareColors.forest,
                  ),
                ),
              ],
            ),
          ),

          // Spoken Question Audio Button (min 64–72 px)
          if (hasQuestionAudio) ...[
            const SizedBox(height: KinCareSpace.x4),
            _buildAudioButton(
              role: 'question',
              assetId: questionAudioId,
              idleLabel: 'Listen to Question',
              playingLabel: 'Stop Audio',
            ),
          ],

          const SizedBox(height: KinCareSpace.x4),
          const Text('Would you like to share what you remember?',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: KinCareColors.forest)),
          const SizedBox(height: KinCareSpace.x2),
          TextField(
            controller: _responseController,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                hintText: 'Type a memory here (optional)',
                border: OutlineInputBorder()),
            onChanged: (_) => unawaited(_captureCurrentResponse()),
          ),
          const SizedBox(height: KinCareSpace.x2),
          Wrap(
              spacing: KinCareSpace.x2,
              runSpacing: KinCareSpace.x2,
              children: [
                SizedBox(
                  height: KinCareSenior.controlHeight,
                  child: FilledButton.icon(
                    onPressed: _recordingResponse
                        ? _stopResponseRecording
                        : _startResponseRecording,
                    icon: Icon(_recordingResponse ? Icons.stop : Icons.mic,
                        size: 26),
                    label: Text(
                        _recordingResponse
                            ? 'Stop recording'
                            : 'Record response',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                ),
                if (_responseAudioAssetId != null)
                  SizedBox(
                    height: KinCareSenior.controlHeight,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final path = await _store.mediaPath(
                            _caregiverId, _responseAudioAssetId!);
                        if (path != null) {
                          await _audioPlayer.stop();
                          await _audioPlayer.play(DeviceFileSource(path));
                        }
                      },
                      icon: const Icon(Icons.play_arrow, size: 26),
                      label: const Text('Play recording',
                          style: TextStyle(fontSize: 18)),
                    ),
                  ),
              ]),

          const SizedBox(height: KinCareSpace.x5),

          // Story is only added to the widget tree after an explicit reveal.
          if (hasStoryContent && !_storyRevealed) ...[
            SizedBox(
              height: KinCareSenior.controlHeight,
              child: FilledButton.icon(
                onPressed: () => setState(() => _storyRevealed = true),
                icon: const Icon(Icons.auto_stories_outlined, size: 28),
                label: const Text(
                  'Reveal Memory Story',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: KinCareColors.amber,
                  foregroundColor: KinCareColors.charcoal,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(KinCareRadii.lg),
                  ),
                ),
              ),
            ),
            const SizedBox(height: KinCareSpace.x5),
          ],
          if (answerContext.isNotEmpty && _storyRevealed) ...[
            Container(
              padding: const EdgeInsets.all(KinCareSpace.x5),
              decoration: BoxDecoration(
                color: KinCareColors.paleSage.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(KinCareRadii.lg),
                border: Border.all(
                  color: KinCareColors.sage.withValues(alpha: 0.35),
                  width: 1.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.auto_stories_outlined,
                        size: 22,
                        color: KinCareColors.forest,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Memory Story',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: KinCareColors.forest,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    answerContext,
                    style: const TextStyle(
                      fontSize: 22,
                      height: 1.45,
                      color: KinCareColors.charcoal,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Spoken Answer Audio Button
          if (hasAnswerAudio && _storyRevealed) ...[
            const SizedBox(height: KinCareSpace.x4),
            _buildAudioButton(
              role: 'answer',
              assetId: answerAudioId,
              idleLabel: 'Listen to Story',
              playingLabel: 'Stop Story',
            ),
          ],

          const SizedBox(height: KinCareSpace.x7),

          // Previous & Next navigation controls (72 px)
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: KinCareSenior.controlHeight,
                  child: OutlinedButton.icon(
                    onPressed: _cardIndex > 0 ? _previousCard : null,
                    icon: const Icon(Icons.arrow_back, size: 28),
                    label: const Text(
                      'Previous',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: KinCareColors.forest,
                      side: const BorderSide(
                        color: KinCareColors.sage,
                        width: 2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(KinCareRadii.lg),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: KinCareSpace.x4),
              Expanded(
                child: SizedBox(
                  height: KinCareSenior.controlHeight,
                  child: FilledButton.icon(
                    onPressed: _nextCard,
                    icon: Icon(
                      _cardIndex < totalCards - 1
                          ? Icons.arrow_forward
                          : Icons.check_circle,
                      size: 28,
                    ),
                    label: Text(
                      _cardIndex < totalCards - 1 ? 'Next' : 'Finish',
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: KinCareColors.forest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(KinCareRadii.lg),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Card Photo with Private Storage Signed URL
  // ---------------------------------------------------------------------------

  Widget _buildCardPhoto(String? assetId) {
    if (assetId == null || assetId.isEmpty) {
      return Container(
        height: 260,
        decoration: BoxDecoration(
          color: KinCareColors.paleSage,
          borderRadius: BorderRadius.circular(KinCareRadii.xl),
        ),
        child: const Center(
          child: Icon(
            Icons.photo_outlined,
            size: 64,
            color: KinCareColors.sage,
          ),
        ),
      );
    }

    return FutureBuilder<String?>(
      future: _resolveSignedUrl(assetId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !_urlCache.containsKey(assetId)) {
          return Container(
            height: 300,
            decoration: BoxDecoration(
              color: KinCareColors.paleSage,
              borderRadius: BorderRadius.circular(KinCareRadii.xl),
            ),
            child: const Center(
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: KinCareColors.forest,
              ),
            ),
          );
        }

        final url = snapshot.data ?? _urlCache[assetId];
        if (url == null || url.isEmpty) {
          return Container(
            height: 260,
            decoration: BoxDecoration(
              color: KinCareColors.paleSage,
              borderRadius: BorderRadius.circular(KinCareRadii.xl),
            ),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.broken_image_outlined,
                    size: 48, color: KinCareColors.sage),
                SizedBox(height: 8),
                Text(
                  'Photograph could not be loaded',
                  style: TextStyle(
                    fontSize: 18,
                    color: KinCareColors.textMuted,
                  ),
                ),
              ],
            ),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(KinCareRadii.xl),
          child: url.startsWith('http')
              ? Image.network(
                  url,
                  fit: BoxFit.cover,
                  height: 320,
                  width: double.infinity,
                  errorBuilder: (_, __, ___) => Container(
                    height: 260,
                    color: KinCareColors.paleSage,
                    child: const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        size: 48,
                        color: KinCareColors.danger,
                      ),
                    ),
                  ),
                )
              : Image.file(
                  File(url),
                  fit: BoxFit.cover,
                  height: 320,
                  width: double.infinity,
                  errorBuilder: (_, __, ___) => Container(
                    height: 260,
                    color: KinCareColors.paleSage,
                    child: const Center(
                        child: Icon(Icons.broken_image_outlined,
                            size: 48, color: KinCareColors.danger)),
                  ),
                ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // High-Contrast Large Audio Button (64–72 px)
  // ---------------------------------------------------------------------------

  Widget _buildAudioButton({
    required String role,
    required String? assetId,
    required String idleLabel,
    required String playingLabel,
  }) {
    final isPlaying = _currentlyPlayingRole == role;

    return SizedBox(
      height: KinCareSenior.controlHeight,
      child: FilledButton.icon(
        onPressed: () => _toggleAudio(assetId, role),
        icon: Icon(
          isPlaying ? Icons.stop_circle : Icons.volume_up_rounded,
          size: 32,
        ),
        label: Text(
          isPlaying ? playingLabel : idleLabel,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: isPlaying ? KinCareColors.amber : KinCareColors.sage,
          foregroundColor:
              isPlaying ? KinCareColors.charcoal : KinCareColors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KinCareRadii.lg),
          ),
        ),
      ),
    );
  }
}
