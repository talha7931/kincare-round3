import 'package:flutter/material.dart';

import 'app_theme.dart';

class CaregiverNavigationActions extends StatelessWidget {
  final bool seniorMode;
  final String caregiverSection;
  final ValueChanged<String> onSectionSelected;
  final VoidCallback onToggleMode;
  final VoidCallback onSignOut;

  const CaregiverNavigationActions({
    super.key,
    required this.seniorMode,
    required this.caregiverSection,
    required this.onSectionSelected,
    required this.onToggleMode,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 980) {
      return PopupMenuButton<String>(
        tooltip: 'Open navigation menu',
        icon: const Icon(Icons.menu),
        onSelected: (action) {
          switch (action) {
            case 'profiles':
            case 'overview':
            case 'reports':
            case 'memory':
            case 'activity':
              onSectionSelected(action);
            case 'mode':
              onToggleMode();
            case 'signout':
              onSignOut();
          }
        },
        itemBuilder: (context) => [
          if (!seniorMode) ...[
            const PopupMenuItem(value: 'overview', child: Text('Dashboard')),
            const PopupMenuItem(value: 'profiles', child: Text('Profiles')),
            const PopupMenuItem(value: 'memory', child: Text('Memory Decks')),
            const PopupMenuItem(
                value: 'activity', child: Text('Activity history')),
            const PopupMenuItem(value: 'reports', child: Text('Reports')),
          ],
          PopupMenuItem(
            value: 'mode',
            child: Text(seniorMode ? 'Caregiver mode' : 'Elderly mode'),
          ),
          const PopupMenuItem(value: 'signout', child: Text('Sign out')),
        ],
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (!seniorMode) ...[
        _sectionButton('overview', 'Dashboard'),
        _sectionButton('profiles', 'Profiles'),
        _sectionButton('memory', 'Memory Decks'),
        _sectionButton('activity', 'Activity history'),
        _sectionButton('reports', 'Reports'),
      ],
      TextButton(
        onPressed: onToggleMode,
        child: Text(seniorMode ? 'Caregiver mode' : 'Elderly mode'),
      ),
      IconButton(
        onPressed: onSignOut,
        tooltip: 'Sign out',
        icon: const Icon(Icons.logout),
      ),
    ]);
  }

  Widget _sectionButton(String section, String label) => TextButton(
        onPressed: () => onSectionSelected(section),
        style: TextButton.styleFrom(
          foregroundColor: caregiverSection == section
              ? KinCareColors.forest
              : KinCareColors.textMuted,
        ),
        child: Text(label),
      );
}
