import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/files.dart';
import '../core/models.dart';
import '../theme/nyx_theme.dart';
import 'common.dart';
import 'dialogs.dart';
import 'emoji_picker.dart';
import 'markdown.dart';

class MessageTile extends StatefulWidget {
  final MessageModel msg;
  final bool grouped;
  final ChannelModel channel;
  final void Function(MessageModel) onReply;
  final void Function(MessageModel) onEdit;
  const MessageTile({super.key, required this.msg, required this.grouped, required this.channel, required this.onReply, required this.onEdit});

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile> {
  bool hover = false;

  @override
  void initState() {
    super.initState();
    EmojiStats.instance.load();
  }

  MessageModel get msg => widget.msg;

  Future<void> _react(BuildContext context, Offset anchor) async {
    final app = context.appRead;
    final g = app.guildOfChannel(msg.channelId);
    final e = await showEmojiPicker(context, guild: g, anchor: anchor);
    if (e != null) await app.toggleReaction(msg, e);
  }

  Future<void> _menu(BuildContext context, Offset pos) async {
    final app = context.appRead;
    final g = app.guildOfChannel(msg.channelId);
    final own = msg.senderId == app.myId;
    final canManage = g == null ? true : g.can(app.myId, Perm.manageMessages);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        const PopupMenuItem(value: 'reply', child: ListTile(dense: true, leading: Icon(Icons.reply_rounded), title: Text('Reply'))),
        if (own) const PopupMenuItem(value: 'edit', child: ListTile(dense: true, leading: Icon(Icons.edit_rounded), title: Text('Edit'))),
        if (msg.files.any((f) => f.mime == 'image/gif' || f.mime == 'image/webp') && msg.content?['st'] != true) const PopupMenuItem(value: 'savegif', child: ListTile(dense: true, leading: Icon(Icons.star_rounded), title: Text('Save GIF'))),
        if (msg.text.isNotEmpty) const PopupMenuItem(value: 'copy', child: ListTile(dense: true, leading: Icon(Icons.copy_rounded), title: Text('Copy text'))),
        if (canManage) PopupMenuItem(value: 'pin', child: ListTile(dense: true, leading: const Icon(Icons.push_pin_rounded), title: Text(msg.pinned ? 'Unpin' : 'Pin'))),
        if (own || (g != null && canManage)) PopupMenuItem(value: 'delete', child: ListTile(dense: true, leading: Icon(Icons.delete_rounded, color: context.nyx.danger), title: Text('Delete', style: TextStyle(color: context.nyx.danger)))),
      ],
    );
    if (!context.mounted) return;
    try {
      switch (choice) {
        case 'reply':
          widget.onReply(msg);
        case 'edit':
          widget.onEdit(msg);
        case 'copy':
          await Clipboard.setData(ClipboardData(text: msg.text));
        case 'savegif':
          final gif = msg.files.firstWhere((f) => f.mime == 'image/gif' || f.mime == 'image/webp');
          await app.saveGif(gif);
          app.toast('GIF saved. Find it in the GIF picker.');
        case 'pin':
          await app.setPinned(msg, !msg.pinned);
        case 'delete':
          if (await confirmDialog(context, 'Delete message?', 'This cannot be undone.', danger: true)) await app.deleteMessage(msg);
      }
    } catch (e) {
      app.toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final t = context.nyx;
    final g = app.guildOfChannel(msg.channelId);
    final sender = app.users[msg.senderId];
    final own = msg.senderId == app.myId;
    final color = g?.colorOf(msg.senderId);
    final name = app.displayNameIn(msg.senderId, g?.id);
    final mentioned = msg.mentions.contains(app.myId) || msg.mentionsEveryone;
    final bubbles = t.messageStyle == MessageStyle.bubbles;

    Widget body;
    if (msg.deleted) {
      body = Text('Message deleted', style: TextStyle(fontStyle: FontStyle.italic, color: context.faint));
    } else if (msg.waitingForKey) {
      body = Text('🔒 Waiting for the key to read this message…', style: TextStyle(fontStyle: FontStyle.italic, color: context.muted));
    } else if (msg.content == null) {
      body = Text('🔒 Could not decrypt or verify this message', style: TextStyle(fontStyle: FontStyle.italic, color: context.nyx.danger));
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (msg.text.isNotEmpty) RichText2(msg.text, guild: g, mentionIds: msg.mentions.toSet()),
        for (final f in msg.files)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: msg.content?['st'] == true && f.isImage ? Align(alignment: Alignment.centerLeft, child: BlobImage(blob: f, width: 160, height: 160, fit: BoxFit.contain)) : AttachmentView(file: f),
          ),
        if (msg.reactions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 4, runSpacing: 4, children: [
              for (final r in msg.reactions) _ReactionChip(reaction: r, msg: msg, guild: g),
              _AddReaction(onTap: (pos) => _react(context, pos)),
            ]),
          ),
      ]);
    }

    final content = Padding(
      padding: EdgeInsets.fromLTRB(16, widget.grouped ? 1 : 10, 16, 1),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 44,
          child: widget.grouped
              ? (hover ? Padding(padding: const EdgeInsets.only(top: 3), child: Text('${msg.createdAt.hour.toString().padLeft(2, '0')}:${msg.createdAt.minute.toString().padLeft(2, '0')}', style: TextStyle(fontSize: 10.5, color: context.faint))) : null)
              : InkWell(customBorder: const CircleBorder(), onTap: () => showProfile(context, msg.senderId), child: UserAvatar(sender, size: 40)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (msg.replyTo != null) _ReplyPreview(msg: msg),
            if (!widget.grouped)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(children: [
                  Flexible(child: InkWell(onTap: () => showProfile(context, msg.senderId), child: Text(name, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: color != null ? Color(color) : context.cs.onSurface)))),
                  const SizedBox(width: 8),
                  Text(fmtTime(msg.createdAt), style: TextStyle(fontSize: 11, color: context.faint)),
                  if (msg.pinned) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.push_pin_rounded, size: 12, color: context.faint)),
                ]),
              ),
            bubbles
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: (own ? context.cs.primary : context.cs.onSurface).withValues(alpha: own ? .22 : .08), borderRadius: BorderRadius.circular(t.radius)),
                    child: body,
                  )
                : body,
            if (msg.editedAt != null && !msg.deleted) Text('(edited)', style: TextStyle(fontSize: 10.5, color: context.faint)),
          ]),
        ),
      ]),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onSecondaryTapDown: (d) => _menu(context, d.globalPosition),
        onLongPressStart: (d) => _menu(context, d.globalPosition),
        child: Stack(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: mentioned && !own ? context.cs.primary.withValues(alpha: .10) : (hover ? context.cs.onSurface.withValues(alpha: .04) : Colors.transparent),
              border: mentioned && !own ? Border(left: BorderSide(color: context.cs.primary, width: 3)) : null,
            ),
            child: content,
          ),
          if (hover && !msg.deleted)
            Positioned(
              right: 16,
              top: -2,
              child: Pop(
                child: Material(
                  elevation: 3,
                  color: context.cs.surface,
                  borderRadius: BorderRadius.circular(10),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    ListenableBuilder(
                      listenable: EmojiStats.instance,
                      builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final e in EmojiStats.instance.top(5))
                          Tooltip(
                            message: 'React with $e',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                EmojiStats.instance.use(e);
                                context.appRead.toggleReaction(msg, e).catchError((err) => context.appRead.toast('$err'));
                              },
                              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4), child: Text(e, style: const TextStyle(fontSize: 17))),
                            ),
                          ),
                      ]),
                    ),
                    Container(width: 1, height: 18, color: context.faint.withValues(alpha: .4)),
                    Builder(builder: (c) => _Tool(Icons.add_reaction_outlined, 'Add reaction', () {
                          final box = c.findRenderObject() as RenderBox;
                          _react(context, box.localToGlobal(Offset.zero));
                        })),
                    _Tool(Icons.reply_rounded, 'Reply', () => widget.onReply(msg)),
                    if (own) _Tool(Icons.edit_rounded, 'Edit', () => widget.onEdit(msg)),
                    Builder(builder: (c) => _Tool(Icons.more_horiz_rounded, 'More', () {
                          final box = c.findRenderObject() as RenderBox;
                          _menu(context, box.localToGlobal(Offset(0, box.size.height)));
                        })),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class _Tool extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  const _Tool(this.icon, this.tip, this.onTap);

  @override
  Widget build(BuildContext context) => Tooltip(message: tip, child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onTap, child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, size: 18, color: context.muted))));
}

