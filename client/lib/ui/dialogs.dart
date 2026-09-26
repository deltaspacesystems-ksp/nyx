import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/crypto.dart';
import '../core/models.dart';
import 'common.dart';
import 'members_panel.dart';
import 'markdown.dart';
import 'settings_guild.dart';
import 'settings_user.dart';

/// Consistent modal frame used by nearly every dialog.
class NyxDialog extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;
  final double maxWidth;
  const NyxDialog({super.key, required this.title, this.subtitle, required this.child, this.actions = const [], this.maxWidth = 440});

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Pop(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: MediaQuery.sizeOf(context).height * .88),
            child: Glass(
              opacity: dialogOpacity(context),
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(subtitle!, style: TextStyle(color: context.muted))),
                const SizedBox(height: 14),
                Flexible(child: SingleChildScrollView(child: child)),
                if (actions.isNotEmpty) ...[const SizedBox(height: 16), SizedBox(width: double.infinity, child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 6, children: actions))],
              ]),
            ),
          ),
        ),
      );
}

Future<bool> confirmDialog(BuildContext context, String title, String body, {bool danger = false, String confirm = 'Confirm'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => NyxDialog(
      title: title,
      child: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(style: danger ? FilledButton.styleFrom(backgroundColor: c.nyx.danger) : null, onPressed: () => Navigator.pop(c, true), child: Text(danger ? 'Delete' : confirm)),
      ],
    ),
  );
  return r == true;
}

Future<String?> promptDialog(BuildContext context, String title, {String label = '', String initial = '', String action = 'Save', int maxLength = 100, bool multiline = false}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (d) => NyxDialog(
      title: title,
      child: TextField(controller: c, autofocus: true, maxLength: maxLength, maxLines: multiline ? 4 : 1, decoration: InputDecoration(labelText: label), onSubmitted: multiline ? null : (v) => Navigator.pop(d, v)),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, c.text), child: Text(action))],
    ),
  );
}

Future<void> run(BuildContext context, Future<void> Function() action) async {
  final app = context.appRead;
  try {
    await action();
  } on ApiException catch (e) {
    app.toast(e.message);
  } catch (e) {
    app.toast('$e');
  }
}

// ================================================================================ servers

Future<void> showAddServer(BuildContext context) => showDialog(
      context: context,
      builder: (c) => NyxDialog(
        title: 'Add a server',
        subtitle: 'Servers are where you and your people hang out.',
        child: Column(children: [
          _BigOption(icon: Icons.add_home_work_rounded, title: 'Create my own', subtitle: 'Start a fresh, private, encrypted server', onTap: () { Navigator.pop(c); showCreateGuild(context); }),
          const SizedBox(height: 10),
          _BigOption(icon: Icons.login_rounded, title: 'Join with an invite code', subtitle: 'Someone already has a server for you', onTap: () { Navigator.pop(c); showJoinGuild(context); }),
        ]),
      ),
    );

class _BigOption extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  const _BigOption({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(context.nyx.radius),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: context.cs.onSurface.withValues(alpha: .06), borderRadius: BorderRadius.circular(context.nyx.radius), border: Border.all(color: Theme.of(context).dividerColor)),
          child: Row(children: [
            Icon(icon, size: 32, color: context.cs.primary),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)), Text(subtitle, style: TextStyle(color: context.muted, fontSize: 12.5))])),
            const Icon(Icons.chevron_right_rounded),
          ]),
        ),
      );
}

Future<void> showCreateGuild(BuildContext context) {
  final name = TextEditingController(text: '${context.appRead.me?.name ?? 'My'}\'s server');
  return showDialog(
    context: context,
    builder: (c) => NyxDialog(
      title: 'Create your server',
      subtitle: 'You can add an icon, banner and roles afterwards.',
      child: TextField(controller: name, autofocus: true, maxLength: 60, decoration: const InputDecoration(labelText: 'Server name')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () { Navigator.pop(c); run(context, () => context.appRead.createGuild(name.text.trim().isEmpty ? 'My server' : name.text.trim())); }, child: const Text('Create')),
      ],
    ),
  );
}

