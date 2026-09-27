import 'package:flutter/material.dart';

import '../core/models.dart';
import 'chat_view.dart';
import 'common.dart';
import 'dialogs.dart';
import 'friends_view.dart';
import 'update_dialog.dart';
import 'members_panel.dart';
import 'settings_user.dart';
import 'voice_room.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  static bool _checkedUpdates = false; // once per app run, not per login
  bool showMembers = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_checkedUpdates) {
        _checkedUpdates = true;
        checkForUpdates(context);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => context.appRead.setFocused(state == AppLifecycleState.resumed);

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return NyxBackground(
      child: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          final narrow = box.maxWidth < 720;
          final wide = box.maxWidth >= 1080;
          final ch = app.channel;
          final main = Stack(children: [
            if (app.guild?.background != null)
              Positioned.fill(child: IgnorePointer(child: Opacity(opacity: .22, child: BlobImage(blob: app.guild!.background, fit: BoxFit.cover)))),
            Positioned.fill(child: _Main(showMembers: showMembers, onToggleMembers: () => setState(() => showMembers = !showMembers), menu: narrow)),
            if (app.notice != null) Positioned(top: 12, left: 0, right: 0, child: Center(child: _Notice(app.notice!, onClose: app.clearNotice))),
          ]);
          final side = Row(children: [
            const GuildRail(),
            const SizedBox(width: 8),
            const Expanded(child: ChannelColumn()),
          ]);

          if (narrow) {
            return Scaffold(
              backgroundColor: Colors.transparent,
              drawer: Drawer(width: 340, backgroundColor: context.nyx.surface, child: Padding(padding: const EdgeInsets.all(8), child: side)),
              endDrawer: Drawer(width: 300, backgroundColor: context.nyx.surface, child: const MembersPanel()),
              body: Padding(padding: const EdgeInsets.all(6), child: Glass(opacity: .4, child: main)),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              const GuildRail(),
              const SizedBox(width: 8),
              SizedBox(width: 248, child: Glass(tint: context.depth(.10), child: const ChannelColumn())),
              const SizedBox(width: 8),
              Expanded(child: Glass(opacity: .4, tint: context.depth(-.02), child: main)),
              if (wide && showMembers && ch != null && (ch.isText || ch.isVoice)) ...[
                const SizedBox(width: 8),
                SizedBox(width: 236, child: Glass(child: const MembersPanel())),
              ],
            ]),
          );
        }),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;
  final VoidCallback onClose;
  const _Notice(this.text, {required this.onClose});

  @override
  Widget build(BuildContext context) => Pop(
        child: Material(
          color: context.cs.surface,
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(text)),
              IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onClose),
            ]),
          ),
        ),
      );
}

class _Main extends StatelessWidget {
  final bool showMembers, menu;
  final VoidCallback onToggleMembers;
  const _Main({required this.showMembers, required this.onToggleMembers, required this.menu});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final ch = app.channel;
    if (app.guildId == null && (app.friendsView || ch == null)) return FriendsView(menu: menu);
    if (ch == null) {
      return Column(children: [
        if (menu) Align(alignment: Alignment.centerLeft, child: Builder(builder: (c) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(c).openDrawer()))),
        Expanded(child: _Empty(guild: app.guild)),
      ]);
    }
    final key = ValueKey(ch.id);
    return ch.isVoice ? VoiceRoom(key: key, channel: ch, menu: menu, onToggleMembers: onToggleMembers) : ChatView(key: key, channel: ch, menu: menu, membersOpen: showMembers, onToggleMembers: onToggleMembers);
  }
}

class _Empty extends StatelessWidget {
  final GuildModel? guild;
  const _Empty({this.guild});

  @override
  Widget build(BuildContext context) => Center(
        child: Pop(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(guild == null ? Icons.forum_rounded : Icons.tag_rounded, size: 56, color: context.cs.primary),
            const SizedBox(height: 12),
            Text(guild == null ? 'Pick a conversation or start a new one' : 'No text channels yet', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            if (guild == null) FilledButton.icon(icon: const Icon(Icons.edit_rounded), label: const Text('New message'), onPressed: () => showNewDm(context)),
          ]),
        ),
      );
}

// ================================================================================ server rail

