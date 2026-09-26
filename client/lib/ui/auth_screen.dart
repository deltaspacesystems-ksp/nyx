import 'package:flutter/material.dart';

import '../core/api.dart';
import 'common.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool register = false, busy = false, showServer = false, needs2fa = false, useRecovery = false;
  String? error;
  final username = TextEditingController(), display = TextEditingController(), password = TextEditingController();
  final invite = TextEditingController(), code = TextEditingController();
  late final TextEditingController server = TextEditingController(text: context.appRead.server);

  Future<void> submit() async {
    final app = context.appRead;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final s = server.text.trim();
      if (register) {
        await app.register(server: s, username: username.text, displayName: display.text, password: password.text, invite: invite.text);
      } else {
        await app.login(server: s, username: username.text, password: password.text, totp: useRecovery ? null : code.text, recoveryCode: useRecovery ? code.text : null);
      }
    } on ApiException catch (e) {
      if (e.needsTwoFactor) needs2fa = true;
      error = e.needsTwoFactor && code.text.isEmpty ? null : e.message;
    } catch (e) {
      error = 'Could not reach the server. Check the address and your connection.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final app = context.app;
    return NyxBackground(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Pop(
              child: Glass(
                padding: const EdgeInsets.all(28),
                child: AutofillGroup(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Center(
                      child: Image.asset('assets/logo.png', width: 72, height: 72, filterQuality: FilterQuality.high),
                    ),
                    const SizedBox(height: 16),
                    Text('Nyx', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                    Text(needs2fa ? 'Two-factor authentication' : (register ? 'Create your account' : 'Welcome back'), textAlign: TextAlign.center, style: TextStyle(color: context.muted)),
                    if (app.notice != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: cs.primary.withValues(alpha: .15), borderRadius: BorderRadius.circular(10)),
                        child: Text(app.notice!, textAlign: TextAlign.center),
                      ),
                    ],
                    const SizedBox(height: 22),
                    if (!needs2fa) ...[
                      TextField(controller: username, autofillHints: const [AutofillHints.username], decoration: const InputDecoration(labelText: 'Username')),
                      Reveal(
                        show: register,
                        child: Column(children: [
                          const SizedBox(height: 12),
                          TextField(controller: display, decoration: const InputDecoration(labelText: 'Display name')),
                          const SizedBox(height: 12),
                          TextField(controller: invite, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Invite code')),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: password,
                        obscureText: true,
                        autofillHints: [register ? AutofillHints.newPassword : AutofillHints.password],
                        onSubmitted: (_) => submit(),
                        decoration: const InputDecoration(labelText: 'Password'),
                      ),
                    ] else ...[
                      TextField(
                        controller: code,
                        autofocus: true,
                        onSubmitted: (_) => submit(),
                        keyboardType: useRecovery ? TextInputType.text : TextInputType.number,
                        decoration: InputDecoration(labelText: useRecovery ? 'Recovery code' : '6-digit code from your authenticator app'),
                      ),
                      Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => setState(() { useRecovery = !useRecovery; code.clear(); }), child: Text(useRecovery ? 'Use authenticator code' : 'Use a recovery code'))),
                    ],
                    Reveal(show: showServer, child: Padding(padding: const EdgeInsets.only(top: 12), child: TextField(controller: server, decoration: const InputDecoration(labelText: 'Server address')))),
                    Reveal(show: error != null, child: Padding(padding: const EdgeInsets.only(top: 12), child: Text(error ?? '', style: TextStyle(color: cs.error)))),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: busy ? null : submit,
                      child: busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(needs2fa ? 'Verify' : (register ? 'Create account' : 'Log in')),
                    ),
                    const SizedBox(height: 8),
                    Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      if (needs2fa)
                        TextButton(onPressed: () => setState(() { needs2fa = false; code.clear(); error = null; }), child: const Text('Back'))
                      else
                        TextButton(onPressed: () => setState(() { register = !register; error = null; }), child: Text(register ? 'I have an account' : 'Have an invite?')),
                      TextButton(onPressed: () => setState(() => showServer = !showServer), child: const Text('Server')),
                    ]),
                    const SizedBox(height: 4),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.lock, size: 14, color: context.faint),
                      const SizedBox(width: 6),
                      Text('End-to-end encrypted', style: TextStyle(fontSize: 12, color: context.faint)),
                    ]),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