Future<void> showJoinGuild(BuildContext context) {
  final code = TextEditingController();
  return showDialog(
    context: context,
    builder: (c) => NyxDialog(
      title: 'Join a server',
      subtitle: 'Enter the invite code you were sent.',
      child: TextField(controller: code, autofocus: true, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Invite code')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () { Navigator.pop(c); run(context, () => context.appRead.joinWithInvite(code.text)); }, child: const Text('Join')),
      ],
    ),
  );
}

Future<void> showInvite(BuildContext context, GuildModel g) async {
  final app = context.appRead;
  var maxUses = 0, hours = 168;
  String? code;
  await showDialog(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => NyxDialog(
        title: 'Invite people to ${g.name}',
        subtitle: 'They join with the code below. Keys are handed over automatically when a member is online.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (code == null) ...[
            DropdownButtonFormField<int>(initialValue: hours, decoration: const InputDecoration(labelText: 'Expires after'), items: const [DropdownMenuItem(value: 1, child: Text('1 hour')), DropdownMenuItem(value: 24, child: Text('1 day')), DropdownMenuItem(value: 168, child: Text('7 days')), DropdownMenuItem(value: 720, child: Text('30 days'))], onChanged: (v) => set(() => hours = v!)),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(initialValue: maxUses, decoration: const InputDecoration(labelText: 'Max uses'), items: const [DropdownMenuItem(value: 0, child: Text('Unlimited')), DropdownMenuItem(value: 1, child: Text('1 use')), DropdownMenuItem(value: 5, child: Text('5 uses')), DropdownMenuItem(value: 25, child: Text('25 uses'))], onChanged: (v) => set(() => maxUses = v!)),
          ] else ...[
            Center(child: SelectableText(code!, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 3))),
            const SizedBox(height: 10),
            Center(child: OutlinedButton.icon(icon: const Icon(Icons.copy_rounded, size: 18), label: const Text('Copy code'), onPressed: () { Clipboard.setData(ClipboardData(text: code!)); app.toast('Copied'); })),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
          if (code == null)
            FilledButton(onPressed: () async {
              try {
                final r = await app.createInvite(g.id, maxUses: maxUses, hours: hours);
                set(() => code = r['code']);
              } catch (e) {
                app.toast('$e');
              }
            }, child: const Text('Create invite')),
        ],
      ),
    ),
  );
}

Future<void> showCreateChannel(BuildContext context, GuildModel g, {ChannelModel? parent, int kind = ChannelKind.text}) {
  final name = TextEditingController();
  var k = kind, restricted = false;
  final members = <String>{};
  final app = context.appRead;
  return showDialog(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => NyxDialog(
        title: 'Create ${k == ChannelKind.category ? 'category' : 'channel'}',
        subtitle: parent == null ? null : 'in ${parent.name}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<int>(
            segments: const [ButtonSegment(value: ChannelKind.text, label: Text('Text'), icon: Icon(Icons.tag_rounded)), ButtonSegment(value: ChannelKind.voice, label: Text('Voice'), icon: Icon(Icons.volume_up_rounded)), ButtonSegment(value: ChannelKind.category, label: Text('Category'), icon: Icon(Icons.folder_rounded))],
            selected: {k},
            onSelectionChanged: (s) => set(() => k = s.first),
          ),
          const SizedBox(height: 14),
          TextField(controller: name, autofocus: true, maxLength: 60, decoration: const InputDecoration(labelText: 'Name')),
          if (k != ChannelKind.category) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Private channel'), subtitle: const Text('Only selected members can see it'), value: restricted, onChanged: (v) => set(() => restricted = v)),
          if (restricted && k != ChannelKind.category)
            for (final id in g.members.keys.where((m) => m != app.myId))
              CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero, secondary: UserAvatar(app.users[id], size: 28), title: Text(app.displayNameIn(id, g.id)), value: members.contains(id), onChanged: (v) => set(() => v! ? members.add(id) : members.remove(id))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            final n = name.text.trim();
            if (n.isEmpty) return;
            Navigator.pop(c);
            run(context, () async {
              final id = await app.createChannel(g.id, k == ChannelKind.category ? n : n.toLowerCase().replaceAll(RegExp(r'\s+'), '-'), k, parentId: parent?.id, restricted: restricted, members: members.toList());
              if (k != ChannelKind.category) await app.openChannel(id);
            });
          }, child: const Text('Create')),
        ],
      ),
    ),
  );
}

