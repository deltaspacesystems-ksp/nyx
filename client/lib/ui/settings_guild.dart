import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/files.dart';
import '../core/models.dart';
import 'common.dart';
import 'dialogs.dart';
import 'settings_common.dart';

Future<void> showGuildSettings(BuildContext context, String guildId, {int tab = 0}) => showDialog(
      context: context,
      builder: (c) {
        final app = c.appRead;
        final g = app.guilds[guildId];
        if (g == null) return const SizedBox.shrink();
        final me = app.myId;
        return SettingsFrame(
          title: g.name,
          initial: tab,
          tabs: [
            SettingsTab(Icons.tune_rounded, 'Overview', (_) => _Overview(guildId: guildId)),
            if (g.can(me, Perm.manageRoles)) SettingsTab(Icons.badge_rounded, 'Roles', (_) => _Roles(guildId: guildId)),
            if (g.can(me, Perm.manageChannels)) SettingsTab(Icons.tag_rounded, 'Channels', (_) => _Channels(guildId: guildId)),
            if (g.can(me, Perm.manageEmojis)) SettingsTab(Icons.emoji_emotions_rounded, 'Emoji', (_) => _Emoji(guildId: guildId)),
            if (g.can(me, Perm.manageEmojis)) SettingsTab(Icons.sticky_note_2_rounded, 'Stickers', (_) => _Emoji(guildId: guildId, sticker: true)),
            SettingsTab(Icons.people_rounded, 'Members', (_) => _Members(guildId: guildId)),
            if (g.can(me, Perm.createInvite)) SettingsTab(Icons.link_rounded, 'Invites', (_) => _Invites(guildId: guildId)),
            if (g.can(me, Perm.banMembers)) SettingsTab(Icons.gavel_rounded, 'Bans', (_) => _Bans(guildId: guildId)),
            if (g.can(me, Perm.manageGuild)) SettingsTab(Icons.history_rounded, 'Audit log', (_) => _Audit(guildId: guildId)),
            if (g.ownerId == me) SettingsTab(Icons.delete_forever_rounded, 'Delete server', (_) => _Danger(guildId: guildId), danger: true),
          ],
        );
      },
    );

GuildModel? _g(BuildContext c, String id) => c.app.guilds[id];

// =================================================================================== overview

class _Overview extends StatefulWidget {
  final String guildId;
  const _Overview({required this.guildId});

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  late final app = context.appRead;
  late final GuildModel g = app.guilds[widget.guildId]!;
  late final name = TextEditingController(text: g.name);
  late final desc = TextEditingController(text: g.description);
  bool saving = false;

