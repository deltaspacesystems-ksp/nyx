import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/api.dart';
import '../core/files.dart';
import '../core/models.dart';
import '../theme/nyx_theme.dart';
import '../voice/voice_controller.dart';
import 'device_panel.dart';
import 'common.dart';
import 'dialogs.dart';
import 'settings_common.dart';
import 'settings_themes.dart';

Future<void> showUserSettings(BuildContext context, {int tab = 0}) => showDialog(
      context: context,
      builder: (c) {
        final app = c.appRead;
        return SettingsFrame(
          title: 'User settings',
          initial: tab,
          tabs: [
            SettingsTab(Icons.person_rounded, 'Profile', (_) => const _ProfileTab()),
            SettingsTab(Icons.shield_rounded, 'Security', (_) => const _SecurityTab()),
            SettingsTab(Icons.palette_rounded, 'Appearance', (_) => const _AppearanceTab()),
            SettingsTab(Icons.extension_rounded, 'Theme packs', (_) => const ThemePacksTab()),
            SettingsTab(Icons.mic_rounded, 'Voice & video', (_) => const _VoiceTab()),
            if (app.isInstanceAdmin) SettingsTab(Icons.admin_panel_settings_rounded, 'This instance', (_) => const _InstanceTab()),
            SettingsTab(Icons.info_outline_rounded, 'About', (_) => const _AboutTab()),
            SettingsTab(Icons.logout_rounded, 'Log out', (_) => const _LogoutTab(), danger: true),
          ],
        );
      },
    );

// =================================================================================== profile

