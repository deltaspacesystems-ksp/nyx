import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/files.dart';
import '../core/models.dart';
import 'common.dart';
import 'dialogs.dart';
import 'emoji_picker.dart';
import 'message_tile.dart';
import 'voice_room.dart';

class ChatView extends StatefulWidget {
  final ChannelModel channel;
  final bool menu, membersOpen;
  final VoidCallback onToggleMembers;
  const ChatView({super.key, required this.channel, required this.menu, required this.membersOpen, required this.onToggleMembers});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final scroll = ScrollController();
  MessageModel? replyTo, editing;
  bool loadingOlder = false, dragging = false;
  int _openedLastRead = 0;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.appRead;
      _openedLastRead = app.lastRead[widget.channel.id] ?? 0;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  Future<void> _onScroll() async {
    if (!scroll.hasClients || loadingOlder) return;
    if (scroll.position.pixels >= scroll.position.maxScrollExtent - 300) {
      loadingOlder = true;
      try {
        await context.appRead.loadOlder(widget.channel.id);
      } catch (_) {}
      loadingOlder = false;
    }
  }

  void _scrollToBottom() {
    if (scroll.hasClients) scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final ch = widget.channel;
    final msgs = app.messages[ch.id];
    final g = app.guildOfChannel(ch.id);
    if (msgs != null && msgs.length != _lastCount) {
      final grew = msgs.length > _lastCount;
      _lastCount = msgs.length;
      if (grew && scroll.hasClients && scroll.position.pixels < 200) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    final typers = app.typingIn(ch.id).map((u) => app.displayNameIn(u, g?.id)).toList();

    return DropTarget(
      onDragEntered: (_) => setState(() => dragging = true),
      onDragExited: (_) => setState(() => dragging = false),
      onDragDone: (d) async {
        setState(() => dragging = false);
        final files = <PickedFile>[];
        for (final f in d.files) {
          files.add(PickedFile(f.name, await f.length(), () => f.openRead(), mime: guessMime(f.name)));
        }
        _composer.currentState?.addFiles(files);
      },
      child: Stack(children: [
        Column(children: [
          ChatHeader(channel: ch, menu: widget.menu, membersOpen: widget.membersOpen, onToggleMembers: widget.onToggleMembers),
          const Divider(height: 1),
          if (ch.isDm) _CallStrip(channel: ch),
          Expanded(
            child: msgs == null
                ? const Center(child: CircularProgressIndicator())
                : msgs.isEmpty
                    ? _StartOfChat(channel: ch)
                    : _list(context, msgs, ch, g),
          ),
          Reveal(
            show: typers.isNotEmpty,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 2),
              child: Text(typers.isEmpty ? '' : '${typers.take(3).join(', ')} ${typers.length == 1 ? 'is' : 'are'} typing…', style: TextStyle(fontSize: 12, color: context.muted, fontStyle: FontStyle.italic)),
            ),
          ),
          Composer(
            key: _composer,
            channel: ch,
            replyTo: replyTo,
            editing: editing,
            onClearReply: () => setState(() => replyTo = null),
            onClearEdit: () => setState(() => editing = null),
            onEditLast: (m) => setState(() {
              editing = m;
              replyTo = null;
            }),
            onSent: () {
              setState(() {
                replyTo = null;
                editing = null;
              });
              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
            },
          ),
        ]),
        if (dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: context.cs.primary.withValues(alpha: .18), borderRadius: BorderRadius.circular(context.nyx.radius), border: Border.all(color: context.cs.primary, width: 2)),
                child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.upload_file_rounded, size: 48), SizedBox(height: 8), Text('Drop to upload (encrypted)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))])),
              ),
            ),
          ),
      ]),
    );
  }

  final _composer = GlobalKey<ComposerState>();

  Widget _list(BuildContext context, List<MessageModel> msgs, ChannelModel ch, GuildModel? g) {
    final items = <Widget>[];
    var dividerPlaced = false;
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      final prev = i > 0 ? msgs[i - 1] : null;
      final newDay = prev == null || prev.createdAt.day != m.createdAt.day || prev.createdAt.month != m.createdAt.month || prev.createdAt.year != m.createdAt.year;
      if (newDay) items.add(_DateDivider(m.createdAt));
      if (!dividerPlaced && _openedLastRead > 0 && m.id > _openedLastRead && m.senderId != context.appRead.myId && (prev == null || prev.id <= _openedLastRead)) {
        items.add(const _NewDivider());
        dividerPlaced = true;
      }
      final grouped = !newDay && prev.senderId == m.senderId && m.replyTo == null && m.createdAt.difference(prev.createdAt).inMinutes < 5 && !(dividerPlaced && prev.id <= _openedLastRead && m.id > _openedLastRead);
      items.add(MessageTile(
        key: ValueKey(m.id),
        msg: m,
        grouped: grouped,
        channel: ch,
        onReply: (x) => setState(() {
          replyTo = x;
          editing = null;
          _composer.currentState?.focus();
        }),
        onEdit: (x) => setState(() {
          editing = x;
          replyTo = null;
          _composer.currentState?.startEdit(x);
        }),
      ));
    }
    final reversed = items.reversed.toList();
    return Stack(children: [
      ListView.builder(
        controller: scroll,
        reverse: true,
        padding: const EdgeInsets.only(top: 12, bottom: 10),
        itemCount: reversed.length + (context.appRead.hasMoreHistory[ch.id] == false ? 1 : 0),
        itemBuilder: (_, i) => i < reversed.length ? reversed[i] : _StartOfChat(channel: ch, compact: true),
      ),
      Positioned(
        right: 16,
        bottom: 8,
        child: AnimatedBuilder(
          animation: scroll,
          builder: (_, _) => scroll.hasClients && scroll.position.pixels > 500
              ? Pop(child: FloatingActionButton.small(onPressed: _scrollToBottom, tooltip: 'Jump to latest', child: const Icon(Icons.arrow_downward_rounded)))
              : const SizedBox.shrink(),
        ),
      ),
    ]);
  }
}