  @override
  Widget build(BuildContext context) {
    final g = _g(context, widget.guildId);
    if (g == null) return const SizedBox.shrink();
    final can = g.can(app.myId, Perm.manageGuild);
    final accent = g.accent != null ? Color(g.accent!) : context.cs.primary;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Server overview'),
      if (!can) const InfoBox(Icons.lock_rounded, 'You need the “Manage server” permission to change these.'),
      const SizedBox(height: 8),
      TextField(controller: name, enabled: can, maxLength: 60, decoration: const InputDecoration(labelText: 'Server name')),
      const SizedBox(height: 8),
      TextField(controller: desc, enabled: can, maxLength: 300, maxLines: 3, decoration: const InputDecoration(labelText: 'Description')),
      if (can) ...[
        ColorField(label: 'Server colour', value: g.accent == null ? null : Color(g.accent!), allowNone: true, onChanged: (c) => run(context, () => app.updateGuild(g.id, accent: c?.toARGB32()))),
        ImageUploadField(
          aspect: 1,
          current: g.icon,
          label: 'Icon',
          hint: 'Square picture, up to 12 MB. Animated GIF / WebP icons animate on hover.',
          preview: (c) => ClipRRect(borderRadius: BorderRadius.circular(16), child: GuildIcon(g, size: 64, hoverToPlay: false)),
          onPicked: (f, a) async {
            final ref = await app.uploadFile(f, scope: 1, scopeId: g.id);
            await app.updateGuild(g.id, icon: ref.withAdjust(a.zoom, a.cx, a.cy));
          },
          onAdjusted: (a) => app.updateGuild(g.id, icon: g.icon!.withAdjust(a.zoom, a.cx, a.cy)),
          onRemove: g.icon == null ? null : () => run(context, () => app.updateGuild(g.id, icon: null)),
        ),
        ImageUploadField(
          aspect: 3,
          current: g.banner,
          label: 'Banner',
          hint: 'Shown at the top of the channel list. Animated pictures are fine.',
          preview: (c) => ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: 130, child: BannerImage(blob: g.banner, accent: accent, height: 60))),
          onPicked: (f, a) async {
            final ref = await app.uploadFile(f, scope: 1, scopeId: g.id);
            await app.updateGuild(g.id, banner: ref.withAdjust(a.zoom, a.cx, a.cy));
          },
          onAdjusted: (a) => app.updateGuild(g.id, banner: g.banner!.withAdjust(a.zoom, a.cx, a.cy)),
          onRemove: g.banner == null ? null : () => run(context, () => app.updateGuild(g.id, banner: null)),
        ),
        ImageUploadField(
          aspect: 1.78,
          current: g.background,
          label: 'Chat background',
          hint: 'A faint picture behind this server\'s channels for everyone. Animated pictures loop.',
          preview: (c) => ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: 130, height: 60, child: g.background == null ? Container(color: c.faint.withValues(alpha: .2)) : BlobImage(blob: g.background))),
          onPicked: (f, a) async {
            final ref = await app.uploadFile(f, scope: 1, scopeId: g.id);
            await app.updateGuild(g.id, background: ref.withAdjust(a.zoom, a.cx, a.cy));
          },
          onAdjusted: (a) => app.updateGuild(g.id, background: g.background!.withAdjust(a.zoom, a.cx, a.cy)),
          onRemove: g.background == null ? null : () => run(context, () => app.updateGuild(g.id, background: null)),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: saving ? null : () async {
            setState(() => saving = true);
            await run(context, () => app.updateGuild(g.id, name: name.text.trim().isEmpty ? g.name : name.text.trim(), description: desc.text.trim()));
            if (mounted) setState(() => saving = false);
          },
          child: const Text('Save changes'),
        ),
      ],
    ]);
  }
}

// ====================================================================================== roles

class _Roles extends StatefulWidget {
  final String guildId;
  const _Roles({required this.guildId});

  @override
  State<_Roles> createState() => _RolesState();
}

class _RolesState extends State<_Roles> {
  String? editing;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final g = _g(context, widget.guildId);
    if (g == null) return const SizedBox.shrink();
    final myRank = g.rankOf(app.myId);
    final roles = g.roles.values.toList()..sort((a, b) => b.position.compareTo(a.position));
    final role = editing == null ? null : g.roles[editing];
    if (role != null) return _RoleEditor(guild: g, role: role, onBack: () => setState(() => editing = null));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Roles'),
      Text('Roles give people colours and permissions. A role can only be changed by someone whose highest role is above it.', style: TextStyle(color: context.muted)),
      const SizedBox(height: 14),
      FilledButton.icon(icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Create role'), onPressed: () async {
        final n = await promptDialog(context, 'New role', label: 'Role name', action: 'Create');
        if (n == null || n.trim().isEmpty || !context.mounted) return;
        run(context, () => app.createRole(g.id, n.trim(), 0, Perm.everyone & ~Perm.createInvite, (myRank == 1 << 30 ? roles.where((r) => !r.isEveryone).fold(0, (a, r) => r.position > a ? r.position : a) + 1 : (myRank - 1).clamp(1, 1 << 20))));
      }),
      const SizedBox(height: 12),
      for (final r in roles)
        Card(
          margin: const EdgeInsets.symmetric(vertical: 3),
          child: ListTile(
            leading: Container(width: 16, height: 16, decoration: BoxDecoration(color: r.color != 0 ? Color(r.color) : context.faint, shape: BoxShape.circle)),
            title: Text(r.isEveryone ? '@everyone' : r.name, style: TextStyle(fontWeight: FontWeight.w700, color: r.color != 0 ? Color(r.color) : null)),
            subtitle: Text(r.isEveryone ? 'Applies to everyone' : '${g.members.values.where((m) => m.roleIds.contains(r.id)).length} member(s)${r.hoist ? ' · shown separately' : ''}'),
            trailing: r.isEveryone || r.position < myRank ? const Icon(Icons.chevron_right_rounded) : Icon(Icons.lock_rounded, size: 16, color: context.faint),
            onTap: r.isEveryone || r.position < myRank ? () => setState(() => editing = r.id) : null,
          ),
        ),
    ]);
  }
}

