import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'app_theme.dart';
import 'cognitive_game_rules.dart';
import 'offline_store.dart';
import 'offline_sync.dart';
import 'sorting_game_progress.dart';

class CognitiveGamesScreen extends StatefulWidget {
  final Map<String, dynamic> selectedProfile;
  final String gameKey;
  final VoidCallback onBack;
  final VoidCallback onHome;

  const CognitiveGamesScreen({
    super.key,
    required this.selectedProfile,
    required this.gameKey,
    required this.onBack,
    required this.onHome,
  });

  @override
  State<CognitiveGamesScreen> createState() => _CognitiveGamesScreenState();
}

class _CognitiveGamesScreenState extends State<CognitiveGamesScreen> {
  final _client = Supabase.instance.client;
  final _tts = FlutterTts();
  final _uuid = const Uuid();
  final _store = OfflineStore.instance;
  late Future<Map<String, dynamic>> _contentFuture;
  String? _sessionId;
  String? _error;
  String? _feedback;
  String _stage = 'intro';
  bool _busy = false;
  int _roundIndex = 0;
  String? _selectedOddItem;
  bool _oddResponseSaved = false;
  final Map<int, Map<String, dynamic>> _draftOddResponses = {};
  final Map<String, String> _placements = {};
  String? _selectedSortingItem;
  final Map<String, String> _responseIds = {};

  bool get _isSorting => widget.gameKey == everydayObjectSortingActivityKey;
  String get _activityKey => widget.gameKey;
  String get _title => _isSorting ? 'Everyday Object Sorting' : 'Odd One Out';
  String get _languageCode => supportedSpeechLanguage(
      widget.selectedProfile['preferred_language']?.toString());
  String get _language => speechLocale(_languageCode);

  String _spoken(Object? translations, {String fallback = ''}) => spokenText(
        translations,
        _languageCode,
        fallback: fallback,
      );