class _ProfileTab extends StatefulWidget {
  const _ProfileTab();

  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<_ProfileTab> {
  late final app = context.appRead;
  late final name = TextEditingController(text: app.me!.displayName);
  late final status = TextEditingController(text: app.me!.profile.status);
  late final bio = TextEditingController(text: app.me!.profile.bio);
  late Profile profile = Profile(bio: app.me!.profile.bio, status: app.me!.profile.status, accent: app.me!.profile.accent, avatar: app.me!.profile.avatar, banner: app.me!.profile.banner, extra: Map.of(app.me!.profile.extra));
  bool saving = false, dirty = false;

  Future<void> save() async {
    setState(() => saving = true);
    profile
      ..bio = bio.text.trim()
      ..status = status.text.trim();
    await run(context, () => app.updateProfile(displayName: name.text.trim().isEmpty ? null : name.text.trim(), profile: profile));
    if (mounted) setState(() {
      saving = false;
      dirty = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final me = app.me!;
    final accent = profile.accent != null ? Color(profile.accent!) : context.cs.primary;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Profile'),
      Text('Only people you share a server or conversation with can see this, and it is encrypted: the server cannot read it.', style: TextStyle(color: context.muted)),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, box) {
        final form = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: name, maxLength: 40, onChanged: (_) => setState(() => dirty = true), decoration: const InputDecoration(labelText: 'Display name')),
          const SizedBox(height: 8),
          TextField(controller: status, maxLength: 80, onChanged: (_) => setState(() => dirty = true), decoration: const InputDecoration(labelText: 'Status', hintText: 'What are you up to?')),
          const SizedBox(height: 8),
          TextField(controller: bio, maxLength: 400, maxLines: 4, onChanged: (_) => setState(() => dirty = true), decoration: const InputDecoration(labelText: 'About me')),
          ColorField(label: 'Profile colour', value: profile.accent == null ? null : Color(profile.accent!), allowNone: true, onChanged: (c) => setState(() {
                profile.accent = c?.toARGB32();
                dirty = true;
              })),
          ImageUploadField(
            label: 'Avatar',
            hint: 'PNG, JPG, GIF or animated WebP, up to 12 MB. Kept in full quality; you choose which part is shown. Animated pictures play on hover.',
            aspect: 1,
            circle: true,
            current: profile.avatar,
            preview: (c) => UserAvatar(UserModel({...{'id': me.id, 'username': me.username, 'displayName': name.text, 'identityPublicKey': '', 'agreementPublicKey': ''}})..profile = profile, size: 64, hoverToPlay: false),
            onPicked: (f, a) async {
              final ref = await app.uploadFile(f, scope: 2, scopeId: me.id);
              setState(() {
                profile.avatar = ref.withAdjust(a.zoom, a.cx, a.cy);
                dirty = true;
              });
            },
            onAdjusted: (a) async => setState(() {
              profile.avatar = profile.avatar!.withAdjust(a.zoom, a.cx, a.cy);
              dirty = true;
            }),
            onRemove: profile.avatar == null
                ? null
                : () => setState(() {
                      profile.avatar = null;
                      dirty = true;
                    }),
          ),
          ImageUploadField(
            label: 'Banner',
            hint: 'Wide picture at the top of your profile (shown about 3:1). GIF and animated WebP are fine.',
            aspect: 3,
            current: profile.banner,
            preview: (c) => ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: 150, child: BannerImage(blob: profile.banner, accent: accent, height: 50))),
            onPicked: (f, a) async {
              final ref = await app.uploadFile(f, scope: 2, scopeId: me.id);
              setState(() {
                profile.banner = ref.withAdjust(a.zoom, a.cx, a.cy);
                dirty = true;
              });
            },
            onAdjusted: (a) async => setState(() {
              profile.banner = profile.banner!.withAdjust(a.zoom, a.cx, a.cy);
              dirty = true;
            }),
            onRemove: profile.banner == null
                ? null
                : () => setState(() {
                      profile.banner = null;
                      dirty = true;
                    }),
          ),
          const SizedBox(height: 20),
          Row(children: [
            FilledButton(onPressed: saving || !dirty ? null : save, child: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save changes')),
            const SizedBox(width: 10),
            if (dirty) TextButton(onPressed: () => setState(() {
                  name.text = me.displayName;
                  status.text = me.profile.status;
                  bio.text = me.profile.bio;
                  profile = Profile(bio: me.profile.bio, status: me.profile.status, accent: me.profile.accent, avatar: me.profile.avatar, banner: me.profile.banner, extra: Map.of(me.profile.extra));
                  dirty = false;
                }), child: const Text('Reset')),
          ]),
        ]);
        final preview = _PreviewCard(name: name.text.isEmpty ? me.username : name.text, username: me.username, profile: profile..status = status.text..bio = bio.text, user: me);
        return box.maxWidth > 620 ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: form), const SizedBox(width: 24), SizedBox(width: 260, child: preview)]) : Column(children: [preview, const SizedBox(height: 20), form]);
      }),
    ]);
  }
}

class _PreviewCard extends StatelessWidget {
  final String name, username;
  final Profile profile;
  final UserModel user;
  const _PreviewCard({required this.name, required this.username, required this.profile, required this.user});

  @override
  Widget build(BuildContext context) {
    final accent = profile.accent != null ? Color(profile.accent!) : context.cs.primary;
    final preview = UserModel({'id': user.id, 'username': username, 'displayName': name, 'identityPublicKey': '', 'agreementPublicKey': '', 'presence': user.presence})..profile = profile;
    return Container(
      decoration: BoxDecoration(color: context.cs.surface, borderRadius: BorderRadius.circular(context.nyx.radius), border: Border.all(color: Theme.of(context).dividerColor)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Stack(clipBehavior: Clip.none, children: [
          BannerImage(blob: profile.banner, accent: accent, height: 84),
          Positioned(left: 14, bottom: -32, child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: context.cs.surface, shape: BoxShape.circle), child: UserAvatar(preview, size: 64, presence: true, hoverToPlay: false))),
        ]),
        const SizedBox(height: 38),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text('@$username', style: TextStyle(color: context.muted)),
            if (profile.status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(profile.status)),
            if (profile.bio.isNotEmpty) ...[const Divider(height: 20), Text(profile.bio)],
          ]),
        ),
      ]),
    );
  }
}

