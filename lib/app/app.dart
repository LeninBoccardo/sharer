import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../presentation/home/home_screen.dart';
import 'providers.dart';

class SharerApp extends ConsumerStatefulWidget {
  const SharerApp({super.key});

  @override
  ConsumerState<SharerApp> createState() => _SharerAppState();
}

class _SharerAppState extends ConsumerState<SharerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Event-driven announce-burst (CLAUDE.md principle #3 / hot-path
      // 3(c)): the moment the user brings Sharer back to the foreground,
      // re-sample the network and re-advertise in place so a freshly
      // visible peer list is ready before they tap. Fire-and-forget; both
      // legs of refreshDiscovery are trust-gated no-ops in quiet mode, so
      // this costs nothing on an untrusted network and never blocks the UI.
      unawaited(refreshDiscovery(ref));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sharer',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5C6BC0),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
    );
  }
}