  bool _isTransportFailure(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      RegExp(r'network|connection|socket|timeout|failed to fetch',
              caseSensitive: false)
          .hasMatch(error.toString());

  @override
  void initState() {
    super.initState();
    _contentFuture = _loadContent();
    _tts.setSpeechRate(0.42);
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<Map<String, dynamic>> _loadContent() async =>
      jsonDecode(await rootBundle.loadString('assets/cognitive_games.json'))
          as Map<String, dynamic>;

  Future<void> _speak(String text) async {
    try {
      await _tts.setLanguage(_language);
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Audio is unavailable. Please read the instruction shown on screen.');
      }
    }
  }

  Future<void> _startSession() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = _client.auth.currentUser;
      if (user == null)
        throw StateError('Sign in again before starting an activity.');
      final localProfiles = await _store.readProfiles(user.id);
      if (localProfiles.isNotEmpty &&
          !localProfiles.any((profile) =>
              profile['id'].toString() ==
              widget.selectedProfile['id'].toString())) {
        throw StateError(
            'The selected profile is not in this caregiver’s saved profile list.');
      }
      final profileId = widget.selectedProfile['id'].toString();
      final existing =
          await _store.resumableSession(user.id, profileId, _activityKey);
      if (existing != null) {
        final sessionId = existing['id']!.toString();
        final checkpoint = await _store.readGameCheckpoint(user.id, sessionId);
        final responses = await _store.localResponses(sessionId);
        final restoredResponseIds = <String, String>{};
        final restoredOddDrafts = <int, Map<String, dynamic>>{};
        for (final response in responses) {
          final payload = jsonDecode(response['payload']! as String)
              as Map<String, dynamic>;
          if (payload['activity_type'] == 'odd_one_out') {
            final index = response['response_index'] as int;
            restoredResponseIds['odd-$index'] = response['id'].toString();
            restoredOddDrafts[index] = {
              'id': response['id'].toString(),
              'session_id': sessionId,
              'response_index': index,
              'response_payload': payload,
              'is_correct': response['is_correct'] == 1,
              'responded_at': response['responded_at'],
            };
          } else if (payload['activity_type'] == 'everyday_object_sorting') {
            restoredResponseIds['sort-${payload['item_id']}'] =
                response['id'].toString();
          }
        }
        final checkpointIds = checkpoint?['response_ids'];
        if (checkpointIds is Map) {
          restoredResponseIds.addAll(checkpointIds
              .map((key, value) => MapEntry(key.toString(), value.toString())));
        }
        final checkpointDrafts = checkpoint?['odd_responses'];
        if (checkpointDrafts is Map) {
          for (final entry in checkpointDrafts.entries) {
            final index = int.tryParse(entry.key.toString());
            if (index != null && entry.value is Map) {
              restoredOddDrafts[index] =
                  Map<String, dynamic>.from(entry.value as Map);
            }
          }
        }
        final placements = <String, String>{};
        final rawPlacements = checkpoint?['placements'];
        if (rawPlacements is Map) {
          placements.addAll(rawPlacements
              .map((key, value) => MapEntry(key.toString(), value.toString())));
        }
        final roundIndex = (checkpoint?['round_index'] as num?)?.toInt() ??
            (responses.isEmpty
                ? 0
                : responses
                    .map((row) => (row['response_index'] as int?) ?? 0)
                    .reduce((a, b) => a > b ? a : b));
        if (!mounted) return;
        setState(() {
          _sessionId = sessionId;
          _stage = 'playing';
          _roundIndex = roundIndex.clamp(0, 2);
          _selectedOddItem = checkpoint?['selected_odd_item']?.toString();
          _oddResponseSaved = checkpoint?['odd_response_saved'] == true ||
              restoredResponseIds.containsKey('odd-$_roundIndex');
          _feedback = checkpoint?['feedback']?.toString();
          _placements
            ..clear()
            ..addAll(placements);
          _selectedSortingItem =
              checkpoint?['selected_sorting_item']?.toString();
          _responseIds
            ..clear()
            ..addAll(restoredResponseIds);
          _draftOddResponses
            ..clear()
            ..addAll(restoredOddDrafts);
        });
        unawaited(OfflineSyncService(_client).initialize(user.id));
        return;
      }
      final preferences = await SharedPreferences.getInstance();
      var deviceUuid = preferences.getString('kincare.device_uuid');
      if (deviceUuid == null || deviceUuid.isEmpty) {
        deviceUuid = _uuid.v4();
        await preferences.setString('kincare.device_uuid', deviceUuid);
      }
      String? deviceId;
      String? activityTypeId;
      final connectivity = await Connectivity().checkConnectivity();
      final online =
          connectivity.any((result) => result != ConnectivityResult.none);
      if (!online &&
          !localProfiles.any((profile) =>
              profile['id'].toString() ==
              widget.selectedProfile['id'].toString())) {
        throw StateError(
            'This profile has not been saved on this device for offline use.');
      }
      if (online) {
        try {
          final device = await _client
              .from('enrolled_devices')
              .upsert({
                'caregiver_id': user.id,
                'device_uuid': deviceUuid,
                'device_name': 'KinCare Android device',
                'last_seen_at': DateTime.now().toUtc().toIso8601String(),
              }, onConflict: 'caregiver_id,device_uuid')
              .select('id, revoked_at')
              .single();
          if (device['revoked_at'] != null)
            throw StateError('This device has been revoked.');
          deviceId = device['id'].toString();
          await _store.cacheDevice(user.id, deviceUuid, deviceId, null);
          try {
            final activity = await _client
                .from('activity_types')
                .select('id')
                .eq('stable_key', _activityKey)
                .single();
            activityTypeId = activity['id'].toString();
          } catch (error) {
            if (!_isTransportFailure(error)) rethrow;
          }
        } catch (error) {
          final cachedDevice = await _store.readDevice(user.id, deviceUuid);
          if (!_isTransportFailure(error) ||
              cachedDevice == null ||
              cachedDevice['revoked_at'] != null) rethrow;
          deviceId = cachedDevice['device_id']?.toString();
        }
      } else {
        final cachedDevice = await _store.readDevice(user.id, deviceUuid);
        if (cachedDevice == null || cachedDevice['revoked_at'] != null) {
          throw StateError(
              'Connect this device to KinCare once before using activities offline.');
        }
        deviceId = cachedDevice['device_id']?.toString();
      }
      final sessionId = _uuid.v4();
      await _store.createSession(
        id: sessionId,
        caregiverId: user.id,
        profileId: widget.selectedProfile['id'].toString(),
        activityKey: _activityKey,
        activityTypeId: activityTypeId,
        deviceId: deviceId,
        startedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await _store.saveGameCheckpoint(
          caregiverId: user.id,
          sessionId: sessionId,
          gameKey: _activityKey,
          payload: {
            'stage': 'playing',
            'round_index': 0,
            'placements': <String, String>{},
            'response_ids': <String, String>{},
          });
      if (!mounted) return;
      setState(() {
        _sessionId = sessionId;
        _stage = 'playing';
      });
      unawaited(OfflineSyncService(_client).initialize(user.id));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveCheckpoint({String? stage, bool? oddResponseSaved}) async {
    final ownerId = _client.auth.currentUser?.id;
    final sessionId = _sessionId;
    if (ownerId == null || sessionId == null) return;
    await _store.saveGameCheckpoint(
        caregiverId: ownerId,
        sessionId: sessionId,
        gameKey: _activityKey,
        payload: {
          'stage': stage ?? _stage,
          'round_index': _roundIndex,
          'selected_odd_item': _selectedOddItem,
          'odd_response_saved': oddResponseSaved ?? _oddResponseSaved,
          'placements': _placements,
          'selected_sorting_item': _selectedSortingItem,
          'response_ids': _responseIds,
          'odd_responses': _draftOddResponses
              .map((index, response) => MapEntry(index.toString(), response)),
          'feedback': _feedback,
        });
  }

  Map<String, dynamic> _oddResponse(Map<String, dynamic> round, String itemId) {
    final responseKey = 'odd-$_roundIndex';
    final id = _responseIds.putIfAbsent(responseKey, _uuid.v4);
    return {
      'id': id,
      'session_id': _sessionId,
      'response_index': _roundIndex,
      'response_payload': {
        'schema_version': 1,
        'activity_type': 'odd_one_out',
        'round_id': round['id'],
        'selected_item_id': itemId,
        'expected_item_id': round['expected_item_id'],
      },
      'is_correct':
          oddOneOutIsCorrect(itemId, round['expected_item_id'].toString()),
      'responded_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<void> _completeSession({bool alreadyCompleted = false}) async {
    if (_sessionId == null) return;
    if (!alreadyCompleted) {
      await _store.finishSession(_sessionId!, 'completed',
          completedAt: DateTime.now().toUtc().toIso8601String());
    }
    if (mounted)
      setState(() {
        _stage = 'complete';
        _feedback =
            'Thank you for taking part. You can enjoy another activity whenever you like.';
      });
    await _speak(spokenCompletion(_languageCode));
    final ownerId = _client.auth.currentUser?.id;
    if (ownerId != null)
      unawaited(OfflineSyncService(_client).initialize(ownerId));
  }

  Future<void> _leaveActivity({required bool home}) async {
    if (_busy) return;
    if (_sessionId != null && _stage == 'playing') {
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        await _store.finishSession(_sessionId!, 'abandoned');
        final ownerId = _client.auth.currentUser?.id;
        if (ownerId != null)
          unawaited(OfflineSyncService(_client).initialize(ownerId));
      } catch (error) {
        if (mounted)
          setState(() {
            _error = error.toString();
            _busy = false;
          });
        return;
      }
      if (mounted) setState(() => _busy = false);
    }
    if (home) {
      widget.onHome();
    } else {
      widget.onBack();
    }
  }

  Future<void> _chooseOdd(Map<String, dynamic> round, String itemId) async {
    if (_busy || _oddResponseSaved) return;
    setState(() {
      _busy = true;
      _error = null;
      _selectedOddItem = itemId;
    });
    try {
      final response = _oddResponse(round, itemId);
      _draftOddResponses[_roundIndex] = response;
      final correct = itemId == round['expected_item_id'];
      if (mounted) {
        setState(() {
          _feedback = correct
              ? 'Well done! ${round['explanation']}'
              : 'That’s okay. ${round['explanation']}';
        });
      }
      await _saveCheckpoint(oddResponseSaved: true);
      if (mounted) setState(() => _oddResponseSaved = true);
      if (_roundIndex == 2) {
        await _completeOddActivity();
      }
      await _speak(
          '${spokenEncouragement(_languageCode, correct: correct)} ${_spoken((round['spoken'] as Map?)?[_languageCode]?['explanation'], fallback: round['explanation'].toString())}');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryOdd(Map<String, dynamic> round) async {
    if (_selectedOddItem == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = _oddResponse(round, _selectedOddItem!);
      _draftOddResponses[_roundIndex] = response;
      if (mounted) {
        setState(() {
          _feedback = _selectedOddItem == round['expected_item_id']
              ? 'Well done! ${round['explanation']}'
              : 'That’s okay. ${round['explanation']}';
        });
      }
      await _saveCheckpoint(oddResponseSaved: true);
      if (mounted) setState(() => _oddResponseSaved = true);
      if (_roundIndex == 2) {
        await _completeOddActivity();
      }
      final correct = _selectedOddItem == round['expected_item_id'];
      await _speak(
          '${spokenEncouragement(_languageCode, correct: correct)} ${_spoken((round['spoken'] as Map?)?[_languageCode]?['explanation'], fallback: round['explanation'].toString())}');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeOddActivity() async {
    final ownerId = _client.auth.currentUser?.id;
    if (ownerId == null) {
      throw StateError(
          'Your saved caregiver account is not available on this device.');
    }
    final responses = <Map<String, dynamic>>[];
    for (var index = 0; index < 3; index++) {
      final response = _draftOddResponses[index];
      if (response == null) {
        throw StateError('Complete each round before finishing the activity.');
      }
      responses.add(response);
    }
    await _store.completeSessionWithResponses(_sessionId!, ownerId, responses);
    await _completeSession(alreadyCompleted: true);
  }

  Future<void> _finishSorting(Map<String, dynamic> sorting) async {
    final items = (sorting['items'] as List).cast<Map<String, dynamic>>();
    if (_busy || _categorizedCount(items) != items.length) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final responses = <Map<String, dynamic>>[];
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final selectedCategory = _placements[item['id']];
        final responseId =
            _responseIds.putIfAbsent('sort-${item['id']}', _uuid.v4);
        responses.add({
          'id': responseId,
          'session_id': _sessionId,
          'response_index': index,
          'response_payload': {
            'schema_version': 1,
            'activity_type': 'everyday_object_sorting',
            'item_id': item['id'],
            'selected_category_id': selectedCategory,
            'expected_category_id': item['category_id'],
          },
          'is_correct': sortingIsCorrect(
              selectedCategory ?? '', item['category_id'].toString()),
          'responded_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
      final ownerId = _client.auth.currentUser!.id;
      await _store.completeSessionWithResponses(
          _sessionId!, ownerId, responses);
      await _completeSession(alreadyCompleted: true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int _categorizedCount(List<Map<String, dynamic>> items) =>
      items.where((item) {
        final value = _placements[item['id']];
        return value != null && value.isNotEmpty;
      }).length;

  Widget _bigButton(String label, VoidCallback? onPressed,
          {bool primary = true}) =>
      SizedBox(
        height: KinCareSenior.controlHeight,
        child: primary
            ? FilledButton(
                onPressed: onPressed,
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 21, fontWeight: FontWeight.w700)))
            : OutlinedButton(
                onPressed: onPressed,
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 21, fontWeight: FontWeight.w700))),
      );

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
        future: _contentFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final content = snapshot.data!;
          final rounds =
              (content['odd_one_out'] as List).cast<Map<String, dynamic>>();
          final sorting =
              content['everyday_object_sorting'] as Map<String, dynamic>;
          final round = rounds[_roundIndex];
          return SingleChildScrollView(
            padding: const EdgeInsets.all(KinCareSpace.x5),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Expanded(
                            child: _bigButton(
                                'Activities',
                                _busy
                                    ? null
                                    : () => _leaveActivity(home: false),
                                primary: false)),
                        const SizedBox(width: KinCareSpace.x3),
                        Expanded(
                            child: _bigButton('Home',
                                _busy ? null : () => _leaveActivity(home: true),
                                primary: false)),
                      ]),
                      const SizedBox(height: KinCareSpace.x4),
                      Text(_title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w700,
                              color: KinCareColors.forest)),
                      if (_error != null) ...[
                        const SizedBox(height: KinCareSpace.x3),
                        Container(
                            padding: const EdgeInsets.all(KinCareSpace.x3),
                            decoration: BoxDecoration(
                                color: KinCareColors.dangerWash,
                                border:
                                    Border.all(color: KinCareColors.dangerLine),
                                borderRadius:
                                    BorderRadius.circular(KinCareRadii.md)),
                            child: Text(_error!,
                                style: const TextStyle(
                                    fontSize: 17,
                                    color: KinCareColors.danger))),
                      ],
                      const SizedBox(height: KinCareSpace.x4),
                      if (_stage == 'intro')
                        _panel(Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                  _isSorting
                                      ? sorting['instruction'].toString()
                                      : rounds.first['instruction'].toString(),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 25,
                                      height: 1.4,
                                      fontWeight: FontWeight.w700,
                                      color: KinCareColors.forest)),
                              const SizedBox(height: KinCareSpace.x4),
                              _bigButton(
                                  '🔊  Listen to Instructions',
                                  () => _speak(_isSorting
                                      ? _spoken(
                                          (sorting['spoken']
                                                  as Map?)?[_languageCode]
                                              ?['instruction'],
                                          fallback:
                                              sorting['instruction'].toString())
                                      : _spoken(
                                          (rounds.first['spoken']
                                                  as Map?)?[_languageCode]
                                              ?['instruction'],
                                          fallback: rounds.first['instruction']
                                              .toString())),
                                  primary: false),
                              const SizedBox(height: KinCareSpace.x3),
                              _bigButton(_busy ? 'Starting…' : 'Begin Activity',
                                  _busy ? null : _startSession),
                            ])),
                      if (_stage == 'playing' && !_isSorting) _buildOdd(round),
                      if (_stage == 'playing' && _isSorting)
                        _buildSorting(sorting),
                      if (_stage == 'complete')
                        _panel(Column(children: [
                          const Icon(Icons.spa_outlined,
                              size: 56, color: KinCareColors.sage),
                          const SizedBox(height: KinCareSpace.x3),
                          const Text('Activity complete',
                              style: TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w700,
                                  color: KinCareColors.forest)),
                          const SizedBox(height: KinCareSpace.x2),
                          Text(_feedback ?? 'Thank you for taking part.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 22)),
                          const SizedBox(height: KinCareSpace.x4),
                          _bigButton('Back to Activities', widget.onBack),
                        ])),
                    ]),
              ),
            ),
          );
        },
      );

  Widget _buildOdd(Map<String, dynamic> round) {
    final items = (round['items'] as List).cast<Map<String, dynamic>>();
    return _panel(
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Round ${_roundIndex + 1} of 3',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: KinCareColors.sage)),
      const SizedBox(height: KinCareSpace.x3),
      Text(round['instruction'].toString(),
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 25,
              height: 1.4,
              fontWeight: FontWeight.w700,
              color: KinCareColors.forest)),
      const SizedBox(height: KinCareSpace.x3),
      _bigButton(
          '🔊  Listen again',
          () => _speak(_spoken(
              (round['spoken'] as Map?)?[_languageCode]?['instruction'],
              fallback: round['instruction'].toString())),
          primary: false),
      const SizedBox(height: KinCareSpace.x4),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: KinCareSpace.x3,
        mainAxisSpacing: KinCareSpace.x3,
        childAspectRatio: 1.15,
        children: items.map((item) {
          final selected = _selectedOddItem == item['id'];
          return Semantics(
            button: true,
            label: 'Choose ${item['label']}',
            child: OutlinedButton(
              onPressed: _busy || _oddResponseSaved
                  ? null
                  : () {
                      _speak(_spoken(item['spoken'],
                          fallback: item['label'].toString()));
                      _chooseOdd(round, item['id'].toString());
                    },
              style: OutlinedButton.styleFrom(
                backgroundColor:
                    selected ? KinCareColors.paleSage : KinCareColors.offWhite,
                side: BorderSide(
                    color: selected
                        ? KinCareColors.sage
                        : KinCareColors.lineStrong,
                    width: 2),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(KinCareRadii.lg)),
              ),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(item['illustration'].toString(),
                        style: const TextStyle(fontSize: 46)),
                    const SizedBox(height: 5),
                    Text(item['label'].toString(),
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: KinCareColors.forest)),
                  ]),
            ),
          );
        }).toList(),
      ),
      if (_feedback != null) ...[
        const SizedBox(height: KinCareSpace.x4),
        Text(_feedback!,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: KinCareColors.forest))
      ],
      if (_error != null && _selectedOddItem != null && !_oddResponseSaved) ...[
        const SizedBox(height: KinCareSpace.x3),
        _bigButton(
            'Try saving answer again', _busy ? null : () => _retryOdd(round),
            primary: false),
      ],
      if (_oddResponseSaved && _roundIndex < 2) ...[
        const SizedBox(height: KinCareSpace.x4),
        _bigButton('Next Round', () async {
          setState(() {
            _roundIndex++;
            _selectedOddItem = null;
            _oddResponseSaved = false;
            _feedback = null;
          });
          await _saveCheckpoint();
        }),
      ],
      if (_oddResponseSaved && _roundIndex == 2 && _stage != 'complete') ...[
        const SizedBox(height: KinCareSpace.x4),
        _bigButton(_busy ? 'Saving…' : 'Finish Activity',
            _busy ? null : _completeOddActivity),
      ],
    ]));
  }

  Widget _buildSorting(Map<String, dynamic> sorting) {
    final items = (sorting['items'] as List).cast<Map<String, dynamic>>();
    final categories =
        (sorting['categories'] as List).cast<Map<String, dynamic>>();
    final categorized = _categorizedCount(items);
    return _panel(
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(sorting['instruction'].toString(),
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 25,
              height: 1.4,
              fontWeight: FontWeight.w700,
              color: KinCareColors.forest)),
      const SizedBox(height: KinCareSpace.x3),
      _bigButton(
          '🔊  Listen again',
          () => _speak(_spoken(
              (sorting['spoken'] as Map?)?[_languageCode]?['instruction'],
              fallback: sorting['instruction'].toString())),
          primary: false),
      const SizedBox(height: KinCareSpace.x4),
      SortingGameProgress(
        categorizedCount: categorized,
        totalCount: items.length,
        busy: _busy,
        onFinish: () => _finishSorting(sorting),
      ),
      const SizedBox(height: KinCareSpace.x3),
      for (final item in items) ...[
        _sortingItem(item, categories),
        const SizedBox(height: KinCareSpace.x2),
      ],
      const SizedBox(height: KinCareSpace.x3),
      LayoutBuilder(builder: (context, constraints) {
        final buttons = categories.map<Widget>((category) {
          final button = _bigButton(
            '${category['illustration']}  ${category['label']}',
            _selectedSortingItem == null || _busy
                ? null
                : () {
                    final selectedItem = items.firstWhere(
                      (item) => item['id'] == _selectedSortingItem,
                    );
                    final updatedPlacements = replaceSortingPlacement(
                        _placements,
                        _selectedSortingItem!,
                        category['id'].toString());
                    setState(() {
                      _placements
                        ..clear()
                        ..addAll(updatedPlacements);
                      _selectedSortingItem = null;
                      _feedback =
                          'Object placed. Choose it again if you would like to move it.';
                    });
                    unawaited(_saveCheckpoint());
                    _speak(spokenPlacement(
                      _languageCode,
                      _spoken(selectedItem['spoken'],
                          fallback: selectedItem['label'].toString()),
                      _spoken(category['spoken'],
                          fallback: category['label'].toString()),
                    ));
                  },
            primary: false,
          );
          return constraints.maxWidth < 520
              ? Padding(
                  padding: const EdgeInsets.only(bottom: KinCareSpace.x2),
                  child: button)
              : Expanded(child: button);
        }).toList();
        return constraints.maxWidth < 520
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: buttons)
            : Row(children: [
                buttons[0],
                const SizedBox(width: KinCareSpace.x3),
                buttons[1]
              ]);
      }),
      if (_feedback != null) ...[
        const SizedBox(height: KinCareSpace.x3),
        Text(_feedback!,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: KinCareColors.forest))
      ],
      if (_error != null) ...[
        const SizedBox(height: KinCareSpace.x2),
        _bigButton(
            'Try saving again', _busy ? null : () => _finishSorting(sorting),
            primary: false)
      ],
      const SizedBox(height: KinCareSpace.x4),
    ]));
  }

  Widget _sortingItem(
      Map<String, dynamic> item, List<Map<String, dynamic>> categories) {
    final categoryId = _placements[item['id']];
    final category =
        categories.where((row) => row['id'] == categoryId).firstOrNull;
    return SizedBox(
      height: 82,
      child: OutlinedButton(
        onPressed: () {
          setState(() {
            _selectedSortingItem = item['id'].toString();
            _feedback = 'Choose a group for ${item['label']}.';
            _speak(_spoken(item['spoken'], fallback: item['label'].toString()));
          });
          unawaited(_saveCheckpoint());
        },
        style: OutlinedButton.styleFrom(
          backgroundColor: _selectedSortingItem == item['id']
              ? KinCareColors.paleSage
              : KinCareColors.offWhite,
          side: BorderSide(
              color: _selectedSortingItem == item['id']
                  ? KinCareColors.sage
                  : KinCareColors.lineStrong,
              width: 2),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(KinCareRadii.md)),
        ),
        child: Row(children: [
          Text(item['illustration'].toString(),
              style: const TextStyle(fontSize: 34)),
          const SizedBox(width: KinCareSpace.x3),
          Expanded(
              child: Text(item['label'].toString(),
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: KinCareColors.forest))),
          Text(category == null ? 'Not grouped' : 'In ${category['label']}',
              style: const TextStyle(
                  fontSize: 15, color: KinCareColors.textMuted)),
        ]),
      ),
    );
  }

  Widget _panel(Widget child) => Container(
        padding: const EdgeInsets.all(KinCareSpace.x5),
        decoration: BoxDecoration(
          color: KinCareColors.white,
          borderRadius: BorderRadius.circular(KinCareRadii.xl),
          border: Border.all(color: KinCareColors.line, width: 2),
        ),
        child: child,
      );
}