// ================================================================================== security

class _SecurityTab extends StatefulWidget {
  const _SecurityTab();

  @override
  State<_SecurityTab> createState() => _SecurityTabState();
}

class _SecurityTabState extends State<_SecurityTab> {
  late final app = context.appRead;
  Future<List<dynamic>>? sessions, log;

  @override
  void initState() {
    super.initState();
    sessions = app.sessions();
    log = app.securityLog();
  }

  Future<void> _setup2fa() async {
    final res = await app.totpSetup();
    if (!mounted) return;
    final code = TextEditingController();
    List<String>? recovery;
    await showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => NyxDialog(
          title: recovery == null ? 'Turn on two-factor authentication' : 'Save your recovery codes',
          subtitle: recovery == null ? 'Scan with an authenticator app (Google Authenticator, Aegis, 1Password…), then enter the 6-digit code.' : 'Each code works once if you lose your phone. Keep them somewhere safe: they will not be shown again.',
          child: recovery != null
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 10, runSpacing: 6, children: [for (final r in recovery!) SelectableText(r, style: const TextStyle(fontFamily: 'monospace', fontSize: 15, fontWeight: FontWeight.w700))]),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(icon: const Icon(Icons.copy_rounded, size: 18), label: const Text('Copy all'), onPressed: () => Clipboard.setData(ClipboardData(text: recovery!.join('\n')))),
                ])
              : Column(children: [
                  Center(child: Container(padding: const EdgeInsets.all(10), color: Colors.white, child: QrImageView(data: res['uri'], size: 170))),
                  const SizedBox(height: 10),
                  SelectableText('Or type this key: ${res['secret']}', style: TextStyle(fontSize: 12, color: c.muted)),
                  const SizedBox(height: 10),
                  TextField(controller: code, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(labelText: '6-digit code')),
                ]),
          actions: recovery != null
              ? [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done'))]
              : [
                  TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
                  FilledButton(onPressed: () async {
                    try {
                      final r = await app.totpEnable(code.text.trim());
                      set(() => recovery = r);
                    } on ApiException catch (e) {
                      app.toast(e.message);
                    }
                  }, child: const Text('Turn on')),
                ],
        ),
      ),
    );
    await app.refresh();
    if (mounted) setState(() {});
  }

  Future<void> _disable2fa() async {
    final pw = TextEditingController(), code = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => NyxDialog(
        title: 'Turn off two-factor authentication',
        child: Column(children: [
          TextField(controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
          const SizedBox(height: 8),
          TextField(controller: code, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(labelText: 'Current 6-digit code')),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Turn off'))],
      ),
    );
    if (ok == true && mounted) {
      await run(context, () => app.totpDisable(pw.text, code.text.trim()));
      await app.refresh();
      if (mounted) setState(() {});
    }
  }

  Future<void> _changePassword() async {
    final oldPw = TextEditingController(), newPw = TextEditingController(), again = TextEditingController(), totp = TextEditingController();
    String? error;
    await showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => NyxDialog(
          title: 'Change password',
          subtitle: 'Other devices will be signed out. Your encryption keys are re-protected with the new password.',
          child: Column(children: [
            TextField(controller: oldPw, obscureText: true, decoration: const InputDecoration(labelText: 'Current password')),
            const SizedBox(height: 8),
            TextField(controller: newPw, obscureText: true, decoration: const InputDecoration(labelText: 'New password')),
            const SizedBox(height: 8),
            TextField(controller: again, obscureText: true, decoration: const InputDecoration(labelText: 'New password again')),
            if (app.totpEnabled) ...[const SizedBox(height: 8), TextField(controller: totp, keyboardType: TextInputType.number, maxLength: 6, decoration: const InputDecoration(labelText: '2FA code'))],
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: c.nyx.danger))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () async {
              if (newPw.text.length < 8) return set(() => error = 'Use at least 8 characters.');
              if (newPw.text != again.text) return set(() => error = 'The new passwords do not match.');
              try {
                await app.changePassword(oldPw.text, newPw.text, totp: totp.text);
                if (c.mounted) Navigator.pop(c);
                app.toast('Password changed.');
              } on ApiException catch (e) {
                set(() => error = e.message);
              }
            }, child: const Text('Change password')),
          ],
        ),
      ),
    );
    if (mounted) setState(() => sessions = app.sessions());
  }

  @override
  Widget build(BuildContext context) {
    app.isInstanceAdmin; // keep lints quiet about unused
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Security'),
      const SectionTitle('Two-factor authentication', sub: 'A code from your phone in addition to your password.'),
      Row(children: [
        Icon(app.totpEnabled ? Icons.verified_user_rounded : Icons.gpp_maybe_rounded, color: app.totpEnabled ? context.nyx.online : context.muted),
        const SizedBox(width: 10),
        Expanded(child: Text(app.totpEnabled ? 'On. New logins need a code.' : 'Off.')),
        app.totpEnabled ? OutlinedButton(onPressed: _disable2fa, child: const Text('Turn off')) : FilledButton(onPressed: _setup2fa, child: const Text('Set up')),
      ]),
      const SectionTitle('Password'),
      OutlinedButton.icon(icon: const Icon(Icons.key_rounded, size: 18), label: const Text('Change password'), onPressed: _changePassword),
      const InfoBox(Icons.info_outline_rounded, 'Your password protects your encryption keys. If you forget it there is no reset: nobody, including the server, can recover your messages.'),
      SectionTitle('Devices', sub: 'Places you are signed in.'),
      FutureBuilder(
        future: sessions,
        builder: (c, snap) {
          if (!snap.hasData) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
          final list = snap.data!;
          return Column(children: [
            for (final s in list)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(s['current'] == true ? Icons.devices_rounded : Icons.devices_other_rounded),
                title: Text('${s['device']}'.isEmpty ? 'Unknown device' : '${s['device']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${s['ip']} · last active ${fmtTime(DateTime.parse(s['lastSeen']).toLocal())}${s['current'] == true ? ' · this device' : ''}'),
                trailing: s['current'] == true ? null : TextButton(onPressed: () async { await app.revokeSession(s['id']); setState(() => sessions = app.sessions()); }, child: const Text('Sign out')),
              ),
            if (list.length > 1) Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: () async { await app.revokeOtherSessions(); setState(() => sessions = app.sessions()); }, child: const Text('Sign out everywhere else'))),
          ]);
        },
      ),
      const SectionTitle('Recent security activity'),
      FutureBuilder(
        future: log,
        builder: (c, snap) {
          if (!snap.hasData) return const SizedBox.shrink();
          return Column(children: [for (final e in snap.data!.take(20)) ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.history_rounded, size: 18, color: c.muted), title: Text('${e['action']}${'${e['detail']}'.isEmpty ? '' : ' · ${e['detail']}'}'), subtitle: Text('${fmtTime(DateTime.parse(e['at']).toLocal())} · ${e['ip']}'))]);
        },
      ),
    ]);
  }
}