Future<void> showGuildMenu(BuildContext context, GuildModel g, Offset pos) async {
  final app = context.appRead;
  final me = app.myId;
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
    items: [
      if (g.can(me, Perm.createInvite)) const PopupMenuItem(value: 'invite', child: ListTile(dense: true, leading: Icon(Icons.person_add_alt_1_rounded), title: Text('Invite people'))),
      if (g.can(me, Perm.manageGuild)) const PopupMenuItem(value: 'settings', child: ListTile(dense: true, leading: Icon(Icons.settings_rounded), title: Text('Server settings'))),
      if (g.can(me, Perm.manageChannels)) const PopupMenuItem(value: 'channel', child: ListTile(dense: true, leading: Icon(Icons.add_circle_outline_rounded), title: Text('Create channel'))),
      if (g.can(me, Perm.manageChannels)) const PopupMenuItem(value: 'category', child: ListTile(dense: true, leading: Icon(Icons.create_new_folder_outlined), title: Text('Create category'))),
      PopupMenuItem(value: 'read', child: const ListTile(dense: true, leading: Icon(Icons.mark_chat_read_rounded), title: Text('Mark all as read'))),
      if (g.ownerId != me) PopupMenuItem(value: 'leave', child: ListTile(dense: true, leading: Icon(Icons.logout_rounded, color: context.nyx.danger), title: Text('Leave server', style: TextStyle(color: context.nyx.danger)))),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'invite':
      showInvite(context, g);
    case 'settings':
      showGuildSettings(context, g.id);
    case 'channel':
      showCreateChannel(context, g);
    case 'category':
      showCreateChannel(context, g, kind: ChannelKind.category);
    case 'read':
      for (final ch in g.channels.values.where((c) => c.isText)) {
        app.markRead(ch.id);
      }
    case 'leave':
      if (await confirmDialog(context, 'Leave ${g.name}?', 'You will need a new invite to come back.', confirm: 'Leave')) {
        if (context.mounted) run(context, () => app.leaveGuild(g.id));
      }
  }
}

Future<void> showChannelMenu(BuildContext context, ChannelModel ch, Offset pos) async {
  final app = context.appRead;
  final g = ch.guildId == null ? null : app.guilds[ch.guildId];
  final can = g?.can(app.myId, Perm.manageChannels) ?? false;
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
    items: [
      if (ch.isText) const PopupMenuItem(value: 'read', child: ListTile(dense: true, leading: Icon(Icons.mark_chat_read_rounded), title: Text('Mark as read'))),
      if (can) const PopupMenuItem(value: 'edit', child: ListTile(dense: true, leading: Icon(Icons.edit_rounded), title: Text('Edit channel'))),
      if (can) PopupMenuItem(value: 'delete', child: ListTile(dense: true, leading: Icon(Icons.delete_rounded, color: context.nyx.danger), title: Text('Delete channel', style: TextStyle(color: context.nyx.danger)))),
    ],
  );
  if (!context.mounted || choice == null) return;
  switch (choice) {
    case 'read':
      app.markRead(ch.id);
    case 'edit':
      showEditChannel(context, ch);
    case 'delete':
      if (await confirmDialog(context, 'Delete ${ch.isCategory ? 'category' : '#${ch.name}'}?', 'All messages and files in it are removed for everyone. This cannot be undone.', danger: true)) {
        if (context.mounted) run(context, () => app.deleteChannel(ch.id));
      }
  }
}

Future<void> showEditChannel(BuildContext context, ChannelModel ch) {
  final name = TextEditingController(text: ch.name), topic = TextEditingController(text: ch.topic);
  var slow = ch.slowmode;
  return showDialog(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => NyxDialog(
        title: 'Edit ${ch.isCategory ? 'category' : 'channel'}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: name, maxLength: 60, decoration: const InputDecoration(labelText: 'Name')),
          if (ch.isText) ...[
            const SizedBox(height: 6),
            TextField(controller: topic, maxLength: 200, decoration: const InputDecoration(labelText: 'Topic')),
            const SizedBox(height: 6),
            DropdownButtonFormField<int>(initialValue: [0, 5, 10, 30, 60, 300, 900, 3600].contains(slow) ? slow : 0, decoration: const InputDecoration(labelText: 'Slowmode'), items: const [DropdownMenuItem(value: 0, child: Text('Off')), DropdownMenuItem(value: 5, child: Text('5 seconds')), DropdownMenuItem(value: 10, child: Text('10 seconds')), DropdownMenuItem(value: 30, child: Text('30 seconds')), DropdownMenuItem(value: 60, child: Text('1 minute')), DropdownMenuItem(value: 300, child: Text('5 minutes')), DropdownMenuItem(value: 900, child: Text('15 minutes')), DropdownMenuItem(value: 3600, child: Text('1 hour'))], onChanged: (v) => set(() => slow = v!)),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () { Navigator.pop(c); run(context, () => context.appRead.updateChannel(ch, name: name.text.trim(), topic: topic.text.trim(), slowmode: ch.isText ? slow : null)); }, child: const Text('Save')),
        ],
      ),
    ),
  );
}

