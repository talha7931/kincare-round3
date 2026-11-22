import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_theme.dart';
import 'engagement_reporting.dart';

class CaregiverDashboardScreen extends StatefulWidget {
  final List<Map<String, dynamic>> profiles;
  final String caregiverName;
  final ValueChanged<String> onOpenProfileReport;

  const CaregiverDashboardScreen({
    super.key,
    required this.profiles,
    required this.caregiverName,
    required this.onOpenProfileReport,
  });

  @override
  State<CaregiverDashboardScreen> createState() =>
      _CaregiverDashboardScreenState();
}

class _CaregiverDashboardScreenState extends State<CaregiverDashboardScreen> {
  bool _loading = true;
  String? _error;
  List<ActivitySessionRecord> _sessions = [];
  late DateTime _startUtc;
  late DateTime _endUtc;

  @override
  void initState() {
    super.initState();
    _setDefaultPeriod();
    _load();
  }

  @override
  void didUpdateWidget(covariant CaregiverDashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.profiles.map((row) => row['id']).join(',');
    final newIds = widget.profiles.map((row) => row['id']).join(',');
    if (oldIds != newIds) _load();
  }

  void _setDefaultPeriod() {
    _endUtc = reportingUtcDate(DateTime.now().toUtc());
    _startUtc = _endUtc.subtract(const Duration(days: 29));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await loadCaregiverReportingData(
        Supabase.instance.client,
        widget.profiles,
      );
      if (mounted)
        setState(() {
          _sessions = data.sessions;
          _loading = false;
        });
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _loading = false;
        });
    }
  }

  Future<void> _pickDate({required bool start}) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: start ? _startUtc : _endUtc,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: start ? 'UTC period start' : 'UTC period end',
    );
    if (selected == null || !mounted) return;
    final day = DateTime.utc(selected.year, selected.month, selected.day);
    setState(() {
      if (start) {
        _startUtc = day;
        if (_startUtc.isAfter(_endUtc)) _endUtc = _startUtc;
      } else {
        _endUtc = day;
        if (_endUtc.isBefore(_startUtc)) _startUtc = _endUtc;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final metrics = EngagementMetrics.calculate(_sessions, _startUtc, _endUtc);
    final profileNames = {
      for (final profile in widget.profiles)
        profile['id'].toString():
            profile['display_name']?.toString() ?? 'Profile',
    };
    final recent = _sessions
        .where((session) =>
            !reportingUtcDate(session.startedAtUtc).isBefore(_startUtc) &&
            !reportingUtcDate(session.startedAtUtc).isAfter(_endUtc))
        .take(8)
        .toList();
    final maxWeekly =
        metrics.sessionsByWeek.values.fold<int>(1, (a, b) => a > b ? a : b);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(KinCareSpace.x4),
        children: [
          Text(
            widget.caregiverName.isEmpty
                ? 'Your engagement overview'
                : 'Welcome, ${widget.caregiverName}',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: KinCareColors.forest,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: KinCareSpace.x2),
          const Text('Factual activity history for the people you support.'),
          const SizedBox(height: KinCareSpace.x4),
          _periodPicker(),
          const SizedBox(height: KinCareSpace.x3),
          if (_error != null)
            _errorCard()
          else if (_loading)
            const Center(
                child: Padding(
              padding: EdgeInsets.all(KinCareSpace.x6),
              child: CircularProgressIndicator(),
            ))
          else ...[
            _metricCards(metrics),
            const SizedBox(height: KinCareSpace.x4),
            _activityBreakdown(metrics),
            const SizedBox(height: KinCareSpace.x4),
            _weeklyTrend(metrics, maxWeekly),
            const SizedBox(height: KinCareSpace.x4),
            _profileList(),
            const SizedBox(height: KinCareSpace.x4),
            _recentActivity(recent, profileNames),
            const SizedBox(height: KinCareSpace.x3),
            const Text(
              'Cloud coverage: synced activity visible to this caregiver. Dates and trends use UTC. This is an engagement summary, not a clinical assessment.',
              style: TextStyle(color: KinCareColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _periodPicker() => Card(
        child: Padding(
          padding: const EdgeInsets.all(KinCareSpace.x3),
          child: Wrap(
            spacing: KinCareSpace.x2,
            runSpacing: KinCareSpace.x2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Reporting period (UTC)'),
              OutlinedButton.icon(
                onPressed: () => _pickDate(start: true),
                icon: const Icon(Icons.calendar_month),
                label: Text(_formatDay(_startUtc)),
              ),
              const Text('to'),
              OutlinedButton.icon(
                onPressed: () => _pickDate(start: false),
                icon: const Icon(Icons.calendar_month),
                label: Text(_formatDay(_endUtc)),
              ),
              TextButton(
                onPressed: () => setState(_setDefaultPeriod),
                child: const Text('Last 30 days'),
              ),
            ],
          ),
        ),
      );

  Widget _metricCards(EngagementMetrics metrics) => LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth > 760
              ? 4
              : constraints.maxWidth > 460
                  ? 2
                  : 1;
          final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
          final values = [
            (
              'Elderly profiles',
              widget.profiles.length.toString(),
              Icons.people_outline
            ),
            (
              'Activity sessions',
              metrics.totalSessions.toString(),
              Icons.event_note
            ),
            (
              'Participation days',
              metrics.participationDays.toString(),
              Icons.calendar_today
            ),
            (
              'Completion',
              _rate(metrics.completionRate),
              Icons.check_circle_outline
            ),
          ];
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final value in values)
                SizedBox(
                    width: width,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(KinCareSpace.x3),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(value.$3, color: KinCareColors.sage),
                              const SizedBox(height: KinCareSpace.x2),
                              Text(value.$2,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(
                                          color: KinCareColors.forest,
                                          fontWeight: FontWeight.w700)),
                              Text(value.$1,
                                  style: const TextStyle(
                                      color: KinCareColors.textMuted)),
                            ]),
                      ),
                    )),
            ],
          );
        },
      );

  Widget _activityBreakdown(EngagementMetrics metrics) => Card(
        child: Padding(
          padding: const EdgeInsets.all(KinCareSpace.x4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Sessions by activity',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: KinCareColors.forest)),
            const SizedBox(height: KinCareSpace.x2),
            if (metrics.sessionsByActivity.isEmpty)
              const Text('No activities were recorded in this period.')
            else
              for (final entry in metrics.sessionsByActivity.entries)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(entry.key),
                  trailing: Text(entry.value.toString(),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
            Text(
                'Sessions per calendar day: ${metrics.sessionsPerDay?.toStringAsFixed(2) ?? '—'}',
                style: const TextStyle(color: KinCareColors.textMuted)),
          ]),
        ),
      );

  Widget _weeklyTrend(EngagementMetrics metrics, int maxWeekly) => Card(
        child: Padding(
          padding: const EdgeInsets.all(KinCareSpace.x4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Weekly activity trend (UTC)',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: KinCareColors.forest)),
            const SizedBox(height: KinCareSpace.x3),
            if (metrics.sessionsByWeek.isEmpty)
              const Text(
                  'Weekly activity will appear after sessions are recorded.')
            else
              for (final entry in (metrics.sessionsByWeek.entries.toList()
                    ..sort((a, b) => a.key.compareTo(b.key)))
                  .take(8))
                Padding(
                  padding: const EdgeInsets.only(bottom: KinCareSpace.x2),
                  child: Row(children: [
                    SizedBox(width: 102, child: Text(_formatDay(entry.key))),
                    Expanded(
                        child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: entry.value / maxWeekly,
                        minHeight: 14,
                        color: KinCareColors.sage,
                        backgroundColor: KinCareColors.paleSage,
                      ),
                    )),
                    const SizedBox(width: KinCareSpace.x2),
                    Text(entry.value.toString()),
                  ]),
                ),
          ]),
        ),
      );

  Widget _profileList() => Card(
        child: Padding(
          padding: const EdgeInsets.all(KinCareSpace.x4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Individual reports',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: KinCareColors.forest)),
            if (widget.profiles.isEmpty)
              const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('Add an elderly profile to view reports.'))
            else
              for (final profile in widget.profiles)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                      backgroundColor: KinCareColors.paleSage,
                      child: Icon(Icons.person_outline,
                          color: KinCareColors.forest)),
                  title: Text(profile['display_name']?.toString() ?? 'Profile'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      widget.onOpenProfileReport(profile['id'].toString()),
                ),
          ]),
        ),
      );

  Widget _recentActivity(List<ActivitySessionRecord> sessions,
          Map<String, String> profileNames) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(KinCareSpace.x4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Recent activity',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: KinCareColors.forest)),
            if (sessions.isEmpty)
              const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('No activity has been recorded in this period.'))
            else
              for (final session in sessions)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(session.activityName),
                  subtitle: Text(
                      '${profileNames[session.profileId] ?? 'Profile'} · ${_formatTimestamp(session.startedAtUtc)} · ${session.displayStatus}'),
                  onTap: () => widget.onOpenProfileReport(session.profileId),
                ),
          ]),
        ),
      );

  Widget _errorCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(KinCareSpace.x4),
          child: Column(children: [
            Text(_error!, style: const TextStyle(color: KinCareColors.danger)),
            const SizedBox(height: 12),
            FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again')),
          ]),
        ),
      );
}

String _formatDay(DateTime utc) =>
    '${utc.year.toString().padLeft(4, '0')}-${utc.month.toString().padLeft(2, '0')}-${utc.day.toString().padLeft(2, '0')}';

String _formatTimestamp(DateTime utc) =>
    '${_formatDay(utc)} ${utc.hour.toString().padLeft(2, '0')}:${utc.minute.toString().padLeft(2, '0')} UTC';

String _rate(double? value) =>
    value == null ? '—' : '${(value * 100).round()}%';
