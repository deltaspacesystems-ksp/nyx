import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';
import 'common.dart';
import 'gif_picker.dart';

const _emojiSets = <String, List<String>>{
  'Smileys': ['😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😙', '🥲', '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🫢', '🤫', '🤔', '🫡', '🤐', '🤨', '😐', '😑', '😶', '🫥', '😏', '😒', '🙄', '😬', '🤥', '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮', '🤧', '🥵', '🥶', '🥴', '😵', '🤯', '🤠', '🥳', '🥸', '😎', '🤓', '🧐', '😕', '🫤', '😟', '🙁', '😮', '😯', '😲', '😳', '🥺', '🥹', '😦', '😧', '😨', '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞', '😓', '😩', '😫', '🥱', '😤', '😡', '😠', '🤬', '😈', '👿', '💀', '💩', '🤡', '👻', '👽', '🤖'],
  'People': ['👋', '🤚', '🖐️', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞', '🫰', '🤟', '🤘', '🤙', '👈', '👉', '👆', '👇', '☝️', '👍', '👎', '✊', '👊', '🤛', '🤜', '👏', '🙌', '🫶', '👐', '🤲', '🤝', '🙏', '✍️', '💅', '💪', '🦾', '👀', '👁️', '👅', '👄', '🧠', '🫀', '🦴', '👶', '🧒', '👦', '👧', '🧑', '👨', '👩', '🧔', '👱', '🧓', '👴', '👵'],
  'Hearts': ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟', '♥️', '💋', '💯', '💢', '💥', '💫', '💦', '💨', '🕳️', '💬', '💭', '💤'],
  'Nature': ['🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🙈', '🙉', '🙊', '🐔', '🐧', '🐦', '🦆', '🦅', '🦉', '🦇', '🐺', '🐗', '🐴', '🦄', '🐝', '🐛', '🦋', '🐌', '🐞', '🐢', '🐍', '🦎', '🐙', '🦑', '🦀', '🐠', '🐬', '🐳', '🦈', '🌸', '🌹', '🌻', '🌼', '🌷', '🌱', '🌲', '🌳', '🌴', '🌵', '🍀', '🍁', '🌈', '☀️', '⭐', '🌙', '⚡', '🔥', '💧', '❄️'],
  'Food': ['🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🥑', '🥦', '🥕', '🌽', '🥔', '🍞', '🥐', '🧀', '🍗', '🍖', '🍔', '🍟', '🍕', '🌭', '🥪', '🌮', '🌯', '🍜', '🍝', '🍣', '🍤', '🍦', '🍩', '🍪', '🎂', '🍰', '🍫', '🍬', '☕', '🍵', '🍺', '🍻', '🥂', '🍷', '🥤'],
  'Activity': ['⚽', '🏀', '🏈', '⚾', '🎾', '🏐', '🎱', '🏓', '🏸', '🥊', '🎯', '⛳', '🎣', '🎮', '🕹️', '🎲', '🧩', '🎭', '🎨', '🎬', '🎤', '🎧', '🎼', '🎹', '🥁', '🎷', '🎸', '🎻', '🏆', '🥇', '🥈', '🥉', '🎉', '🎊', '🎁', '🎈'],
  'Objects': ['⌚', '📱', '💻', '⌨️', '🖥️', '🖱️', '💾', '📷', '📹', '🎥', '📞', '📺', '📻', '⏰', '🔋', '💡', '🔦', '💰', '💳', '🔧', '🔨', '⚙️', '🔒', '🔑', '📌', '📎', '✂️', '📝', '📚', '📖', '🔍', '🧲', '🚀', '✈️', '🚗', '🏠', '🌍', '⏳', '✅', '❌', '⚠️', '❓', '❗', '➕', '➖', '✔️', '🔔', '🔕', '🎵', '📣'],
};

class EmojiPickerResult {
  final String text; // unicode emoji, or ":name:" for a custom one
  EmojiPickerResult(this.text);
}

/// Pop-up emoji chooser with the server's own emoji first.
/// With [channelId] the picker also offers GIFs and stickers, which are sent straight to that channel ([onSent] afterwards).
Future<String?> showEmojiPicker(BuildContext context, {GuildModel? guild, Offset? anchor, String? channelId, VoidCallback? onSent}) async {
  final r = await _showPicker(context, guild: guild, anchor: anchor, channelId: channelId, onSent: onSent);
  if (r != null) EmojiStats.instance.use(r);
  return r;
}

Future<String?> _showPicker(BuildContext context, {GuildModel? guild, Offset? anchor, String? channelId, VoidCallback? onSent}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (c) {
      final size = MediaQuery.sizeOf(c);
      final w = 340.0, h = 380.0;
      final left = anchor == null ? (size.width - w) / 2 : (anchor.dx - w + 20).clamp(8.0, size.width - w - 8);
      final top = anchor == null ? (size.height - h) / 2 : (anchor.dy - h - 10).clamp(8.0, size.height - h - 8);
      return Stack(children: [
        Positioned(left: left, top: top, width: w, height: h, child: Pop(child: Material(elevation: 12, borderRadius: BorderRadius.circular(16), color: c.cs.surface, child: _Picker(guild: guild, channelId: channelId, onSent: onSent)))),
      ]);
    },
  );
}

