import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nyx/main.dart';
import 'package:nyx/state/app_state.dart';
import 'package:nyx/theme/nyx_theme.dart';

void main() {
  testWidgets('signed out: login screen, and it switches to registration', (t) async {
    FlutterSecureStorage.setMockInitialValues({});
    final app = AppState();
    await t.runAsync(app.init);
    await t.pumpWidget(NyxApp(app: app, theme: ThemeController()));
    // The background animates forever, so step time by hand instead of pumpAndSettle.
    await t.pump(const Duration(milliseconds: 700));

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('End-to-end encrypted'), findsOneWidget);

    await t.tap(find.text('Have an invite?'));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Create your account'), findsOneWidget);
    expect(find.text('Invite code'), findsOneWidget);
    expect(find.text('Display name'), findsOneWidget);

    await t.tap(find.text('Server'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Server address'), findsOneWidget);
  });
}

