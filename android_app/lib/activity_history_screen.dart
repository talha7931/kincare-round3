import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_theme.dart';

class CaregiverActivityHistoryScreen extends StatefulWidget {
  final List<Map<String, dynamic>> profiles;

  const CaregiverActivityHistoryScreen({super.key, required this.profiles});

  @override
  State<CaregiverActivityHistoryScreen> createState() =>
      _CaregiverActivityHistoryScreenState();
}

class _CaregiverActivityHistoryScreenState
    extends State<CaregiverActivityHistoryScreen> {
  final _client = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _sessions = [];
  Map<String, String> _activityNames = {};
  Map<String, List<Map<String, dynamic>>> _responses = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (widget.profiles.isEmpty) {
        setState(() { _sessions = []; _loading = false; });
        return;
      }
      final profileIds = widget.profiles.map((p) => p['id'].toString()).toList();
      final sessions = await _client
          .from('activity_sessions')
          .select('id, elderly_profile_id, activity_type_id, started_at, completed_at, status')
          .inFilter('elderly_profile_id', profileIds)
          .order('started_at', ascending: false)
          .limit(100);
      final loaded = List<Map<String, dynamic>>.from(sessions);
      final typeIds = loaded.map((row) => row['activity_type_id'].toString()).toSet().toList();
      final sessionIds = loaded.map((row) => row['id'].toString()).toList();
      final types = typeIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await _client
              .from('activity_types')
              .select('id, name')
              .inFilter('id', typeIds));
      final responseRows = sessionIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await _client
              .from('activity_responses')
              .select('session_id, response_index, response_payload')
              .inFilter('session_id', sessionIds)
              .order('response_index'));
      final names = <String, String>{for (final row in types) row['id'].toString(): row['name'].toString()};
      final responseMap = <String, List<Map<String, dynamic>>>{};
      for (final response in responseRows) {
        (responseMap[response['session_id'].toString()] ??= []).add(response);
      }
      if (mounted) setState(() {
        _sessions = loaded;
        _activityNames = names;
        _responses = responseMap;
        _loading = false;
      });
    } catch (error) {
      if (mounted) setState(() { _error = error.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileNames = {
      for (final profile in widget.profiles)
        profile['id'].toString(): profile['display_name'].toString(),
    };
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(KinCareSpace.x5),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!, style: const TextStyle(color: KinCareColors.danger)),
          const SizedBox(height: KinCareSpace.x3),
          FilledButton(onPressed: _load, child: const Text('Try again')),
        ]),
      ));
    }
    if (_sessions.isEmpty) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(KinCareSpace.x6),
        child: Text('No activities have been recorded for these profiles yet.', textAlign: TextAlign.center, style: TextStyle(fontSize: 20)),
      ));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(KinCareSpace.x4),
        itemCount: _sessions.length,
        separatorBuilder: (_, __) => const SizedBox(height: KinCareSpace.x3),
        itemBuilder: (context, index) {
          final session = _sessions[index];
          final sessionId = session['id'].toString();
          final started = DateTime.tryParse(session['started_at'].toString())?.toLocal();
          final responseRows = _responses[sessionId] ?? const [];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(KinCareSpace.x4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_activityNames[session['activity_type_id'].toString()] ?? 'Activity', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: KinCareColors.forest)),
                const SizedBox(height: KinCareSpace.x2),
                Text('Profile: ${profileNames[session['elderly_profile_id'].toString()] ?? 'Profile'}'),
                Text('Started: ${started?.toString() ?? session['started_at']}'),
                Text('Status: ${session['status']}'),
                for (final response in responseRows) ...[
                  const SizedBox(height: KinCareSpace.x1),
                  Text(_responseSummary(response['response_payload'] as Map<String, dynamic>, response['response_index'] as int)),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }

  String _responseSummary(Map<String, dynamic> payload, int index) {
    if (payload['activity_type'] == 'odd_one_out') {
      return 'Round ${index + 1}: selected ${payload['selected_item_id']}';
    }
    return '${payload['item_id']} placed in ${payload['selected_category_id']}';
  }
}