class _ReplyPreview extends StatelessWidget {
  final MessageModel msg;
  const _ReplyPreview({required this.msg});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final ref = app.messageById(msg.channelId, msg.replyTo!);
    final who = ref == null ? null : app.displayNameIn(ref.senderId, app.guildOfChannel(msg.channelId)?.id);
    final text = ref == null ? 'Original message not loaded' : (ref.deleted ? 'Message deleted' : (ref.text.isNotEmpty ? ref.text : (ref.files.isNotEmpty ? 'Attachment' : '…')));
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(children: [
        Icon(Icons.subdirectory_arrow_right_rounded, size: 16, color: context.faint),
        const SizedBox(width: 4),
        if (who != null) Text(who, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: context.muted)),
        const SizedBox(width: 6),
        Flexible(child: Text(text.replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: context.faint))),
      ]),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final ReactionModel reaction;
  final MessageModel msg;
  final GuildModel? guild;
  const _ReactionChip({required this.reaction, required this.msg, required this.guild});

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final mine = reaction.users.contains(app.myId);
    final custom = RegExp(r'^:([a-zA-Z0-9_]{2,32}):$').firstMatch(reaction.emoji);
    final asset = custom == null ? null : guild?.assets.values.where((a) => a.name == custom.group(1)).firstOrNull;
    final who = reaction.users.map((u) => app.displayNameIn(u, guild?.id)).join(', ');
    return Tooltip(
      message: who,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => EmojiStats.instance.use(reaction.emoji).then((_) => app.toggleReaction(msg, reaction.emoji)).catchError((e) => app.toast('$e')),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: (mine ? context.cs.primary : context.cs.onSurface).withValues(alpha: mine ? .22 : .08),
            border: Border.all(color: mine ? context.cs.primary : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            asset?.ref != null ? BlobImage(blob: asset!.ref, width: 18, height: 18, fit: BoxFit.contain) : Text(reaction.emoji, style: const TextStyle(fontSize: 15)),
            const SizedBox(width: 5),
            Text('${reaction.users.length}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: mine ? context.cs.primary : context.muted)),
          ]),
        ),
      ),
    );
  }
}