class _RoleEditor extends StatefulWidget {
  final GuildModel guild;
  final RoleModel role;
  final VoidCallback onBack;
  const _RoleEditor({required this.guild, required this.role, required this.onBack});

  @override
  State<_RoleEditor> createState() => _RoleEditorState();
}

class _RoleEditorState extends State<_RoleEditor> {
  late final app = context.appRead;
  late final name = TextEditingController(text: widget.role.name);
  late int color = widget.role.color;
  late int perms = widget.role.permissions;
  late bool hoist = widget.role.hoist;
  late int position = widget.role.position;

  @override
  Widget build(BuildContext context) {
    final g = widget.guild, r = widget.role;
    final mine = g.permsOf(app.myId);
    final myRank = g.rankOf(app.myId);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: widget.onBack), Expanded(child: PageTitle(r.isEveryone ? '@everyone' : 'Edit role'))]),
      if (!r.isEveryone) ...[
        TextField(controller: name, maxLength: 40, decoration: const InputDecoration(labelText: 'Role name')),
        ColorField(label: 'Role colour', value: color == 0 ? null : Color(color), allowNone: true, onChanged: (c) => setState(() => color = c?.toARGB32() ?? 0)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Show members separately in the list'), value: hoist, onChanged: (v) => setState(() => hoist = v)),
        Row(children: [
          const Text('Position'),
          const SizedBox(width: 10),
          IconButton(icon: const Icon(Icons.remove_circle_outline_rounded), onPressed: position > 1 ? () => setState(() => position--) : null),
          Text('$position', style: const TextStyle(fontWeight: FontWeight.w800)),
          IconButton(icon: const Icon(Icons.add_circle_outline_rounded), onPressed: position + 1 < myRank ? () => setState(() => position++) : null),
          Text('  higher = more authority', style: TextStyle(fontSize: 12, color: context.muted)),
        ]),
      ],
      const SectionTitle('Permissions'),
      for (final e in Perm.labels.entries)
        Builder(builder: (context) {
          final allowed = r.isEveryone ? e.key != Perm.administrator : (mine & e.key) == e.key;
          return SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(e.value.$1, style: TextStyle(fontWeight: FontWeight.w600, color: e.key == Perm.administrator ? context.nyx.danger : null)),
            subtitle: Text(allowed ? e.value.$2 : '${e.value.$2} (you do not have this yourself)'),
            value: (perms & e.key) != 0,
            onChanged: allowed ? (v) => setState(() => perms = v ? perms | e.key : perms & ~e.key) : null,
          );
        }),
      const SizedBox(height: 16),
      Row(children: [
        FilledButton(onPressed: () => run(context, () async {
              await app.updateRole(g.id, r, name: r.isEveryone ? null : name.text.trim(), color: color, permissions: perms, position: r.isEveryone ? 0 : position, hoist: hoist);
              widget.onBack();
            }), child: const Text('Save role')),
        const SizedBox(width: 10),
        if (!r.isEveryone) OutlinedButton(style: OutlinedButton.styleFrom(foregroundColor: context.nyx.danger), onPressed: () async {
              if (await confirmDialog(context, 'Delete role “${r.name}”?', 'Members lose this role and its permissions.', danger: true) && context.mounted) {
                await run(context, () => app.deleteRole(g.id, r.id));
                widget.onBack();
              }
            }, child: const Text('Delete')),
      ]),
    ]);
  }
}