Future<void> showPresenceMenu(BuildContext context, Offset pos) async {
  final app = context.appRead;
  PopupMenuItem<String> item(String value, String label, Color color) => PopupMenuItem<String>(value: value, child: Row(children: [Icon(Icons.circle, size: 12, color: color), const SizedBox(width: 12), Text(label)]));
  final v = await showMenu<String>(
    context: context,
    // Anchored above the click point (the user panel sits at the bottom of the window).
    position: RelativeRect.fromLTRB(pos.dx, pos.dy - 230, pos.dx + 1, pos.dy - 230),
    constraints: const BoxConstraints(minWidth: 190),
    items: [
      item('online', 'Online', context.nyx.online),
      item('idle', 'Idle', const Color(0xFFF5A623)),
      item('dnd', 'Do not disturb', context.nyx.danger),
      item('invisible', 'Invisible', const Color(0xFF80848E)),
      const PopupMenuDivider(),
      PopupMenuItem<String>(value: '_activity', child: Row(children: [Icon(Icons.sports_esports_rounded, size: 16, color: context.muted), const SizedBox(width: 12), Text(app.manualActivity == null ? 'Set activity…' : 'Activity: ${app.manualActivity!['name']}')])),
    ],
  );
  if (v == '_activity') {
    if (context.mounted) await showActivityDialog(context);
  } else if (v != null) {
    await app.setPresence(v);
  }
}

Future<void> showActivityDialog(BuildContext context) async {
  final app = context.appRead;
  final name = TextEditingController(text: (app.manualActivity?['name'] as String?) ?? '');
  final details = TextEditingController(text: (app.manualActivity?['details'] as String?) ?? '');
  await showDialog(
    context: context,
    builder: (c) => NyxDialog(
      title: 'Activity',
      subtitle: 'Shown next to your name for everyone in your servers. Games that support Discord Rich Presence fill this in by themselves.',
      actions: [
        if (app.manualActivity != null) TextButton(onPressed: () { app.setManualActivity(null); Navigator.pop(c); }, child: const Text('Clear')),
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () { app.setManualActivity(name.text, details: details.text); Navigator.pop(c); }, child: const Text('Save')),
      ],
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, autofocus: true, maxLength: 64, decoration: const InputDecoration(labelText: 'Playing / doing')),
        TextField(controller: details, maxLength: 128, decoration: const InputDecoration(labelText: 'Details (optional)')),
      ]),
    ),
  );
}

// ============================================================================ conversations

