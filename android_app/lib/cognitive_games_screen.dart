import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'app_theme.dart';
import 'cognitive_game_rules.dart';

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
  late Future<Map<String, dynamic>> _contentFuture;
  String? _sessionId;
  String? _error;
  String? _feedback;
  String _stage = 'intro';
  bool _busy = false;
  int _roundIndex = 0;
  String? _selectedOddItem;
  bool _oddResponseSaved = false;
  final Map<String, String> _placements = {};
  String? _selectedSortingItem;
  final Map<String, String> _responseIds = {};

  bool get _isSorting => widget.gameKey == everydayObjectSortingActivityKey;
  String get _activityKey => widget.gameKey;
  String get _title => _isSorting ? 'Everyday Object Sorting' : 'Odd One Out';
  // Bundled prompts and object labels are English.
  String get _language => 'en-IN';

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
        setState(() => _error = 'Audio is unavailable. Please read the instruction shown on screen.');
      }
    }
  }

  Future<void> _startSession() async {
    setState(() { _busy = true; _error = null; });
    try {
      final user = _client.auth.currentUser;
      if (user == null) throw StateError('Sign in again before starting an activity.');
      final preferences = await SharedPreferences.getInstance();
      var deviceUuid = preferences.getString('kincare.device_uuid');
      if (deviceUuid == null || deviceUuid.isEmpty) {
        deviceUuid = _uuid.v4();
        await preferences.setString('kincare.device_uuid', deviceUuid);
      }
      final device = await _client
          .from('enrolled_devices')
          .upsert({
            'caregiver_id': user.id,
            'device_uuid': deviceUuid,
            'device_name': 'KinCare Android device',
            'last_seen_at': DateTime.now().toUtc().toIso8601String(),
          }, onConflict: 'caregiver_id,device_uuid')
          .select('id')
          .single();
      final activity = await _client
          .from('activity_types')
          .select('id')
          .eq('stable_key', _activityKey)
          .single();
      final sessionId = _uuid.v4();
      await _client.from('activity_sessions').insert({
        'id': sessionId,
        'elderly_profile_id': widget.selectedProfile['id'],
        'activity_type_id': activity['id'],
        'device_id': device['id'],
        'status': 'in_progress',
      });
      if (!mounted) return;
      setState(() { _sessionId = sessionId; _stage = 'playing'; });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveResponses(List<Map<String, dynamic>> responses) async {
    final ids = responses.map((row) => row['id'].toString()).toList();
    final existing = await _client.from('activity_responses').select('id').inFilter('id', ids);
    final existingIds = (existing as List).map((row) => row['id'].toString()).toSet();
    final missing = responses.where((row) => !existingIds.contains(row['id'])).toList();
    if (missing.isEmpty) return;
    try {
      await _client.from('activity_responses').insert(missing);
    } catch (error) {
      final confirmed = await _client.from('activity_responses').select('id').inFilter('id', ids);
      final confirmedIds = (confirmed as List).map((row) => row['id'].toString()).toSet();
      if (ids.any((id) => !confirmedIds.contains(id))) rethrow;
    }
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
      'is_correct': oddOneOutIsCorrect(itemId, round['expected_item_id'].toString()),
      'responded_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<void> _completeSession() async {
    if (_sessionId == null) return;
    await _client.from('activity_sessions').update({
      'status': 'completed',
      'completed_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', _sessionId!);
    if (mounted) setState(() { _stage = 'complete'; _feedback = 'Thank you for taking part. You can enjoy another activity whenever you like.'; });
  }

  Future<void> _leaveActivity({required bool home}) async {
    if (_busy) return;
    if (_sessionId != null && _stage == 'playing') {
      setState(() { _busy = true; _error = null; });
      try {
        await _client.from('activity_sessions').update({'status': 'abandoned'}).eq('id', _sessionId!);
      } catch (error) {
        if (mounted) setState(() { _error = error.toString(); _busy = false; });
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
    setState(() { _busy = true; _error = null; _selectedOddItem = itemId; });
    try {
      await _saveResponses([_oddResponse(round, itemId)]);
      final correct = itemId == round['expected_item_id'];
      if (mounted) setState(() {
        _oddResponseSaved = true;
        _feedback = correct
            ? 'Well done! ${round['explanation']}'
            : 'That’s okay. ${round['explanation']}';
      });
      if (_roundIndex == 2) await _completeSession();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryOdd(Map<String, dynamic> round) async {
    if (_selectedOddItem == null || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _saveResponses([_oddResponse(round, _selectedOddItem!)]);
      if (mounted) setState(() {
        _oddResponseSaved = true;
        _feedback = _selectedOddItem == round['expected_item_id']
            ? 'Well done! ${round['explanation']}'
            : 'That’s okay. ${round['explanation']}';
      });
      if (_roundIndex == 2) await _completeSession();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishSorting(Map<String, dynamic> sorting) async {
    if (_busy || _placements.length != (sorting['items'] as List).length) return;
    setState(() { _busy = true; _error = null; });
    try {
      final items = (sorting['items'] as List).cast<Map<String, dynamic>>();
      final responses = <Map<String, dynamic>>[];
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final selectedCategory = _placements[item['id']];
        final responseId = _responseIds.putIfAbsent('sort-${item['id']}', _uuid.v4);
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
          'is_correct': sortingIsCorrect(selectedCategory ?? '', item['category_id'].toString()),
          'responded_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
      await _saveResponses(responses);
      await _completeSession();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _bigButton(String label, VoidCallback? onPressed, {bool primary = true}) =>
      SizedBox(
        height: KinCareSenior.controlHeight,
        child: primary
            ? FilledButton(onPressed: onPressed, child: Text(label, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700)))
            : OutlinedButton(onPressed: onPressed, child: Text(label, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700))),
      );

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
        future: _contentFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final content = snapshot.data!;
          final rounds = (content['odd_one_out'] as List).cast<Map<String, dynamic>>();
          final sorting = content['everyday_object_sorting'] as Map<String, dynamic>;
          final round = rounds[_roundIndex];
          final instruction = _isSorting ? sorting['instruction'].toString() : round['instruction'].toString();
          return SingleChildScrollView(
            padding: const EdgeInsets.all(KinCareSpace.x5),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: _bigButton('Activities', _busy ? null : () => _leaveActivity(home: false), primary: false)),
                    const SizedBox(width: KinCareSpace.x3),
                    Expanded(child: _bigButton('Home', _busy ? null : () => _leaveActivity(home: true), primary: false)),
                  ]),
                  const SizedBox(height: KinCareSpace.x4),
                  Text(_title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: KinCareColors.forest)),
                  if (_error != null) ...[
                    const SizedBox(height: KinCareSpace.x3),
                    Container(padding: const EdgeInsets.all(KinCareSpace.x3), decoration: BoxDecoration(color: KinCareColors.dangerWash, border: Border.all(color: KinCareColors.dangerLine), borderRadius: BorderRadius.circular(KinCareRadii.md)), child: Text(_error!, style: const TextStyle(fontSize: 17, color: KinCareColors.danger))),
                  ],
                  const SizedBox(height: KinCareSpace.x4),
                  if (_stage == 'intro') _panel(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(_isSorting ? sorting['instruction'].toString() : rounds.first['instruction'].toString(), textAlign: TextAlign.center, style: const TextStyle(fontSize: 25, height: 1.4, fontWeight: FontWeight.w700, color: KinCareColors.forest)),
                    const SizedBox(height: KinCareSpace.x4),
                    _bigButton('🔊  Listen to Instructions', () => _speak(instruction), primary: false),
                    const SizedBox(height: KinCareSpace.x3),
                    _bigButton(_busy ? 'Starting…' : 'Begin Activity', _busy ? null : _startSession),
                  ])),
                  if (_stage == 'playing' && !_isSorting) _buildOdd(round),
                  if (_stage == 'playing' && _isSorting) _buildSorting(sorting),
                  if (_stage == 'complete') _panel(Column(children: [
                    const Icon(Icons.spa_outlined, size: 56, color: KinCareColors.sage),
                    const SizedBox(height: KinCareSpace.x3),
                    const Text('Activity complete', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: KinCareColors.forest)),
                    const SizedBox(height: KinCareSpace.x2),
                    Text(_feedback ?? 'Thank you for taking part.', textAlign: TextAlign.center, style: const TextStyle(fontSize: 22)),
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
    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Round ${_roundIndex + 1} of 3', textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: KinCareColors.sage)),
      const SizedBox(height: KinCareSpace.x3),
      Text(round['instruction'].toString(), textAlign: TextAlign.center, style: const TextStyle(fontSize: 25, height: 1.4, fontWeight: FontWeight.w700, color: KinCareColors.forest)),
      const SizedBox(height: KinCareSpace.x3),
      _bigButton('🔊  Listen again', () => _speak(round['instruction'].toString()), primary: false),
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
              onPressed: _busy || _oddResponseSaved ? null : () {
                _speak(item['label'].toString());
                _chooseOdd(round, item['id'].toString());
              },
              style: OutlinedButton.styleFrom(
                backgroundColor: selected ? KinCareColors.paleSage : KinCareColors.offWhite,
                side: BorderSide(color: selected ? KinCareColors.sage : KinCareColors.lineStrong, width: 2),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KinCareRadii.lg)),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(item['illustration'].toString(), style: const TextStyle(fontSize: 46)),
                const SizedBox(height: 5),
                Text(item['label'].toString(), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: KinCareColors.forest)),
              ]),
            ),
          );
        }).toList(),
      ),
      if (_feedback != null) ...[const SizedBox(height: KinCareSpace.x4), Text(_feedback!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: KinCareColors.forest))],
      if (_error != null && _selectedOddItem != null && !_oddResponseSaved) ...[
        const SizedBox(height: KinCareSpace.x3),
        _bigButton('Try saving answer again', _busy ? null : () => _retryOdd(round), primary: false),
      ],
      if (_oddResponseSaved && _roundIndex < 2) ...[
        const SizedBox(height: KinCareSpace.x4),
        _bigButton('Next Round', () => setState(() { _roundIndex++; _selectedOddItem = null; _oddResponseSaved = false; _feedback = null; })),
      ],
      if (_oddResponseSaved && _roundIndex == 2 && _stage != 'complete') ...[
        const SizedBox(height: KinCareSpace.x4),
        _bigButton(_busy ? 'Saving…' : 'Finish Activity', _busy ? null : _completeSession),
      ],
    ]));
  }

  Widget _buildSorting(Map<String, dynamic> sorting) {
    final items = (sorting['items'] as List).cast<Map<String, dynamic>>();
    final categories = (sorting['categories'] as List).cast<Map<String, dynamic>>();
    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(sorting['instruction'].toString(), textAlign: TextAlign.center, style: const TextStyle(fontSize: 25, height: 1.4, fontWeight: FontWeight.w700, color: KinCareColors.forest)),
      const SizedBox(height: KinCareSpace.x3),
      _bigButton('🔊  Listen again', () => _speak(sorting['instruction'].toString()), primary: false),
      const SizedBox(height: KinCareSpace.x4),
      for (final item in items) ...[
        _sortingItem(item, categories),
        const SizedBox(height: KinCareSpace.x2),
      ],
      const SizedBox(height: KinCareSpace.x3),
      Row(children: [
        for (var index = 0; index < categories.length; index++) ...[
          if (index > 0) const SizedBox(width: KinCareSpace.x3),
          Expanded(child: _bigButton(
            '${categories[index]['illustration']}  ${categories[index]['label']}',
            _selectedSortingItem == null || _busy ? null : () {
              setState(() {
                _placements[_selectedSortingItem!] = categories[index]['id'].toString();
                _selectedSortingItem = null;
                _feedback = 'Object placed. Choose it again if you would like to move it.';
              });
              _speak(categories[index]['label'].toString());
            },
            primary: false,
          )),
        ],
      ]),
      if (_feedback != null) ...[const SizedBox(height: KinCareSpace.x3), Text(_feedback!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: KinCareColors.forest))],
      if (_error != null) ...[const SizedBox(height: KinCareSpace.x2), _bigButton('Try saving again', _busy ? null : () => _finishSorting(sorting), primary: false)],
      const SizedBox(height: KinCareSpace.x4),
      _bigButton(_busy ? 'Saving your choices…' : 'Finish Sorting', _placements.length == items.length && !_busy ? () => _finishSorting(sorting) : null),
    ]));
  }

  Widget _sortingItem(Map<String, dynamic> item, List<Map<String, dynamic>> categories) {
    final categoryId = _placements[item['id']];
    final category = categories.where((row) => row['id'] == categoryId).firstOrNull;
    return SizedBox(
      height: 82,
      child: OutlinedButton(
        onPressed: () => setState(() {
          _selectedSortingItem = item['id'].toString();
          _feedback = 'Choose a group for ${item['label']}.';
          _speak(item['label'].toString());
        }),
        style: OutlinedButton.styleFrom(
          backgroundColor: _selectedSortingItem == item['id'] ? KinCareColors.paleSage : KinCareColors.offWhite,
          side: BorderSide(color: _selectedSortingItem == item['id'] ? KinCareColors.sage : KinCareColors.lineStrong, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KinCareRadii.md)),
        ),
        child: Row(children: [
          Text(item['illustration'].toString(), style: const TextStyle(fontSize: 34)),
          const SizedBox(width: KinCareSpace.x3),
          Expanded(child: Text(item['label'].toString(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: KinCareColors.forest))),
          Text(category == null ? 'Choose' : 'In ${category['label']}', style: const TextStyle(fontSize: 15, color: KinCareColors.textMuted)),
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