// ================================================================================== channels

class _Channels extends StatelessWidget {
  final String guildId;
  const _Channels({required this.guildId});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final g = _g(context, guildId);
    if (g == null) return const SizedBox.shrink();
    final all = g.sortedChannels;
    Widget tile(ChannelModel c, {bool indent = false}) => ListTile(
          contentPadding: EdgeInsets.only(left: indent ? 24 : 0),
          leading: Icon(c.isCategory ? Icons.folder_rounded : (c.isVoice ? Icons.volume_up_rounded : (c.restricted ? Icons.lock_rounded : Icons.tag_rounded))),
          title: Text(c.name),
          subtitle: c.topic.isEmpty ? null : Text(c.topic, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.edit_rounded, size: 20), onPressed: () => showEditChannel(context, c)),
            IconButton(icon: Icon(Icons.delete_rounded, size: 20, color: context.nyx.danger), onPressed: () async {
              if (await confirmDialog(context, 'Delete ${c.name}?', 'Messages and files in it are removed for everyone.', danger: true) && context.mounted) run(context, () => app.deleteChannel(c.id));
            }),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Channels'),
      Wrap(spacing: 8, children: [
        FilledButton.icon(icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Channel'), onPressed: () => showCreateChannel(context, g)),
        OutlinedButton.icon(icon: const Icon(Icons.create_new_folder_outlined, size: 18), label: const Text('Category'), onPressed: () => showCreateChannel(context, g, kind: ChannelKind.category)),
      ]),
      const SizedBox(height: 10),
      for (final c in all.where((c) => c.isCategory || c.parentId == null || !g.channels.containsKey(c.parentId))) ...[
        tile(c),
        if (c.isCategory) for (final child in all.where((x) => x.parentId == c.id)) tile(child, indent: true),
      ],
    ]);
  }
}

// ==================================================================================== emoji

class _Emoji extends StatefulWidget {
  final String guildId;
  final bool sticker;
  const _Emoji({required this.guildId, this.sticker = false});

  @override
  State<_Emoji> createState() => _EmojiState();
}

class _EmojiState extends State<_Emoji> {
  final name = TextEditingController();
  bool busy = false;
  String? error;

  Future<void> add() async {
    final app = context.appRead;
    final n = name.text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    if (n.length < 2) return setState(() => error = 'Give it a name (at least 2 letters, digits or _).');
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty) return;
    final f = files.first;
    final size = await f.length() ?? 0;
    final limit = widget.sticker ? 2 * 1024 * 1024 : 1024 * 1024;
    if (size > limit) return setState(() => error = '${widget.sticker ? 'Stickers' : 'Emoji'} must be under ${fmtSize(limit)} (${fmtSize(size)}).');
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await f.readAsBytes();
      final animated = f.name.toLowerCase().endsWith('.gif') || f.name.toLowerCase().endsWith('.webp');
      await app.addAsset(widget.guildId, widget.sticker ? 'sticker' : 'emoji', n, PickedFile.bytes(f.name, data, mime: guessMime(f.name)), animated);
      name.clear();
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final g = _g(context, widget.guildId);
    if (g == null) return const SizedBox.shrink();
    final emoji = g.assets.values.where((a) => a.kind == (widget.sticker ? 'sticker' : 'emoji')).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageTitle(widget.sticker ? 'Stickers' : 'Custom emoji'),
      Text(widget.sticker ? 'Big pictures anyone here can send from the emoji button → Stickers. Animated GIF / WebP stickers animate.' : 'Everyone in this server can use them by typing :name: in a message. Animated GIF / WebP emoji animate.', style: TextStyle(color: context.muted)),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: TextField(controller: name, maxLength: 32, decoration: InputDecoration(labelText: widget.sticker ? 'Sticker name' : 'Emoji name', hintText: 'party_parrot'))),
        const SizedBox(width: 10),
        FilledButton.icon(icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_rounded, size: 18), label: const Text('Pick picture'), onPressed: busy ? null : add),
      ]),
      if (error != null) Text(error!, style: TextStyle(color: context.nyx.danger)),
      const SizedBox(height: 14),
      Wrap(spacing: 12, runSpacing: 12, children: [
        for (final a in emoji)
          Container(
            width: 132,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: context.cs.onSurface.withValues(alpha: .06), borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              BlobImage(blob: a.ref, width: 48, height: 48, fit: BoxFit.contain),
              const SizedBox(height: 6),
              Text(widget.sticker ? a.name : ':${a.name}:', maxLines: 1, overflow: TextOverflow.ellipsis),
              TextButton(onPressed: () => run(context, () => app.deleteAsset(g.id, a.id)), child: Text('Delete', style: TextStyle(color: context.nyx.danger))),
            ]),
          ),
        if (emoji.isEmpty) Text(widget.sticker ? 'No stickers yet.' : 'No custom emoji yet.', style: TextStyle(color: context.muted)),
      ]),
    ]);
  }
}