Future<void> showNewDm(BuildContext context) {
  final app = context.appRead;
  final picked = <String>{};
  final name = TextEditingController();
  var q = '';
  return showDialog(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        final people = app.users.values.where((u) => u.id != app.myId && (q.isEmpty || u.name.toLowerCase().contains(q) || u.username.contains(q))).toList();
        return NyxDialog(
          title: 'New message',
          subtitle: picked.length > 1 ? 'A group conversation with ${picked.length} people' : 'Choose one person, or several for a group',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(onChanged: (v) => set(() => q = v.toLowerCase()), decoration: const InputDecoration(hintText: 'Search people', prefixIcon: Icon(Icons.search))),
            const SizedBox(height: 8),
            if (people.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('Nobody else is on this server yet.\nInvite someone from Settings.', textAlign: TextAlign.center, style: TextStyle(color: context.muted))),
            for (final u in people) CheckboxListTile(contentPadding: EdgeInsets.zero, secondary: UserAvatar(u, size: 36, presence: true), title: Text(u.name), subtitle: Text('@${u.username}'), value: picked.contains(u.id), onChanged: (v) => set(() => v! ? picked.add(u.id) : picked.remove(u.id))),
            if (picked.length > 1) TextField(controller: name, maxLength: 50, decoration: const InputDecoration(labelText: 'Group name (optional)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              onPressed: picked.isEmpty ? null : () {
                Navigator.pop(c);
                run(context, () async {
                  if (picked.length == 1) {
                    await app.openDm(picked.first);
                  } else {
                    await app.createConversation(picked.toList(), groupName: name.text.trim());
                  }
                });
              },
              child: Text(picked.length > 1 ? 'Create group' : 'Open'),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> showAddToGroup(BuildContext context, ChannelModel ch) {
  final app = context.appRead;
  final picked = <String>{};
  return showDialog(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        final people = app.users.values.where((u) => !ch.members.contains(u.id)).toList();
        return NyxDialog(
          title: 'Add people',
          subtitle: 'New members cannot read what was said before they joined (the key changes).',
          child: Column(children: [
            if (people.isEmpty) Text('Everyone is already here.', style: TextStyle(color: context.muted)),
            for (final u in people) CheckboxListTile(contentPadding: EdgeInsets.zero, secondary: UserAvatar(u, size: 34), title: Text(u.name), value: picked.contains(u.id), onChanged: (v) => set(() => v! ? picked.add(u.id) : picked.remove(u.id))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: picked.isEmpty ? null : () { Navigator.pop(c); run(context, () => app.addToGroup(ch.id, picked.toList())); }, child: const Text('Add')),
          ],
        );
      },
    ),
  );
}

// ================================================================================ messages

Future<void> showPins(BuildContext context, ChannelModel ch) => showDialog(
      context: context,
      builder: (c) => NyxDialog(
        title: 'Pinned messages',
        maxWidth: 520,
        child: FutureBuilder(
          future: c.appRead.pinned(ch.id),
          builder: (c, snap) {
            if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
            final list = snap.data ?? [];
            if (list.isEmpty) return Padding(padding: const EdgeInsets.all(20), child: Text('Nothing pinned yet. Right-click a message to pin it.', style: TextStyle(color: c.muted)));
            return Column(children: [
              for (final m in list)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: c.cs.onSurface.withValues(alpha: .06), borderRadius: BorderRadius.circular(12)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [UserAvatar(c.appRead.users[m.senderId], size: 22), const SizedBox(width: 8), Text(c.appRead.displayNameIn(m.senderId), style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(width: 8), Text(fmtTime(m.createdAt), style: TextStyle(fontSize: 11, color: c.faint))]),
                    const SizedBox(height: 6),
                    m.content == null ? Text('Could not decrypt', style: TextStyle(color: c.nyx.danger)) : RichText2(m.text, guild: c.appRead.guildOfChannel(ch.id)),
                  ]),
                ),
            ]);
          },
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );

Future<void> showChannelSearch(BuildContext context, ChannelModel ch) {
  final app = context.appRead;
  final q = TextEditingController();
  var query = '';
  var loading = false;
  return showDialog(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        final results = query.length < 2
            ? <MessageModel>[]
            : (app.messages[ch.id] ?? []).where((m) => !m.deleted && (m.text.toLowerCase().contains(query) || m.files.any((f) => f.name.toLowerCase().contains(query)))).toList().reversed.toList();
        return NyxDialog(
          title: 'Search ${ch.isDm ? 'this conversation' : '#${ch.name}'}',
          subtitle: 'Everything is encrypted, so searching happens on this device, over the messages you have loaded.',
          maxWidth: 560,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: q, autofocus: true, onChanged: (v) => set(() => query = v.toLowerCase().trim()), decoration: const InputDecoration(hintText: 'Search', prefixIcon: Icon(Icons.search))),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text('${results.length} result${results.length == 1 ? '' : 's'} in ${(app.messages[ch.id] ?? []).length} loaded messages', style: TextStyle(fontSize: 12, color: c.muted))),
              TextButton(
                onPressed: loading ? null : () async {
                  set(() => loading = true);
                  for (var i = 0; i < 10; i++) {
                    if (!await app.loadOlder(ch.id)) break;
                  }
                  set(() => loading = false);
                },
                child: Text(loading ? 'Loading…' : 'Load older messages'),
              ),
            ]),
            for (final m in results.take(40))
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: c.cs.onSurface.withValues(alpha: .06), borderRadius: BorderRadius.circular(10)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${app.displayNameIn(m.senderId)} · ${fmtTime(m.createdAt)}', style: TextStyle(fontSize: 11.5, color: c.muted)),
                  const SizedBox(height: 2),
                  Text(m.text.isEmpty ? '(attachment)' : m.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                ]),
              ),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        );
      },
    ),
  );
}