class _DateDivider extends StatelessWidget {
  final DateTime d;
  const _DateDivider(this.d);

  @override
  Widget build(BuildContext context) {
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(children: [
        const Expanded(child: Divider()),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('${d.day} ${months[d.month - 1]} ${d.year}', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: context.muted))),
        const Expanded(child: Divider()),
      ]),
    );
  }
}

class _NewDivider extends StatelessWidget {
  const _NewDivider();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Row(children: [
          Expanded(child: Divider(color: context.nyx.danger)),
          Container(margin: const EdgeInsets.only(left: 8), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: context.nyx.danger, borderRadius: BorderRadius.circular(8)), child: const Text('NEW', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800))),
        ]),
      );
}

class _StartOfChat extends StatelessWidget {
  final ChannelModel channel;
  final bool compact;
  const _StartOfChat({required this.channel, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final other = channel.kind == ChannelKind.dm ? app.users[channel.members.firstWhere((m) => m != app.myId, orElse: () => '')] : null;
    final title = channel.isDm ? (other?.name ?? channel.name) : '#${channel.name}';
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (other != null) UserAvatar(other, size: 72, hoverToPlay: false) else Icon(channel.isDm ? Icons.group_rounded : Icons.tag_rounded, size: 48, color: context.cs.primary),
        const SizedBox(height: 10),
        Text(channel.isDm ? title : 'Welcome to $title', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(channel.isDm ? 'This is the beginning of your conversation. Messages here are end-to-end encrypted.' : 'This is the start of the channel. Messages here are end-to-end encrypted.', style: TextStyle(color: context.muted)),
        if (!compact) const SizedBox(height: 40),
      ]),
    );
  }
}

// =================================================================================== header