// =================================================================================== members

class _Members extends StatelessWidget {
  final String guildId;
  const _Members({required this.guildId});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final g = _g(context, guildId);
    if (g == null) return const SizedBox.shrink();
    final list = g.members.keys.map((i) => app.users[i]).whereType<UserModel>().toList()..sort((a, b) => g.rankOf(b.id).compareTo(g.rankOf(a.id)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageTitle('Members — ${list.length}'),
      for (final u in list)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: UserAvatar(u, size: 40, presence: true),
          title: Text(app.displayNameIn(u.id, g.id), style: TextStyle(fontWeight: FontWeight.w700, color: g.colorOf(u.id) != null ? Color(g.colorOf(u.id)!) : null)),
          subtitle: Text([if (g.ownerId == u.id) 'Owner', ...?g.members[u.id]?.roleIds.map((r) => g.roles[r]?.name).whereType<String>()].join(' · ').isEmpty ? '@${u.username}' : [if (g.ownerId == u.id) 'Owner', ...?g.members[u.id]?.roleIds.map((r) => g.roles[r]?.name).whereType<String>()].join(' · ')),
          trailing: Builder(builder: (c) => IconButton(icon: const Icon(Icons.more_vert_rounded), onPressed: () => showMemberMenu(c, u.id, (c.findRenderObject() as RenderBox).localToGlobal(Offset.zero)))),
        ),
    ]);
  }
}

// =================================================================================== invites

class _Invites extends StatefulWidget {
  final String guildId;
  const _Invites({required this.guildId});

  @override
  State<_Invites> createState() => _InvitesState();
}

class _InvitesState extends State<_Invites> {
  Future<List<dynamic>>? future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => future = context.appRead.listInvites(widget.guildId).catchError((_) => <dynamic>[]);

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final g = _g(context, widget.guildId)!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Invites'),
      FilledButton.icon(icon: const Icon(Icons.add_link_rounded, size: 18), label: const Text('Create invite'), onPressed: () async {
        await showInvite(context, g);
        if (mounted) setState(_load);
      }),
      const SizedBox(height: 12),
      FutureBuilder(
        future: future,
        builder: (c, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          if (list.isEmpty) return Text('No active invites.', style: TextStyle(color: c.muted));
          return Column(children: [
            for (final i in list)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link_rounded),
                title: Text(i['code'], style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800, letterSpacing: 2)),
                subtitle: Text('by ${app.displayNameIn(i['createdBy'] ?? '', g.id)} · ${i['uses']}/${i['maxUses'] == 0 ? '∞' : i['maxUses']} uses · expires ${fmtTime(DateTime.parse(i['expiresAt']).toLocal())}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.copy_rounded, size: 20), onPressed: () => Clipboard.setData(ClipboardData(text: i['code']))),
                  IconButton(icon: Icon(Icons.delete_rounded, size: 20, color: c.nyx.danger), onPressed: () async { await app.api.delete('/api/invites/${i['code']}'); setState(_load); }),
                ]),
              ),
          ]);
        },
      ),
    ]);
  }
}