// ================================================================================== people

Future<void> showProfile(BuildContext context, String userId) {
  final app = context.appRead;
  final u = app.users[userId];
  if (u == null) return Future.value();
  final mine = userId == app.myId;
  return showDialog(
    context: context,
    builder: (c) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Pop(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Glass(
            opacity: dialogOpacity(context),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ProfileCard(userId: userId, guildId: app.guildId),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    if (mine) FilledButton.icon(icon: const Icon(Icons.edit_rounded, size: 18), label: const Text('Edit profile'), onPressed: () { Navigator.pop(c); showUserSettings(context, tab: 0); })
                    else ...[
                      FilledButton.icon(icon: const Icon(Icons.chat_bubble_rounded, size: 18), label: const Text('Message'), onPressed: () { Navigator.pop(c); run(context, () async { await app.openDm(userId); }); }),
                      if (app.friends.contains(userId))
                        OutlinedButton.icon(icon: const Icon(Icons.person_remove_rounded, size: 18), label: const Text('Remove friend'), onPressed: () { Navigator.pop(c); run(context, () => app.removeFriend(userId)); })
                      else if (app.incomingFriends.contains(userId))
                        OutlinedButton.icon(icon: const Icon(Icons.person_add_alt_1_rounded, size: 18), label: const Text('Accept request'), onPressed: () { Navigator.pop(c); run(context, () => app.acceptFriend(userId)); })
                      else if (app.outgoingFriends.contains(userId))
                        OutlinedButton.icon(icon: const Icon(Icons.close_rounded, size: 18), label: const Text('Cancel request'), onPressed: () { Navigator.pop(c); run(context, () => app.removeFriend(userId)); })
                      else if (!app.blockedUsers.contains(userId))
                        OutlinedButton.icon(icon: const Icon(Icons.person_add_alt_1_rounded, size: 18), label: const Text('Add friend'), onPressed: () { Navigator.pop(c); run(context, () async { await app.addFriend(u.username); app.toast('Friend request sent.'); }); }),
                      OutlinedButton.icon(icon: const Icon(Icons.verified_user_rounded, size: 18), label: const Text('Verify'), onPressed: () => showVerify(context, userId)),
                      if (app.blockedUsers.contains(userId))
                        OutlinedButton.icon(icon: const Icon(Icons.lock_open_rounded, size: 18), label: const Text('Unblock'), onPressed: () { Navigator.pop(c); run(context, () => app.unblockUser(userId)); })
                      else
                        OutlinedButton.icon(icon: Icon(Icons.block_rounded, size: 18, color: context.nyx.danger), label: Text('Block', style: TextStyle(color: context.nyx.danger)), onPressed: () { Navigator.pop(c); run(context, () => app.blockUser(userId)); }),
                    ],
                    if (!mine && app.guild != null) OutlinedButton.icon(icon: const Icon(Icons.shield_rounded, size: 18), label: const Text('Moderate'), onPressed: () { Navigator.pop(c); showMemberMenu(context, userId, const Offset(200, 200)); }),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> showVerify(BuildContext context, String userId) async {
  final app = context.appRead;
  final u = app.users[userId]!;
  final number = await NyxCrypto.safetyNumberFromKeys(app.identity!.publicKeys, '${u.edPublic}:${u.xPublic}');
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (c) => NyxDialog(
      title: 'Verify ${u.name}',
      subtitle: 'Compare this number with ${u.name} in person or over a call you trust. If it matches on both sides, nobody is in the middle.',
      child: Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SelectableText(number, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 2, height: 1.5)))),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
    ),
  );
}