class _Picker extends StatefulWidget {
  final GuildModel? guild;
  final String? channelId;
  final VoidCallback? onSent;
  const _Picker({this.guild, this.channelId, this.onSent});

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  String query = '';
  int tab = 0; // 0 emoji, 1 GIFs, 2 stickers

  @override
  void initState() {
    super.initState();
    EmojiStats.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    final custom = widget.guild?.assets.values.where((a) => a.kind == 'emoji' && a.ref != null && (query.isEmpty || a.name.toLowerCase().contains(query.toLowerCase()))).toList() ?? [];
    final groups = query.isEmpty ? _emojiSets : <String, List<String>>{};
    final cid = widget.channelId;
    return Column(children: [
      if (cid != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(spacing: 6, children: [
              for (final (i, l) in ['Emoji', 'GIFs', 'Stickers'].indexed) ChoiceChip(label: Text(l), selected: tab == i, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => tab = i)),
            ]),
          ),
        ),
      if (cid != null && tab == 1) Expanded(child: Padding(padding: const EdgeInsets.only(top: 8), child: GifTab(channelId: cid, onSent: widget.onSent ?? () {})))
      else if (cid != null && tab == 2) Expanded(child: StickerTab(guild: widget.guild, channelId: cid, onSent: widget.onSent ?? () {}))
      else ...[
      Padding(
        padding: const EdgeInsets.all(10),
        child: TextField(autofocus: true, onChanged: (v) => setState(() => query = v), decoration: const InputDecoration(hintText: 'Search emoji', isDense: true, prefixIcon: Icon(Icons.search, size: 18))),
      ),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), children: [
          if (query.isEmpty) ...[
            _title(context, 'Frequently used'),
            ListenableBuilder(
              listenable: EmojiStats.instance,
              builder: (context, _) => Wrap(spacing: 2, runSpacing: 2, children: [
                for (final emoji in EmojiStats.instance.top(5)) InkWell(borderRadius: BorderRadius.circular(8), onTap: () => Navigator.pop(context, emoji), child: Padding(padding: const EdgeInsets.all(5), child: Text(emoji, style: const TextStyle(fontSize: 24)))),
              ]),
            ),
          ],
          if (custom.isNotEmpty) ...[
            _title(context, widget.guild!.name),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final a in custom)
                Tooltip(
                  message: ':${a.name}:',
                  child: InkWell(borderRadius: BorderRadius.circular(8), onTap: () => Navigator.pop(context, ':${a.name}:'), child: Padding(padding: const EdgeInsets.all(4), child: BlobImage(blob: a.ref, width: 30, height: 30, fit: BoxFit.contain))),
                ),
            ]),
          ],
          for (final e in groups.entries) ...[
            _title(context, e.key),
            Wrap(spacing: 2, runSpacing: 2, children: [
              for (final emoji in e.value) InkWell(borderRadius: BorderRadius.circular(8), onTap: () => Navigator.pop(context, emoji), child: Padding(padding: const EdgeInsets.all(5), child: Text(emoji, style: const TextStyle(fontSize: 24)))),
            ]),
          ],
          if (query.isNotEmpty && custom.isEmpty)
            Padding(padding: const EdgeInsets.all(20), child: Text('Only this server\'s custom emoji can be searched by name.', textAlign: TextAlign.center, style: TextStyle(color: context.faint))),
        ]),
      ),
      ],
    ]);
  }

  Widget _title(BuildContext context, String t) => Padding(padding: const EdgeInsets.fromLTRB(2, 10, 2, 4), child: Text(t.toUpperCase(), style: TextStyle(fontSize: 11, letterSpacing: .8, fontWeight: FontWeight.w800, color: context.muted)));
}

const quickReactions = ['👍', '❤️', '😂', '🎉', '😮', '😢'];

/// How often each (unicode) emoji is used on this device: drives the "Frequently used" row and the quick
/// reactions in the message toolbar. Stays local, never leaves the device.
class EmojiStats extends ChangeNotifier {
  EmojiStats._();
  static final instance = EmojiStats._();
  static const _key = 'nyx.emoji.freq';

  final _counts = <String, int>{};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        for (final e in (jsonDecode(raw) as Map).entries) {
          _counts[e.key as String] = (e.value as num).toInt();
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  /// The [n] most used emoji, padded with sensible defaults so there are always [n].
  List<String> top(int n) {
    final sorted = _counts.entries.where((e) => !e.key.startsWith(':')).toList()..sort((a, b) => b.value.compareTo(a.value));
    final out = [for (final e in sorted.take(n)) e.key];
    for (final d in quickReactions) {
      if (out.length >= n) break;
      if (!out.contains(d)) out.add(d);
    }
    return out;
  }

  Future<void> use(String emoji) async {
    if (emoji.startsWith(':')) return;
    _counts[emoji] = (_counts[emoji] ?? 0) + 1;
    notifyListeners();
    try {
      // Keep the store small: only the 60 most used survive.
      final keep = (_counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(60);
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode({for (final e in keep) e.key: e.value}));
    } catch (_) {}
  }
}