class GuildRail extends StatelessWidget {
  const GuildRail({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return SizedBox(
      width: 72,
      child: Glass(
        radius: BorderRadius.circular(context.nyx.radius + 4),
        tint: context.depth(.18),
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 10), children: [
          _RailButton(
            selected: app.guildId == null,
            tooltip: 'Direct messages',
            badge: app.dmMentions,
            dot: app.dmsHaveUnread,
            onTap: () => app.selectGuild(null),
            child: Icon(Icons.forum_rounded, color: app.guildId == null ? Colors.white : context.cs.primary),
            color: context.cs.primary,
          ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6), child: Divider(height: 1)),
          for (final g in app.guilds.values)
            _RailButton(
              selected: app.guildId == g.id,
              tooltip: g.name,
              badge: app.guildMentions(g),
              dot: app.guildHasUnread(g),
              onTap: () => app.selectGuild(g.id),
              child: GuildIcon(g, size: 48, hoverToPlay: false),
              onSecondary: (pos) => showGuildMenu(context, g, pos),
              flat: true,
            ),
          _RailButton(selected: false, tooltip: 'Add a server', onTap: () => showAddServer(context), child: Icon(Icons.add_rounded, color: context.nyx.online), color: context.cs.onSurface.withValues(alpha: .08)),
        ]),
      ),
    );
  }
}

class _RailButton extends StatefulWidget {
  final bool selected, flat;
  final String tooltip;
  final VoidCallback onTap;
  final void Function(Offset)? onSecondary;
  final Widget child;
  final Color? color;
  final int badge;
  final bool dot;
  const _RailButton({required this.selected, required this.tooltip, required this.onTap, required this.child, this.color, this.badge = 0, this.dot = false, this.onSecondary, this.flat = false});

  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.nyx;
    final round = widget.selected || (hover && t.hoverAnimations) ? 16.0 : 24.0;
    final dur = t.reduceMotion ? Duration.zero : const Duration(milliseconds: 180);
    return Tooltip(
      message: widget.tooltip,
      preferBelow: false,
      child: MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapDown: widget.onSecondary == null ? null : (d) => widget.onSecondary!(d.globalPosition),
          onLongPressStart: widget.onSecondary == null ? null : (d) => widget.onSecondary!(d.globalPosition),
          child: SizedBox(
            height: 58,
            child: Stack(alignment: Alignment.center, children: [
              Positioned(
                left: 0,
                child: AnimatedContainer(
                  duration: dur,
                  width: 4,
                  height: widget.selected ? 36 : (widget.dot ? 8 : (hover ? 20 : 0)),
                  decoration: BoxDecoration(color: context.cs.onSurface, borderRadius: const BorderRadius.horizontal(right: Radius.circular(4))),
                ),
              ),
              AnimatedContainer(
                duration: dur,
                curve: Curves.easeOutCubic,
                width: 48,
                height: 48,
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: widget.flat ? null : (widget.selected ? widget.color : (widget.color ?? context.cs.onSurface.withValues(alpha: .08)).withValues(alpha: widget.selected ? 1 : .18)),
                  borderRadius: BorderRadius.circular(round),
                ),
                child: widget.flat ? ClipRRect(borderRadius: BorderRadius.circular(round), child: widget.child) : widget.child,
              ),
              if (widget.badge > 0) Positioned(right: 6, bottom: 4, child: CountBadge(widget.badge)),
            ]),
          ),
        ),
      ),
    );
  }
}

// ============================================================================ channel column

class ChannelColumn extends StatefulWidget {
  const ChannelColumn({super.key});

  @override
  State<ChannelColumn> createState() => _ChannelColumnState();
}

