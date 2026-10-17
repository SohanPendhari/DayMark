import 'package:flutter/material.dart';

import '../../app/app_scope.dart';

/// Header button that switches between light and dark.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final showingDark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: showingDark ? 'Switch to light theme' : 'Switch to dark theme',
      icon: Icon(showingDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
      onPressed: () => AppScope.read(context).toggleTheme(Theme.of(context).brightness),
    );
  }
}
