import 'package:flutter/material.dart';

import 'common.dart';
import 'dialogs.dart';

enum _Tab { online, all, pending, blocked }

/// The Home page: friends (online / all), requests and blocked people, plus "Add friend".
class FriendsView extends StatefulWidget {
  final bool menu;
  const FriendsView({super.key, required this.menu});

  @override
  State<FriendsView> createState() => _FriendsViewState();
}

class _FriendsViewState extends State<FriendsView> {
  _Tab tab = _Tab.online;
  final name = TextEditingController();
  String? info;
  bool infoError = false, busy = false;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final n = name.text.trim();
    if (n.isEmpty) return;
    setState(() {
      busy = true;
      info = null;
    });
    try {
      final status = await context.appRead.addFriend(n);
      info = status == 'friends' ? 'You are now friends with $n.' : 'Friend request sent to $n.';
      infoError = false;
      name.clear();
    } catch (e) {
      info = '$e';
      infoError = true;
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    List<String> ids = switch (tab) {
      _Tab.online => app.friends.where((i) => app.users[i]?.online == true).toList(),
      _Tab.all => app.friends.toList(),
      _Tab.pending => [...app.incomingFriends, ...app.outgoingFriends],
      _Tab.blocked => app.blockedUsers.toList(),
    };
    ids = ids.where(app.users.containsKey).toList()..sort((a, b) => app.users[a]!.name.toLowerCase().compareTo(app.users[b]!.name.toLowerCase()));

    Widget chip(_Tab t, String label, {int count = 0}) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            label: Row(mainAxisSize: MainAxisSize.min, children: [Text(label), if (count > 0) ...[const SizedBox(width: 6), CountBadge(count)]]),
            selected: tab == t,
            onSelected: (_) => setState(() => tab = t),
          ),
        );

    return Column(children: [
      SizedBox(
        height: 56,
        child: Row(children: [
          if (widget.menu) Builder(builder: (c) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(c).openDrawer())),
          Padding(padding: EdgeInsets.only(left: widget.menu ? 0 : 18, right: 8), child: Icon(Icons.people_alt_rounded, color: context.muted)),
          const Text('Friends', style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
        ]),
      ),
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: name,
                enabled: !busy,
                onSubmitted: (_) => _add(),
                decoration: const InputDecoration(hintText: 'Add a friend by username', isDense: true, prefixIcon: Icon(Icons.person_add_alt_1_rounded, size: 18)),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: busy ? null : _add, child: const Text('Send request')),
          ]),
          if (info != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(info!, style: TextStyle(fontSize: 12.5, color: infoError ? context.nyx.danger : context.nyx.online))),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            chip(_Tab.online, 'Online'),
            chip(_Tab.all, 'All'),
            chip(_Tab.pending, 'Pending', count: app.incomingFriends.length),
            chip(_Tab.blocked, 'Blocked'),
          ]),
        ),
      ),
      Expanded(
        child: ids.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    switch (tab) {
                      _Tab.online => app.friends.isEmpty ? 'No friends yet. Add someone by username above.' : 'None of your friends are online right now.',
                      _Tab.all => 'No friends yet. Add someone by username above.',
                      _Tab.pending => 'No pending requests.',
                      _Tab.blocked => 'Nobody is blocked.',
                    },
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.faint),
                  ),
                ),
              )
            : ListView(padding: const EdgeInsets.fromLTRB(10, 4, 10, 12), children: [for (final (i, id) in ids.indexed) Pop(index: i, child: _Row(id: id, tab: tab))]),
      ),
    ]);
  }
}

class _Row extends StatelessWidget {
  final String id;
  final _Tab tab;
  const _Row({required this.id, required this.tab});

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final u = app.users[id]!;
    final incoming = app.incomingFriends.contains(id);
    Widget act(IconData icon, String tip, VoidCallback f, {Color? color}) => IconButton(icon: Icon(icon, size: 20), color: color, tooltip: tip, onPressed: f);

    final actions = switch (tab) {
      _Tab.online || _Tab.all => [
          act(Icons.chat_bubble_rounded, 'Message', () => run(context, () async => await app.openDm(id))),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded, size: 20),
            onSelected: (v) => run(context, () async {
              if (v == 'remove') await app.removeFriend(id);
              if (v == 'block') await app.blockUser(id);
              if (v == 'profile') await showProfile(context, id);
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'profile', child: Text('Profile')),
              PopupMenuItem(value: 'remove', child: Text('Remove friend')),
              PopupMenuItem(value: 'block', child: Text('Block')),
            ],
          ),
        ],
      _Tab.pending => [
          if (incoming) act(Icons.check_rounded, 'Accept', () => run(context, () => app.acceptFriend(id)), color: context.nyx.online),
          act(Icons.close_rounded, incoming ? 'Decline' : 'Cancel request', () => run(context, () => app.removeFriend(id)), color: context.nyx.danger),
        ],
      _Tab.blocked => [TextButton(onPressed: () => run(context, () => app.unblockUser(id)), child: const Text('Unblock'))],
    };

    final sub = switch (tab) {
      _Tab.pending => incoming ? 'Incoming friend request' : 'Outgoing friend request',
      _Tab.blocked => '@${u.username}',
      _ => u.profile.status.isNotEmpty ? u.profile.status : (u.online ? _label(u.presence) : 'Offline'),
    };

    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(context.nyx.radius * .6)),
        leading: UserAvatar(u, size: 38, presence: tab != _Tab.blocked, hoverToPlay: false),
        title: Text(u.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
        onTap: () => showProfile(context, id),
      ),
    );
  }

  static String _label(String p) => switch (p) { 'idle' => 'Idle', 'dnd' => 'Do not disturb', _ => 'Online' };
}