class _ChannelColumnState extends State<ChannelColumn> {
  final collapsed = <String>{};

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final g = app.guild;
    return Column(children: [
      Expanded(child: g == null ? _dmList(context) : _guildList(context, g)),
      const _VoiceStatus(),
      const UserPanel(),
    ]);
  }

  Widget _dmList(BuildContext context) {
    final app = context.app;
    final list = app.dms.values.toList()..sort((a, b) => (app.lastMsg[b.id] ?? 0).compareTo(app.lastMsg[a.id] ?? 0));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Row(children: [
          const Expanded(child: Text('Direct messages', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
          IconButton(icon: const Icon(Icons.edit_square, size: 20), tooltip: 'New message', onPressed: () => showNewDm(context)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Material(
          type: MaterialType.transparency,
          child: ListTile(
            dense: true,
            selected: app.friendsView,
            selectedTileColor: context.cs.primary.withValues(alpha: .18),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(context.nyx.radius * .6)),
            leading: const Icon(Icons.people_alt_rounded),
            title: const Text('Friends', style: TextStyle(fontWeight: FontWeight.w700)),
            trailing: app.incomingFriends.isEmpty ? null : CountBadge(app.incomingFriends.length),
            onTap: () {
              if (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) Navigator.pop(context);
              app.showFriends();
            },
          ),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: list.isEmpty
            ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('No conversations yet.\nStart one with the button above.', textAlign: TextAlign.center, style: TextStyle(color: context.faint))))
            : ListView(padding: const EdgeInsets.all(8), children: [for (final (i, c) in list.indexed) Pop(index: i, child: _DmTile(channel: c))]),
      ),
    ]);
  }

  Widget _guildList(BuildContext context, GuildModel g) {
    final app = context.app;
    final me = app.myId;
    final channels = g.sortedChannels;
    final cats = channels.where((c) => c.isCategory).toList();
    final loose = channels.where((c) => !c.isCategory && (c.parentId == null || !g.channels.containsKey(c.parentId))).toList();

    Widget section(ChannelModel? cat, List<ChannelModel> items) {
      final open = cat == null || !collapsed.contains(cat.id);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (cat != null)
          InkWell(
            onTap: () => setState(() => open ? collapsed.add(cat.id) : collapsed.remove(cat.id)),
            onSecondaryTapDown: (d) => showChannelMenu(context, cat, d.globalPosition),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 14, 6, 4),
              child: Row(children: [
                AnimatedRotation(turns: open ? 0 : -.25, duration: const Duration(milliseconds: 150), child: Icon(Icons.expand_more_rounded, size: 16, color: context.muted)),
                const SizedBox(width: 2),
                Expanded(child: Text(cat.name.toUpperCase(), style: TextStyle(fontSize: 11.5, letterSpacing: .8, fontWeight: FontWeight.w800, color: context.muted))),
                if (g.can(me, Perm.manageChannels))
                  InkWell(onTap: () => showCreateChannel(context, g, parent: cat), child: Icon(Icons.add_rounded, size: 18, color: context.muted)),
              ]),
            ),
          ),
        Reveal(show: open, child: Column(children: [for (final c in items) _ChannelTile(guild: g, channel: c)])),
      ]);
    }

    return Column(children: [
      _GuildHeader(guild: g),
      Expanded(
        child: g.keysMissing
            ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('Waiting for another member to share this server\'s keys with you.\nThis happens automatically when one of them is online.', textAlign: TextAlign.center, style: TextStyle(color: context.muted))))
            : ListView(padding: const EdgeInsets.fromLTRB(8, 0, 8, 8), children: [
                if (loose.isNotEmpty) section(null, loose),
                for (final cat in cats) section(cat, channels.where((c) => c.parentId == cat.id).toList()),
                if (channels.isEmpty && g.can(me, Perm.manageChannels))
                  Padding(padding: const EdgeInsets.all(12), child: OutlinedButton.icon(icon: const Icon(Icons.add), label: const Text('Create a channel'), onPressed: () => showCreateChannel(context, g))),
              ]),
      ),
    ]);
  }
}

class _GuildHeader extends StatelessWidget {
  final GuildModel guild;
  const _GuildHeader({required this.guild});