// ================================================================================ appearance

class _AppearanceTab extends StatelessWidget {
  const _AppearanceTab();

  @override
  Widget build(BuildContext context) {
    final tc = NyxTheme.controllerOf(context);
    final s = tc.settings;
    Widget slider(String label, double v, double min, double max, void Function(double) set, {int? div, String Function(double)? fmt}) => Row(children: [
          SizedBox(width: 130, child: Text(label)),
          Expanded(child: Slider(value: v.clamp(min, max), min: min, max: max, divisions: div, label: fmt?.call(v) ?? v.toStringAsFixed(1), onChanged: (x) => tc.update((_) => set(x)))),
          SizedBox(width: 44, child: Text(fmt?.call(v) ?? v.toStringAsFixed(1), textAlign: TextAlign.end, style: TextStyle(color: context.muted, fontSize: 12))),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Appearance'),
      const SectionTitle('Presets'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final p in presets)
          ActionChip(
            avatar: CircleAvatar(backgroundColor: p.settings.accent, radius: 8),
            label: Text(p.name),
            onPressed: () => tc.replace(p.settings.copy()),
          ),
      ]),
      const SectionTitle('Colours'),
      ColorField(label: 'Accent', value: s.accent, onChanged: (c) => tc.update((t) => t.accent = c!)),
      ColorField(label: 'Secondary glow', value: s.secondary, onChanged: (c) => tc.update((t) => t.secondary = c!)),
      ColorField(label: 'Background', value: s.background, onChanged: (c) => tc.update((t) => t.background = c!)),
      ColorField(label: 'Panels', value: s.surface, onChanged: (c) => tc.update((t) => t.surface = c!)),
      ColorField(label: 'Text (auto if empty)', value: s.textColor, allowNone: true, onChanged: (c) => tc.update((t) => t.textColor = c)),
      const SectionTitle('Shape & glass'),
      slider('Corner radius', s.radius, 0, 32, (x) => s.radius = x, fmt: (v) => v.round().toString()),
      slider('Glass blur', s.blur, 0, 40, (x) => s.blur = x, fmt: (v) => v.round().toString()),
      slider('Panel opacity', s.panelOpacity, 0, 1, (x) => s.panelOpacity = x, fmt: (v) => '${(v * 100).round()}%'),
      slider('Text size', s.fontScale, .8, 1.5, (x) => s.fontScale = x, fmt: (v) => '${(v * 100).round()}%'),
      const SectionTitle('Background'),
      SegmentedButton<BackgroundKind>(
        segments: const [ButtonSegment(value: BackgroundKind.aurora, label: Text('Aurora')), ButtonSegment(value: BackgroundKind.solid, label: Text('Solid')), ButtonSegment(value: BackgroundKind.gradient, label: Text('Gradient')), ButtonSegment(value: BackgroundKind.image, label: Text('Image'))],
        selected: {s.backgroundKind},
        onSelectionChanged: (v) => tc.update((t) => t.backgroundKind = v.first),
      ),
      if (s.backgroundKind == BackgroundKind.gradient) ...[
        ColorField(label: 'Gradient start', value: s.gradient.first, onChanged: (c) => tc.update((t) => t.gradient = [c!, t.gradient.last])),
        ColorField(label: 'Gradient end', value: s.gradient.last, onChanged: (c) => tc.update((t) => t.gradient = [t.gradient.first, c!])),
      ],
      if (s.backgroundKind == BackgroundKind.image) ...[
        ImageUploadField(
          label: 'Background picture',
          hint: 'Stays on this device. GIF and animated WebP loop.',
          maxBytes: 25 * 1024 * 1024,
          preview: (c) => ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: 100, height: 56, child: s.backgroundImage == null ? Container(color: c.faint.withValues(alpha: .2)) : Image.memory(s.assets[s.backgroundImage]!, fit: BoxFit.cover))),
          onPicked: (f, _) async => tc.setLocalBackground(f.name, await FileCrypto.collect(f.open())),
        ),
        slider('Picture opacity', s.backgroundOpacity, 0, 1, (x) => s.backgroundOpacity = x, fmt: (v) => '${(v * 100).round()}%'),
        slider('Picture blur', s.backgroundBlur, 0, 30, (x) => s.backgroundBlur = x, fmt: (v) => v.round().toString()),
      ],
      const SectionTitle('Chat'),
      SegmentedButton<MessageStyle>(segments: const [ButtonSegment(value: MessageStyle.flat, label: Text('Flat')), ButtonSegment(value: MessageStyle.bubbles, label: Text('Bubbles'))], selected: {s.messageStyle}, onSelectionChanged: (v) => tc.update((t) => t.messageStyle = v.first)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Animated background'), value: s.animatedBackground, onChanged: (v) => tc.update((t) => t.animatedBackground = v)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Glow around whoever is speaking'), value: s.speakingGlow, onChanged: (v) => tc.update((t) => t.speakingGlow = v)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Hover animations'), value: s.hoverAnimations, onChanged: (v) => tc.update((t) => t.hoverAnimations = v)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Reduce motion'), subtitle: const Text('Turns off most animations'), value: s.reduceMotion, onChanged: (v) => tc.update((t) => t.reduceMotion = v)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Compact layout'), value: s.compact, onChanged: (v) => tc.update((t) => t.compact = v)),
    ]);
  }
}