class _AddReaction extends StatelessWidget {
  final void Function(Offset) onTap;
  const _AddReaction({required this.onTap});

  @override
  Widget build(BuildContext context) => Builder(
        builder: (c) => InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onTap((c.findRenderObject() as RenderBox).localToGlobal(Offset.zero)),
          child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: c.cs.onSurface.withValues(alpha: .06), borderRadius: BorderRadius.circular(8)), child: Icon(Icons.add_reaction_outlined, size: 16, color: c.muted)),
        ),
      );
}

// ================================================================================== attachments

class AttachmentView extends StatefulWidget {
  final BlobRef file;
  const AttachmentView({super.key, required this.file});

  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  bool saving = false;
  String? err;

  Future<void> save() async {
    final app = context.appRead;
    setState(() {
      saving = true;
      err = null;
    });
    try {
      final data = await app.media.load(widget.file);
      await FilePicker.saveFile(fileName: widget.file.name.isEmpty ? 'file' : widget.file.name, bytes: data);
    } catch (e) {
      err = 'Could not decrypt or save this file.';
    }
    if (mounted) setState(() => saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    if (f.isImage && f.size < 40 * 1024 * 1024) {
      return GestureDetector(
        onTap: () => showImageViewer(context, f),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 340, minWidth: 80, minHeight: 60),
              child: BlobImage(blob: f, fit: BoxFit.contain, fallback: Container(width: 200, height: 120, color: context.cs.onSurface.withValues(alpha: .06), child: const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))))),
            ),
          ),
        ),
      );
    }
    final icon = f.isVideo ? Icons.movie_rounded : (f.isAudio ? Icons.audiotrack_rounded : (f.mime.contains('pdf') ? Icons.picture_as_pdf_rounded : Icons.insert_drive_file_rounded));
    return Container(
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: context.cs.onSurface.withValues(alpha: .07), borderRadius: BorderRadius.circular(12), border: Border.all(color: context.cs.onSurface.withValues(alpha: .06))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 30, color: context.cs.primary),
        const SizedBox(width: 10),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(f.name.isEmpty ? 'file' : f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(err ?? '${fmtSize(f.size)} · encrypted', style: TextStyle(fontSize: 12, color: err != null ? context.nyx.danger : context.muted)),
          ]),
        ),
        const SizedBox(width: 6),
        saving ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : IconButton(icon: const Icon(Icons.download_rounded), tooltip: 'Decrypt & save', onPressed: save),
      ]),
    );
  }
}

void showImageViewer(BuildContext context, BlobRef f) {
  showDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (c) => GestureDetector(
      onTap: () => Navigator.pop(c),
      child: Stack(children: [
        Positioned.fill(child: InteractiveViewer(minScale: .5, maxScale: 6, child: Center(child: BlobImage(blob: f, fit: BoxFit.contain)))),
        Positioned(
          top: 12,
          right: 12,
          child: Row(children: [
            Text(f.name, style: const TextStyle(color: Colors.white70)),
            IconButton(color: Colors.white, icon: const Icon(Icons.download_rounded), tooltip: 'Save', onPressed: () async {
              final data = await c.appRead.media.load(f);
              await FilePicker.saveFile(fileName: f.name.isEmpty ? 'image' : f.name, bytes: data);
            }),
            IconButton(color: Colors.white, icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(c)),
          ]),
        ),
      ]),
    ),
  );
}