  @override
  Widget build(BuildContext context) {
    final accent = guild.accent != null ? Color(guild.accent!) : context.cs.primary;
    return InkWell(
      onTapDown: (d) => showGuildMenu(context, guild, d.globalPosition),
      child: Stack(children: [
        if (guild.banner != null) Positioned.fill(child: BannerImage(blob: guild.banner, accent: accent, height: 96)),
        Container(
          height: guild.banner != null ? 96 : 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.bottomLeft,
          decoration: guild.banner == null ? null : BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: .65)])),
          child: SizedBox(
            height: 52,
            child: Row(children: [
              Expanded(child: Text(guild.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5, color: guild.banner != null ? Colors.white : null, shadows: guild.banner != null ? const [Shadow(blurRadius: 6)] : null))),
              Icon(Icons.expand_more_rounded, color: guild.banner != null ? Colors.white : context.muted),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _ChannelTile extends StatefulWidget {
  final GuildModel guild;
  final ChannelModel channel;
  const _ChannelTile({required this.guild, required this.channel});

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  bool hover = false;
  GuildModel get guild => widget.guild;
  ChannelModel get channel => widget.channel;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final selected = app.channelId == channel.id;
    final unread = channel.isText && app.hasUnread(channel.id) && !selected;
    final mentions = app.mentionsIn(channel.id);
    final inVoice = app.voiceRooms[channel.id] ?? const [];
    final cs = context.cs;
    final t = context.nyx;
    final icon = channel.isVoice ? Icons.volume_up_rounded : (channel.kind == ChannelKind.announcement ? Icons.campaign_rounded : (channel.restricted ? Icons.lock_rounded : Icons.tag_rounded));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: MouseRegion(
          onEnter: (_) => setState(() => hover = true),
          onExit: (_) => setState(() => hover = false),
          child: GestureDetector(
            onSecondaryTapDown: (d) => showChannelMenu(context, channel, d.globalPosition),
            onLongPressStart: (d) => showChannelMenu(context, channel, d.globalPosition),
            child: Stack(children: [
              Positioned(
                left: 0,
                top: 6,
                bottom: 6,
                child: AnimatedContainer(
                  duration: t.reduceMotion ? Duration.zero : const Duration(milliseconds: 160),
                  width: selected ? 3 : 0,
                  decoration: BoxDecoration(color: cs.onSurface, borderRadius: const BorderRadius.horizontal(right: Radius.circular(3))),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                margin: const EdgeInsets.only(left: 3),
                decoration: BoxDecoration(
                  color: selected ? cs.primary.withValues(alpha: .18) : (hover && t.hoverAnimations ? cs.onSurface.withValues(alpha: .05) : Colors.transparent),
                  borderRadius: BorderRadius.circular(t.radius * .55),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -2),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius * .55)),
                  leading: Icon(icon, size: 19, color: selected || unread ? cs.onSurface : context.muted),
                  title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: unread || selected ? FontWeight.w700 : FontWeight.w500, color: selected || unread ? cs.onSurface : context.muted)),
                  trailing: mentions > 0
                      ? CountBadge(mentions)
                      : (unread
                          ? Container(width: 8, height: 8, decoration: BoxDecoration(color: cs.onSurface, shape: BoxShape.circle))
                          : (hover && guild.can(app.myId, Perm.manageChannels)
                              ? Builder(builder: (c) => InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: () {
                                    final box = c.findRenderObject() as RenderBox;
                                    showChannelMenu(context, channel, box.localToGlobal(box.size.center(Offset.zero)));
                                  },
                                  child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.settings_outlined, size: 16, color: context.muted)),
                                ))
                              : null)),
                  onTap: () {
                    if (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) Navigator.pop(context);
                    app.openChannel(channel.id);
                  },
                )),
              ),
            ]),
          ),
        ),
      ),
      for (final p in inVoice)
        Padding(
          padding: const EdgeInsets.only(left: 30, bottom: 2),
          child: Row(children: [
            UserAvatar(app.users[p.userId], size: 22),
            const SizedBox(width: 8),
            Expanded(child: Text(app.displayNameIn(p.userId, guild.id), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: context.muted))),
            if (p.streaming) Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: context.nyx.danger, borderRadius: BorderRadius.circular(4)), child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800))),
            if (p.deafened) Icon(Icons.headset_off_rounded, size: 14, color: context.faint) else if (p.muted) Icon(Icons.mic_off_rounded, size: 14, color: context.faint),
          ]),
        ),
    ]);
  }
}

class _DmTile extends StatefulWidget {
  final ChannelModel channel;
  const _DmTile({required this.channel});

  @override
  State<_DmTile> createState() => _DmTileState();
}

