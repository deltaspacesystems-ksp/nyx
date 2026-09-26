import 'package:flutter/material.dart';

import '../core/models.dart';
import 'common.dart';
import 'dialogs.dart';

class MembersPanel extends StatelessWidget {
  const MembersPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final g = app.guild;
    final ch = app.channel;

    // A 1:1 DM shows the other person's card instead of a list.
    if (g == null && ch != null && ch.kind == ChannelKind.dm) {
      final other = ch.members.firstWhere((m) => m != app.myId, orElse: () => '');
      if (other.isNotEmpty) return SingleChildScrollView(child: ProfileCard(userId: other, guildId: null, compact: true));
    }

    final ids = g != null ? g.members.keys.toList() : (ch?.members ?? const <String>[]);
    final people = ids.map((i) => app.users[i]).whereType<UserModel>().toList();

    Widget row(UserModel u) {
      final color = g?.colorOf(u.id);
      final member = g?.members[u.id];
      return InkWell(
        borderRadius: BorderRadius.circular(context.nyx.radius * .5),
        onTap: () => showProfile(context, u.id),
        onSecondaryTapDown: (d) => showMemberMenu(context, u.id, d.globalPosition),
        onLongPress: () => showProfile(context, u.id),
        child: Opacity(
          opacity: u.online ? 1 : .5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(children: [
              UserAvatar(u, size: 34, presence: true),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(app.displayNameIn(u.id, g?.id), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: color != null ? Color(color) : null))),
                    if (g != null && g.ownerId == u.id) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.workspace_premium_rounded, size: 14, color: const Color(0xFFF5A623))),
                    if (member?.timedOut == true) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.timer_off_rounded, size: 13, color: context.faint)),
                  ]),
                  if (u.profile.status.isNotEmpty) Text(u.profile.status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: context.muted)),
                ]),
              ),
            ]),
          ),
        ),
      );
    }

    Widget header(String t) => Padding(padding: const EdgeInsets.fromLTRB(12, 16, 8, 4), child: Text(t.toUpperCase(), style: TextStyle(fontSize: 11, letterSpacing: .8, fontWeight: FontWeight.w800, color: context.muted)));

    final children = <Widget>[];
    if (g != null) {
      final hoisted = g.roles.values.where((r) => r.hoist && !r.isEveryone).toList()..sort((a, b) => b.position.compareTo(a.position));
      final placed = <String>{};
      for (final r in hoisted) {
        final members = people.where((u) => u.online && !placed.contains(u.id) && (g.members[u.id]?.roleIds.contains(r.id) ?? false)).toList();
        if (members.isEmpty) continue;
        placed.addAll(members.map((m) => m.id));
        children..add(header('${r.name} — ${members.length}'))..addAll(members.map(row));
      }
      final online = people.where((u) => u.online && !placed.contains(u.id)).toList();
      final offline = people.where((u) => !u.online).toList();
      if (online.isNotEmpty) children..add(header('Online — ${online.length}'))..addAll(online.map(row));
      if (offline.isNotEmpty) children..add(header('Offline — ${offline.length}'))..addAll(offline.map(row));
    } else {
      children..add(header('Members — ${people.length}'))..addAll(people.map(row));
    }
    return ListView(padding: const EdgeInsets.fromLTRB(6, 0, 6, 12), children: children);
  }
}

/// The profile card used in the pop-up and beside 1:1 conversations.
class ProfileCard extends StatelessWidget {
  final String userId;
  final String? guildId;
  final bool compact;
  const ProfileCard({super.key, required this.userId, required this.guildId, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final u = app.users[userId];
    if (u == null) return const SizedBox.shrink();
    final g = guildId == null ? null : app.guilds[guildId];
    final accent = u.profile.accent != null ? Color(u.profile.accent!) : context.cs.primary;
    final roles = g == null ? <RoleModel>[] : (g.members[userId]?.roleIds.map((r) => g.roles[r]).whereType<RoleModel>().toList() ?? [])
      ..sort((a, b) => b.position.compareTo(a.position));
    final joined = g?.members[userId]?.joinedAt;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Stack(clipBehavior: Clip.none, children: [
        BannerImage(blob: u.profile.banner, accent: accent, height: compact ? 90 : 110),
        Positioned(
          left: 16,
          bottom: -36,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: context.cs.surface, shape: BoxShape.circle),
            child: UserAvatar(u, size: 76, presence: true, hoverToPlay: false),
          ),
        ),
      ]),
      const SizedBox(height: 42),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(app.displayNameIn(userId, g?.id), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          Text('@${u.username}', style: TextStyle(color: context.muted)),
          if (u.profile.status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(u.profile.status)),
          if (u.profileLocked)
            Padding(padding: const EdgeInsets.only(top: 10), child: Row(children: [Icon(Icons.hourglass_top_rounded, size: 14, color: context.faint), const SizedBox(width: 6), Expanded(child: Text('Profile appears when ${u.name} is next online.', style: TextStyle(fontSize: 12, color: context.faint)))])),
          if (u.profile.bio.isNotEmpty) ...[
            const Divider(height: 24),
            Text('ABOUT ME', style: TextStyle(fontSize: 11, letterSpacing: .8, fontWeight: FontWeight.w800, color: context.muted)),
            const SizedBox(height: 4),
            Text(u.profile.bio),
          ],
          if (roles.isNotEmpty) ...[
            const Divider(height: 24),
            Text('ROLES', style: TextStyle(fontSize: 11, letterSpacing: .8, fontWeight: FontWeight.w800, color: context.muted)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final r in roles)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: context.cs.onSurface.withValues(alpha: .08), borderRadius: BorderRadius.circular(8)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: r.color != 0 ? Color(r.color) : context.faint, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(r.name, style: const TextStyle(fontSize: 12)),
                  ]),
                ),
            ]),
          ],
          if (joined != null) ...[
            const Divider(height: 24),
            Text('MEMBER SINCE', style: TextStyle(fontSize: 11, letterSpacing: .8, fontWeight: FontWeight.w800, color: context.muted)),
            const SizedBox(height: 4),
            Text(fmtTime(joined.toLocal())),
          ],
        ]),
      ),
    ]);
  }
}
