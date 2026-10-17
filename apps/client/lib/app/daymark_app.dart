import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/daymark_theme.dart';
import '../features/tasks/tasks_home.dart';
import 'app_controller.dart';
import 'app_scope.dart';

/// Root widget. Creates the production [AppController] unless one is injected
/// (tests pass a controller wired to an in-memory database).
class DayMarkApp extends StatefulWidget {
  const DayMarkApp({super.key, this.controller});

  final AppController? controller;

  @override
  State<DayMarkApp> createState() => _DayMarkAppState();
}

class _DayMarkAppState extends State<DayMarkApp> {
  late final AppController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? AppController.production();
    if (_ownsController) unawaited(_controller.init());
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: _controller,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: _controller.themeMode,
        builder: (BuildContext context, ThemeMode mode, Widget? _) {
          return MaterialApp(
            title: 'DayMark',
            debugShowCheckedModeBanner: false,
            theme: DaymarkTheme.light,
            darkTheme: DaymarkTheme.dark,
            themeMode: mode,
            home: const TasksHome(),
          );
        },
      ),
    );
  }
}