class _DmTileState extends State<_DmTile> {
  bool hover = false;
  ChannelModel get channel => widget.channel;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final t = context.nyx;
    final selected = app.channelId == channel.id;
    final others = channel.members.where((m) => m != app.myId).map((m) => app.users[m]).whereType<UserModel>().toList();
    final title = channel.kind == ChannelKind.groupDm ? (channel.name.isNotEmpty ? channel.name : others.map((u) => u.name).join(', ')) : (others.firstOrNull?.name ?? 'Unknown');
    final unread = app.hasUnread(channel.id) && !selected;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: selected ? context.cs.primary.withValues(alpha: .18) : (hover && t.hoverAnimations ? context.cs.onSurface.withValues(alpha: .05) : Colors.transparent),
            borderRadius: BorderRadius.circular(t.radius * .6),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: ListTile(
            dense: true,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius * .6)),
            leading: channel.kind == ChannelKind.groupDm
                ? CircleAvatar(radius: 18, backgroundColor: context.cs.primary.withValues(alpha: .3), child: const Icon(Icons.group_rounded, size: 18))
                : UserAvatar(others.firstOrNull, size: 36, presence: true),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: unread || selected ? FontWeight.w700 : FontWeight.w500)),
            subtitle: channel.kind == ChannelKind.groupDm ? Text('${channel.members.length} members', style: const TextStyle(fontSize: 11)) : (others.firstOrNull?.profile.status.isNotEmpty == true ? Text(others.first.profile.status, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)) : null),
            trailing: unread ? Container(width: 9, height: 9, decoration: BoxDecoration(color: context.nyx.danger, shape: BoxShape.circle)) : null,
            onTap: () {
              if (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) Navigator.pop(context);
              app.openChannel(channel.id);
            },
          )),
        ),
      ),
    );
  }
}

// ============================================================================ user + voice bar

class _VoiceStatus extends StatelessWidget {
  const _VoiceStatus();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return ListenableBuilder(
      listenable: app.voice,
      builder: (context, _) {
        final v = app.voice;
        final ch = v.channelId == null ? null : app.channelById(v.channelId!);
        return Reveal(
          show: ch != null,
          child: ch == null
              ? const SizedBox.shrink()
              : Container(
                  margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  decoration: BoxDecoration(color: context.nyx.online.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Icon(Icons.graphic_eq_rounded, size: 18, color: context.nyx.online),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkWell(
                        onTap: () => app.openChannel(ch.id),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Text('Voice connected', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: context.nyx.online)),
                            const SizedBox(width: 6),
                            CallTimer(since: v.joinedAt, style: TextStyle(fontSize: 11.5, color: context.muted)),
                          ]),
                          Text(ch.isDm ? 'Call' : ch.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: context.muted)),
                        ]),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.call_end_rounded, size: 20), color: context.nyx.danger, tooltip: 'Disconnect', onPressed: v.leave),
                  ]),
                ),
        );
      },
    );
  }
}

class UserPanel extends StatelessWidget {
  const UserPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final me = app.me;
    if (me == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: app.voice,
      builder: (context, _) {
        final v = app.voice;
        return Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
          child: Row(children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTapDown: (d) => showPresenceMenu(context, d.globalPosition),
              child: Padding(padding: const EdgeInsets.all(2), child: UserAvatar(me, size: 36, presence: true, hoverToPlay: false)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: () => showProfile(context, me.id),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(me.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                  Text(me.profile.status.isNotEmpty ? me.profile.status : '@${me.username}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: context.muted)),
                ]),
              ),
            ),
            if (v.inCall) ...[
              IconButton(visualDensity: VisualDensity.compact, icon: Icon(v.muted ? Icons.mic_off_rounded : Icons.mic_rounded, size: 20, color: v.muted ? context.nyx.danger : null), tooltip: v.muted ? 'Unmute' : 'Mute', onPressed: v.toggleMute),
              IconButton(visualDensity: VisualDensity.compact, icon: Icon(v.deafened ? Icons.headset_off_rounded : Icons.headset_rounded, size: 20, color: v.deafened ? context.nyx.danger : null), tooltip: v.deafened ? 'Undeafen' : 'Deafen', onPressed: v.toggleDeafen),
            ],
            IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.settings_rounded, size: 20), tooltip: 'Settings', onPressed: () => showUserSettings(context)),
          ]),
        );
      },
    );
  }
}