Future<void> showMemberMenu(BuildContext context, String userId, Offset pos) async {
  final app = context.appRead;
  final g = app.guild;
  final me = app.myId;
  if (g == null || userId == me) {
    showProfile(context, userId);
    return;
  }
  final rank = g.rankOf(me), theirs = g.rankOf(userId);
  final above = userId == g.ownerId || theirs >= rank;
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
    items: [
      const PopupMenuItem(value: 'profile', child: ListTile(dense: true, leading: Icon(Icons.person_rounded), title: Text('Profile'))),
      const PopupMenuItem(value: 'dm', child: ListTile(dense: true, leading: Icon(Icons.chat_bubble_rounded), title: Text('Message'))),
      if (g.can(me, Perm.manageRoles) && !above) const PopupMenuItem(value: 'roles', child: ListTile(dense: true, leading: Icon(Icons.badge_rounded), title: Text('Roles'))),
      if (g.can(me, Perm.kickMembers) && !above) const PopupMenuItem(value: 'timeout', child: ListTile(dense: true, leading: Icon(Icons.timer_rounded), title: Text('Time out'))),
      if (g.can(me, Perm.kickMembers) && !above) PopupMenuItem(value: 'kick', child: ListTile(dense: true, leading: Icon(Icons.exit_to_app_rounded, color: context.nyx.danger), title: Text('Kick', style: TextStyle(color: context.nyx.danger)))),
      if (g.can(me, Perm.banMembers) && !above) PopupMenuItem(value: 'ban', child: ListTile(dense: true, leading: Icon(Icons.gavel_rounded, color: context.nyx.danger), title: Text('Ban', style: TextStyle(color: context.nyx.danger)))),
    ],
  );
  if (!context.mounted || choice == null) return;
  final name = app.displayNameIn(userId, g.id);
  switch (choice) {
    case 'profile':
      showProfile(context, userId);
    case 'dm':
      run(context, () async { await app.openDm(userId); });
    case 'roles':
      showMemberRoles(context, g, userId);
    case 'timeout':
      final d = await showMenu<Duration?>(context: context, position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy), items: [
        const PopupMenuItem(value: Duration(minutes: 1), child: Text('1 minute')),
        const PopupMenuItem(value: Duration(minutes: 10), child: Text('10 minutes')),
        const PopupMenuItem(value: Duration(hours: 1), child: Text('1 hour')),
        const PopupMenuItem(value: Duration(days: 1), child: Text('1 day')),
        const PopupMenuItem(value: Duration(days: 7), child: Text('1 week')),
        const PopupMenuItem(value: Duration.zero, child: Text('Remove time out')),
      ]);
      if (d != null && context.mounted) run(context, () => app.timeout(g.id, userId, d == Duration.zero ? null : d));
    case 'kick':
      if (await confirmDialog(context, 'Kick $name?', '$name is removed from ${g.name} and the encryption keys are changed. They can rejoin with a new invite.', confirm: 'Kick') && context.mounted) run(context, () => app.kick(g.id, userId));
    case 'ban':
      if (await confirmDialog(context, 'Ban $name?', '$name is removed and cannot rejoin until you unban them.', confirm: 'Ban') && context.mounted) run(context, () => app.ban(g.id, userId));
  }
}

Future<void> showMemberRoles(BuildContext context, GuildModel g, String userId) {
  final app = context.appRead;
  final selected = {...?g.members[userId]?.roleIds};
  final mine = g.rankOf(app.myId);
  final roles = g.roles.values.where((r) => !r.isEveryone).toList()..sort((a, b) => b.position.compareTo(a.position));
  return showDialog(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => NyxDialog(
        title: 'Roles for ${app.displayNameIn(userId, g.id)}',
        child: Column(children: [
          if (roles.isEmpty) Text('This server has no roles yet. Create some in Server settings.', style: TextStyle(color: c.muted)),
          for (final r in roles)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              secondary: Container(width: 14, height: 14, decoration: BoxDecoration(color: r.color != 0 ? Color(r.color) : c.faint, shape: BoxShape.circle)),
              title: Text(r.name),
              subtitle: r.position >= mine ? const Text('Above your highest role') : null,
              value: selected.contains(r.id),
              onChanged: r.position >= mine ? null : (v) => set(() => v! ? selected.add(r.id) : selected.remove(r.id)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () { Navigator.pop(c); run(context, () => app.setMemberRoles(g.id, userId, selected.toList())); }, child: const Text('Save')),
        ],
      ),
    ),
  );
}

Future<void> showMembersSheet(BuildContext context) => showModalBottomSheet(context: context, showDragHandle: true, isScrollControlled: true, builder: (c) => SizedBox(height: MediaQuery.sizeOf(c).height * .7, child: const MembersPanel()));