class ChatHeader extends StatelessWidget {
  final ChannelModel channel;
  final bool menu, membersOpen;
  final VoidCallback onToggleMembers;
  const ChatHeader({super.key, required this.channel, required this.menu, required this.membersOpen, required this.onToggleMembers});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final ch = channel;
    final other = ch.kind == ChannelKind.dm ? app.users[ch.members.firstWhere((m) => m != app.myId, orElse: () => '')] : null;
    final compact = MediaQuery.sizeOf(context).width < 640;
    final title = ch.kind == ChannelKind.groupDm ? (ch.name.isNotEmpty ? ch.name : ch.members.where((m) => m != app.myId).map((m) => app.users[m]?.name ?? '?').join(', ')) : (other?.name ?? ch.name);
    return SizedBox(
      height: 56,
      child: Row(children: [
        if (menu) Builder(builder: (c) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(c).openDrawer())),
        Padding(
          padding: EdgeInsets.only(left: menu ? 0 : 18, right: 8),
          child: other != null ? UserAvatar(other, size: 28, presence: true) : Icon(ch.isDm ? Icons.group_rounded : (ch.restricted ? Icons.lock_rounded : Icons.tag_rounded), color: context.muted),
        ),
        Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800))),
        if (ch.topic.isNotEmpty && !compact) ...[
          Container(width: 1, height: 20, margin: const EdgeInsets.symmetric(horizontal: 12), color: Theme.of(context).dividerColor),
          Expanded(child: Text(ch.topic, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: context.muted))),
        ] else
          const Spacer(),
        Icon(Icons.lock, size: 15, color: context.cs.secondary),
        const SizedBox(width: 4),
        if (ch.isDm) IconButton(icon: const Icon(Icons.call_rounded), tooltip: 'Start a call', onPressed: () => app.voice.join(ch.id)),
        if (!compact) ...[
          IconButton(icon: const Icon(Icons.push_pin_outlined), tooltip: 'Pinned messages', onPressed: () => showPins(context, ch)),
          IconButton(icon: const Icon(Icons.search_rounded), tooltip: 'Search this channel', onPressed: () => showChannelSearch(context, ch)),
          if (ch.kind == ChannelKind.groupDm) IconButton(icon: const Icon(Icons.group_add_rounded), tooltip: 'Add people', onPressed: () => showAddToGroup(context, ch)),
        ] else
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: 'More',
            onSelected: (v) {
              switch (v) {
                case 'pins':
                  showPins(context, ch);
                case 'search':
                  showChannelSearch(context, ch);
                case 'add':
                  showAddToGroup(context, ch);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'pins', child: ListTile(dense: true, leading: Icon(Icons.push_pin_outlined), title: Text('Pinned messages'))),
              const PopupMenuItem(value: 'search', child: ListTile(dense: true, leading: Icon(Icons.search_rounded), title: Text('Search'))),
              if (ch.kind == ChannelKind.groupDm) const PopupMenuItem(value: 'add', child: ListTile(dense: true, leading: Icon(Icons.group_add_rounded), title: Text('Add people'))),
            ],
          ),
        Builder(builder: (c) => IconButton(icon: Icon(membersOpen ? Icons.people_alt_rounded : Icons.people_alt_outlined), tooltip: 'Members', onPressed: () {
              final w = MediaQuery.sizeOf(c).width;
              if (w < 1080) {
                Scaffold.maybeOf(c)?.openEndDrawer();
                if (Scaffold.maybeOf(c) == null) showMembersSheet(c);
              } else {
                onToggleMembers();
              }
            })),
        const SizedBox(width: 6),
      ]),
    );
  }
}

class _CallStrip extends StatelessWidget {
  final ChannelModel channel;
  const _CallStrip({required this.channel});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final inCall = app.voice.channelId == channel.id;
    final others = app.voiceRooms[channel.id] ?? const [];
    if (!inCall && others.isEmpty) return const SizedBox.shrink();
    if (inCall) return SizedBox(height: 300, child: VoiceRoom(channel: channel, menu: false, onToggleMembers: () {}, embedded: true));
    return Container(
      margin: const EdgeInsets.all(10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: context.nyx.online.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.call_rounded, color: context.nyx.online),
        const SizedBox(width: 10),
        Expanded(child: Text('${others.map((p) => app.displayNameIn(p.userId)).join(', ')} in a call')),
        FilledButton(onPressed: () => app.voice.join(channel.id), child: const Text('Join')),
      ]),
    );
  }
}

// =================================================================================== composer

class Composer extends StatefulWidget {
  final ChannelModel channel;
  final MessageModel? replyTo, editing;
  final VoidCallback onClearReply, onClearEdit, onSent;
  final void Function(MessageModel) onEditLast;
  const Composer({super.key, required this.channel, required this.replyTo, required this.editing, required this.onClearReply, required this.onClearEdit, required this.onSent, required this.onEditLast});

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  final input = TextEditingController();
  final focusNode = FocusNode();
  final pending = <PickedFile>[];
  double? progress;
  String? error;
  DateTime _lastTyping = DateTime(0);
  List<UserModel> suggestions = [];

  void focus() => focusNode.requestFocus();