// ==================================================================================== voice

class _VoiceTab extends StatelessWidget {
  const _VoiceTab();

  @override
  Widget build(BuildContext context) {
    final v = context.app.voice;
    return ListenableBuilder(
      listenable: v,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const PageTitle('Voice & video'),
        const SectionTitle('Devices'),
        const DevicePanel(),
        const SectionTitle('Screen sharing quality'),
        Wrap(spacing: 8, children: [for (final q in ShareQuality.values) ChoiceChip(label: Text(q.label), selected: v.quality == q, onSelected: (_) => v.setQuality(q))]),
        const InfoBox(Icons.lock_rounded, 'Calls are peer-to-peer and encrypted. If two people cannot connect directly, media goes through your own relay server, still encrypted end to end.'),
      ]),
    );
  }
}

// ==================================================================================== admin

class _InstanceTab extends StatefulWidget {
  const _InstanceTab();

  @override
  State<_InstanceTab> createState() => _InstanceTabState();
}

class _InstanceTabState extends State<_InstanceTab> {
  String? code;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const PageTitle('This instance'),
        Text('You are the administrator of ${context.appRead.server}.', style: TextStyle(color: context.muted)),
        const SectionTitle('Invite a new person', sub: 'They use this code on the sign-up screen to create an account. It works once and expires in two days.'),
        FilledButton.icon(icon: const Icon(Icons.person_add_alt_1_rounded, size: 18), label: const Text('Create invite code'), onPressed: () => run(context, () async {
              final c = await context.appRead.createInstanceInvite();
              setState(() => code = c);
            })),
        if (code != null) ...[
          const SizedBox(height: 14),
          Row(children: [SelectableText(code!, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 3)), const SizedBox(width: 12), IconButton(icon: const Icon(Icons.copy_rounded), onPressed: () => Clipboard.setData(ClipboardData(text: code!)))]),
        ],
      ]);
}

class _AboutTab extends StatelessWidget {
  const _AboutTab();

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('About'),
      const SectionTitle('Nyx'),
      const Text('Private, end-to-end encrypted chat for a few people.'),
      const SizedBox(height: 12),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.dns_rounded), title: const Text('Server'), subtitle: Text(app.server)),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.badge_rounded), title: const Text('Signed in as'), subtitle: Text('${app.me!.name} (@${app.me!.username})')),
      const SectionTitle('Your identity key', sub: 'Other people can compare this with what they see for you (Profile → Verify).'),
      SelectableText(app.identity!.publicKeys, style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: context.muted)),
    ]);
  }
}

class _LogoutTab extends StatelessWidget {
  const _LogoutTab();

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const PageTitle('Log out'),
        const Text('You will be signed out on this device only. Your messages stay on the server, encrypted.'),
        const SizedBox(height: 16),
        FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: context.nyx.danger), icon: const Icon(Icons.logout_rounded, size: 18), label: const Text('Log out'), onPressed: () { Navigator.pop(context); context.appRead.signOut(); }),
      ]);
}
