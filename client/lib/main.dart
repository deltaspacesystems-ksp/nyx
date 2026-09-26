import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'state/app_state.dart';
import 'theme/nyx_theme.dart';
import 'ui/auth_screen.dart';
import 'ui/common.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final theme = ThemeController();
  final app = AppState();
  await theme.load();
  runApp(NyxApp(app: app, theme: theme));
  app.init();
}

class NyxApp extends StatelessWidget {
  final AppState app;
  final ThemeController theme;
  const NyxApp({super.key, required this.app, required this.theme});

  @override
  Widget build(BuildContext context) => NyxTheme(
        controller: theme,
        child: AppScope(
          state: app,
          child: ListenableBuilder(
            listenable: theme,
            builder: (context, _) => MaterialApp(
              title: 'Nyx',
              debugShowCheckedModeBanner: false,
              theme: theme.build(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(theme.settings.fontScale)),
                child: child!,
              ),
              home: const _Root(),
            ),
          ),
        ),
      );
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final t = context.nyx;
    return AnimatedSwitcher(
      duration: t.reduceMotion ? Duration.zero : const Duration(milliseconds: 400),
      switchInCurve: Curves.easeOutCubic,
      child: !app.ready
          ? const Scaffold(key: ValueKey('splash'), body: Center(child: CircularProgressIndicator()))
          : app.signedIn
              ? const Shell(key: ValueKey('shell'))
              : const AuthScreen(key: ValueKey('auth')),
    );
  }
}