  void addFiles(List<PickedFile> f) {
    setState(() => pending.addAll(f));
    focus();
  }

  void startEdit(MessageModel m) {
    input.text = m.text;
    input.selection = TextSelection.collapsed(offset: input.text.length);
    focus();
  }

  @override
  void didUpdateWidget(covariant Composer old) {
    super.didUpdateWidget(old);
    if (old.editing != null && widget.editing == null) input.clear();
  }

  Future<void> pick() async {
    final files = await FilePicker.pickFiles();
    addFiles([for (final f in files) PickedFile(f.name, await f.length() ?? 0, f.readAsByteStream, mime: guessMime(f.name))]);
  }

  Future<void> send() async {
    final app = context.appRead;
    final text = input.text.trim();
    if (widget.editing != null) {
      final m = widget.editing!;
      if (text.isEmpty) return;
      try {
        await app.editMessage(m, text);
        input.clear();
        widget.onSent();
      } catch (e) {
        setState(() => error = '$e');
      }
      return;
    }
    if (text.isEmpty && pending.isEmpty) return;
    final files = List.of(pending);
    final reply = widget.replyTo;
    setState(() {
      error = null;
      if (files.isNotEmpty) progress = 0;
    });
    input.clear();
    pending.clear();
    try {
      await app.sendMessage(widget.channel.id, text, files: files, replyTo: reply, onProgress: (p) => setState(() => progress = p));
      widget.onSent();
    } on ApiException catch (e) {
      error = e.message;
      input.text = text;
    } catch (e) {
      error = 'Could not send: $e';
    }
    if (mounted) setState(() => progress = null);
  }

  void _onChanged(String v) {
    final app = context.appRead;
    if (DateTime.now().difference(_lastTyping).inSeconds > 3 && v.isNotEmpty) {
      _lastTyping = DateTime.now();
      app.typingPing();
    }
    final m = RegExp(r'(?:^|\s)@([\w.]*)$').firstMatch(v.substring(0, input.selection.isValid ? input.selection.baseOffset.clamp(0, v.length) : v.length));
    if (m == null) {
      if (suggestions.isNotEmpty) setState(() => suggestions = []);
      return;
    }
    final q = m.group(1)!.toLowerCase();
    final ch = widget.channel;
    final pool = (ch.guildId != null ? app.guilds[ch.guildId]?.members.keys : ch.members)?.map((id) => app.users[id]).whereType<UserModel>() ?? const [];
    setState(() => suggestions = pool.where((u) => u.id != app.myId && (u.username.toLowerCase().startsWith(q) || u.displayName.toLowerCase().startsWith(q))).take(6).toList());
  }

  void _pickMention(UserModel u) {
    final sel = input.selection.baseOffset;
    final before = input.text.substring(0, sel), after = input.text.substring(sel);
    final replaced = before.replaceFirst(RegExp(r'@[\w.]*$'), '@${u.username} ');
    input.text = replaced + after;
    input.selection = TextSelection.collapsed(offset: replaced.length);
    setState(() => suggestions = []);
    focus();
  }

  Future<void> _emoji(Offset anchor) async {
    final e = await showEmojiPicker(context, guild: context.appRead.guildOfChannel(widget.channel.id), anchor: anchor, channelId: widget.channel.id, onSent: widget.onSent);
    if (e == null) return;
    final sel = input.selection.isValid ? input.selection.baseOffset : input.text.length;
    input.text = input.text.substring(0, sel) + e + input.text.substring(sel);
    input.selection = TextSelection.collapsed(offset: sel + e.length);
    focus();
  }