// ====================================================================================== bans

class _Bans extends StatefulWidget {
  final String guildId;
  const _Bans({required this.guildId});

  @override
  State<_Bans> createState() => _BansState();
}

class _BansState extends State<_Bans> {
  late Future<List<dynamic>> future = context.appRead.api.get('/api/guilds/${widget.guildId}/bans').then((v) => v as List);

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Bans'),
      FutureBuilder(
        future: future,
        builder: (c, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          if (snap.data!.isEmpty) return Text('Nobody is banned.', style: TextStyle(color: c.muted));
          return Column(children: [
            for (final b in snap.data!)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: UserAvatar(app.users[b['userId']], size: 36),
                title: Text(app.users[b['userId']]?.name ?? 'Unknown'),
                subtitle: Text('Banned ${fmtTime(DateTime.parse(b['at']).toLocal())}'),
                trailing: TextButton(onPressed: () async {
                  await app.api.delete('/api/guilds/${widget.guildId}/bans/${b['userId']}');
                  setState(() => future = app.api.get('/api/guilds/${widget.guildId}/bans').then((v) => v as List));
                }, child: const Text('Unban')),
              ),
          ]);
        },
      ),
    ]);
  }
}

// ====================================================================================== audit

class _Audit extends StatelessWidget {
  final String guildId;
  const _Audit({required this.guildId});

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Audit log'),
      Text('What moderators and admins did in this server. Message content is never in here, it cannot be read by the server.', style: TextStyle(color: context.muted)),
      const SizedBox(height: 10),
      FutureBuilder(
        future: app.api.get('/api/guilds/$guildId/audit'),
        builder: (c, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data as List;
          return Column(children: [
            for (final e in list)
              ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.history_rounded, size: 18, color: c.muted), title: Text('${app.displayNameIn(e['userId'] ?? '', guildId)} · ${e['action']}'), subtitle: Text('${fmtTime(DateTime.parse(e['at']).toLocal())}${'${e['detail']}'.isEmpty ? '' : ' · ${e['detail']}'}')),
          ]);
        },
      ),
    ]);
  }
}

// ====================================================================================== danger

class _Danger extends StatefulWidget {
  final String guildId;
  const _Danger({required this.guildId});

  @override
  State<_Danger> createState() => _DangerState();
}

class _DangerState extends State<_Danger> {
  final confirm = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final g = _g(context, widget.guildId);
    if (g == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Delete server'),
      InfoBox(Icons.warning_amber_rounded, 'This deletes ${g.name} with every channel, message and file, for everyone. It cannot be undone.', color: context.nyx.danger),
      const SectionTitle('Or hand it to someone else'),
      OutlinedButton(onPressed: () async {
        final others = g.members.keys.where((m) => m != app.myId).toList();
        final pick = await showDialog<String>(context: context, builder: (c) => NyxDialog(title: 'Transfer ownership', child: Column(children: [for (final id in others) ListTile(leading: UserAvatar(app.users[id], size: 32), title: Text(app.displayNameIn(id, g.id)), onTap: () => Navigator.pop(c, id))])));
        if (pick != null && context.mounted && await confirmDialog(context, 'Transfer ${g.name}?', 'You will no longer be the owner.', confirm: 'Transfer') && context.mounted) {
          await run(context, () async {
            await app.api.put('/api/guilds/${g.id}/owner', {'userId': pick});
            await app.refresh();
          });
        }
      }, child: const Text('Transfer ownership…')),
      const SectionTitle('Delete'),
      TextField(controller: confirm, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: 'Type the server name to confirm', hintText: g.name)),
      const SizedBox(height: 12),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: context.nyx.danger),
        onPressed: confirm.text.trim() == g.name ? () async {
          Navigator.pop(context);
          await run(context, () => app.deleteGuild(g.id));
        } : null,
        child: const Text('Delete this server forever'),
      ),
    ]);
  }
}