  @override
  void dispose() {
    input.dispose();
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final ch = widget.channel;
    final g = app.guildOfChannel(ch.id);
    final me = app.myId;
    String? blocked;
    if (app.currentKey(ch.id) == null) {
      blocked = 'Waiting for the encryption key for this channel…';
    } else if (g != null && !g.can(me, Perm.sendMessages)) {
      blocked = 'You do not have permission to send messages in this channel.';
    } else if (g?.members[me]?.timedOut == true) {
      blocked = 'You are timed out and cannot send messages right now.';
    }
    final canAttach = g == null || g.can(me, Perm.attachFiles);
    final other = ch.kind == ChannelKind.dm ? app.users[ch.members.firstWhere((m) => m != me, orElse: () => '')] : null;
    final name = ch.isDm ? '@${other?.name ?? ch.name}' : '#${ch.name}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Reveal(
          show: suggestions.isNotEmpty,
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(color: context.cs.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: Theme.of(context).dividerColor)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final u in suggestions) ListTile(dense: true, leading: UserAvatar(u, size: 26), title: Text(u.name), subtitle: Text('@${u.username}', style: const TextStyle(fontSize: 11)), onTap: () => _pickMention(u)),
            ]),
          ),
        ),
        if (widget.replyTo != null)
          _Banner(
            icon: Icons.reply_rounded,
            text: 'Replying to ${app.displayNameIn(widget.replyTo!.senderId, g?.id)}',
            onClose: widget.onClearReply,
          ),
        if (widget.editing != null) _Banner(icon: Icons.edit_rounded, text: 'Editing message — Shift+Enter to save, Esc to cancel', onClose: () {
              input.clear();
              widget.onClearEdit();
            }),
        if (pending.isNotEmpty)
          SizedBox(
            height: 46,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final f in pending) Padding(padding: const EdgeInsets.only(right: 8, bottom: 6), child: InputChip(avatar: const Icon(Icons.insert_drive_file_rounded, size: 16), label: Text('${f.name} · ${fmtSize(f.size)}'), onDeleted: () => setState(() => pending.remove(f)))),
            ]),
          ),
        if (progress != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: LinearProgressIndicator(value: progress, minHeight: 3, borderRadius: BorderRadius.circular(2))),
        if (error != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(error!, style: TextStyle(color: context.nyx.danger, fontSize: 12.5))),
        if (blocked != null)
          Container(padding: const EdgeInsets.all(14), width: double.infinity, decoration: BoxDecoration(color: context.cs.onSurface.withValues(alpha: .06), borderRadius: BorderRadius.circular(context.nyx.radius)), child: Text(blocked, style: TextStyle(color: context.muted)))
        else
          Container(
            decoration: BoxDecoration(color: context.cs.onSurface.withValues(alpha: .07), borderRadius: BorderRadius.circular(context.nyx.radius)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(icon: const Icon(Icons.add_circle_rounded), tooltip: canAttach ? 'Attach files (encrypted)' : 'You cannot attach files here', onPressed: canAttach && widget.editing == null ? pick : null),
              Expanded(
                child: Focus(
                  onKeyEvent: (_, e) {
                    if (e is! KeyDownEvent) return KeyEventResult.ignored;
                    if ((e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) && HardwareKeyboard.instance.isShiftPressed) {
                      send();
                      return KeyEventResult.handled;
                    }
                    if (e.logicalKey == LogicalKeyboardKey.escape && (widget.editing != null || widget.replyTo != null)) {
                      input.clear();
                      widget.onClearEdit();
                      widget.onClearReply();
                      return KeyEventResult.handled;
                    }
                    if (e.logicalKey == LogicalKeyboardKey.arrowUp && input.text.isEmpty && widget.editing == null) {
                      final mine = (app.messages[ch.id] ?? []).where((m) => m.senderId == me && !m.deleted && m.content != null).lastOrNull;
                      if (mine != null) {
                        startEdit(mine);
                        widget.onEditLast(mine);
                        return KeyEventResult.handled;
                      }
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: input,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 8,
                    onChanged: _onChanged,
                    decoration: InputDecoration(hintText: widget.editing != null ? 'Edit your message' : 'Message $name', border: InputBorder.none, filled: false, contentPadding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
              ),
              Builder(builder: (c) => IconButton(icon: const Icon(Icons.emoji_emotions_outlined), tooltip: 'Emoji', onPressed: () => _emoji((c.findRenderObject() as RenderBox).localToGlobal(Offset.zero)))),
              IconButton.filled(icon: const Icon(Icons.send_rounded, size: 20), tooltip: 'Send (Shift+Enter)', onPressed: progress != null ? null : send),
              const SizedBox(width: 4),
            ]),
          ),
        if (blocked == null && ch.slowmode > 0) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Slowmode: ${ch.slowmode}s between messages', style: TextStyle(fontSize: 11, color: context.faint))),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onClose;
  const _Banner({required this.icon, required this.text, required this.onClose});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(color: context.cs.primary.withValues(alpha: .14), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Icon(icon, size: 16, color: context.cs.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5))),
          IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 16), onPressed: onClose),
        ]),
      );
}
