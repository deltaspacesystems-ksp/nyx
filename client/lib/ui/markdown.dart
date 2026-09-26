import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import 'common.dart';

/// Discord-style text: **bold**, *italic*, __underline__, ~~strike~~, `code`, ```blocks```, > quotes,
/// ||spoilers||, links, @mentions and :custom_emoji:. Also big emoji when a message is only emoji.
class RichText2 extends StatelessWidget {
  final String text;
  final GuildModel? guild;
  final Set<String> mentionIds; // people mentioned (for highlighting)
  final bool selectable;
  final double? fontSize;
  const RichText2(this.text, {super.key, this.guild, this.mentionIds = const {}, this.selectable = true, this.fontSize});

  /// True when the message is nothing but emoji (unicode or :custom:) - those are shown big.
  static bool _onlyEmoji(String s) {
    final t = s.trim().replaceAll(RegExp(r':[a-zA-Z0-9_]{2,32}:'), '');
    if (t.isEmpty) return s.trim().isNotEmpty;
    for (final r in t.runes) {
      final ok = r == 0x200D || r == 0xFE0F || r == 0x20 || r == 0x0A || (r >= 0x1F300 && r <= 0x1FAFF) || (r >= 0x2600 && r <= 0x27BF) || (r >= 0x1F1E6 && r <= 0x1F1FF) || r == 0x2B50 || r == 0x2B55 || r == 0x2764;
      if (!ok) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: fontSize ?? 15, height: 1.38, color: context.cs.onSurface);
    final blocks = _blocks(text);
    final jumbo = text.trim().isNotEmpty && text.length < 60 && _onlyEmoji(text);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final b in blocks) _block(context, b, jumbo ? base.copyWith(fontSize: 34) : base, jumbo),
    ]);
  }

  Widget _block(BuildContext context, _Block b, TextStyle base, bool jumbo) {
    switch (b.kind) {
      case _Kind.code:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: context.cs.onSurface.withValues(alpha: .07), borderRadius: BorderRadius.circular(8), border: Border.all(color: context.cs.onSurface.withValues(alpha: .08))),
          child: SelectableText(b.text, style: base.copyWith(fontFamily: 'monospace', fontSize: (base.fontSize ?? 15) - 1.5, height: 1.3)),
        );
      case _Kind.quote:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: context.cs.onSurface.withValues(alpha: .3), width: 3))),
          child: _rich(context, b.text, base, jumbo),
        );
      case _Kind.text:
        return _rich(context, b.text, base, jumbo);
    }
  }

  Widget _rich(BuildContext context, String s, TextStyle base, bool jumbo) {
    final spans = _inline(context, s, base, jumbo);
    return selectable ? SelectableText.rich(TextSpan(children: spans, style: base)) : Text.rich(TextSpan(children: spans, style: base));
  }

  // -------------------------------------------------------------------------- inline

  static final _inlineRe = RegExp(
    r'(?<code>`[^`\n]+`)'
    r'|(?<spoiler>\|\|.+?\|\|)'
    r'|(?<bold>\*\*.+?\*\*)'
    r'|(?<under>__.+?__)'
    r'|(?<strike>~~.+?~~)'
    r'|(?<ital>\*[^*\s][^*]*?\*|_[^_\s][^_]*?_)'
    r'|(?<url>https?://[^\s<>]+)'
    r'|(?<mention>@(?:everyone|here|[\w.]+(?: [\w.]+)?))'
    r'|(?<emoji>:[a-zA-Z0-9_]{2,32}:)',
    dotAll: true,
  );

  List<InlineSpan> _inline(BuildContext context, String s, TextStyle base, bool jumbo) {
    final out = <InlineSpan>[];
    var i = 0;
    for (final m in _inlineRe.allMatches(s)) {
      if (m.start > i) out.add(TextSpan(text: s.substring(i, m.start)));
      final t = m.group(0)!;
      if (m.namedGroup('code') != null) {
        out.add(TextSpan(text: t.substring(1, t.length - 1), style: TextStyle(fontFamily: 'monospace', backgroundColor: context.cs.onSurface.withValues(alpha: .1), fontSize: (base.fontSize ?? 15) - 1)));
      } else if (m.namedGroup('spoiler') != null) {
        out.add(WidgetSpan(alignment: PlaceholderAlignment.baseline, baseline: TextBaseline.alphabetic, child: _Spoiler(t.substring(2, t.length - 2), base)));
      } else if (m.namedGroup('bold') != null) {
        out.add(TextSpan(children: _inline(context, t.substring(2, t.length - 2), base, jumbo), style: const TextStyle(fontWeight: FontWeight.w800)));
      } else if (m.namedGroup('under') != null) {
        out.add(TextSpan(children: _inline(context, t.substring(2, t.length - 2), base, jumbo), style: const TextStyle(decoration: TextDecoration.underline)));
      } else if (m.namedGroup('strike') != null) {
        out.add(TextSpan(children: _inline(context, t.substring(2, t.length - 2), base, jumbo), style: const TextStyle(decoration: TextDecoration.lineThrough)));
      } else if (m.namedGroup('ital') != null) {
        out.add(TextSpan(children: _inline(context, t.substring(1, t.length - 1), base, jumbo), style: const TextStyle(fontStyle: FontStyle.italic)));
      } else if (m.namedGroup('url') != null) {
        var url = t;
        var tail = '';
        while (url.isNotEmpty && '.,;:!?)]'.contains(url[url.length - 1])) {
          tail = url[url.length - 1] + tail;
          url = url.substring(0, url.length - 1);
        }
        out.add(TextSpan(text: url, style: TextStyle(color: context.cs.secondary, decoration: TextDecoration.underline), recognizer: TapGestureRecognizer()..onTap = () => _open(context, url)));
        if (tail.isNotEmpty) out.add(TextSpan(text: tail));
      } else if (m.namedGroup('mention') != null) {
        final mine = _isMe(context, t);
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(color: (mine ? context.cs.primary : context.cs.secondary).withValues(alpha: .22), borderRadius: BorderRadius.circular(5)),
            child: Text(t, style: base.copyWith(fontWeight: FontWeight.w700, color: mine ? context.cs.primary : context.cs.secondary)),
          ),
        ));
      } else {
        final name = t.substring(1, t.length - 1);
        final asset = guild?.assets.values.where((a) => a.kind == 'emoji' && a.name == name).firstOrNull;
        if (asset?.ref != null) {
          final size = jumbo ? 48.0 : 22.0;
          out.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 1), child: BlobImage(blob: asset!.ref, width: size, height: size, fit: BoxFit.contain))));
        } else {
          out.add(TextSpan(text: t));
        }
      }
      i = m.end;
    }
    if (i < s.length) out.add(TextSpan(text: s.substring(i)));
    return out;
  }

  bool _isMe(BuildContext context, String token) {
    final app = context.appRead;
    final me = app.me;
    if (me == null) return false;
    final n = token.substring(1).toLowerCase();
    if (n == 'everyone' || n == 'here') return true;
    return n == me.username.toLowerCase() || n == me.displayName.toLowerCase() || n.startsWith(me.username.toLowerCase());
  }

  Future<void> _open(BuildContext context, String url) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Open this link?'),
        content: SelectableText(url),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open')),
        ],
      ),
    );
    if (ok == true) await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  // --------------------------------------------------------------------------- blocks

  static List<_Block> _blocks(String text) {
    final out = <_Block>[];
    final re = RegExp(r'```(?:[a-zA-Z0-9+#-]*\n)?(.*?)```', dotAll: true);
    var i = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > i) out.addAll(_lines(text.substring(i, m.start)));
      out.add(_Block(_Kind.code, (m.group(1) ?? '').replaceAll(RegExp(r'^\n|\n$'), '')));
      i = m.end;
    }
    if (i < text.length) out.addAll(_lines(text.substring(i)));
    return out;
  }

  static List<_Block> _lines(String text) {
    final out = <_Block>[];
    final buf = <String>[];
    var quote = false;
    void flush() {
      if (buf.isNotEmpty) out.add(_Block(quote ? _Kind.quote : _Kind.text, buf.join('\n')));
      buf.clear();
    }

    for (final line in text.split('\n')) {
      final q = line.startsWith('> ');
      if (q != quote) flush();
      quote = q;
      buf.add(q ? line.substring(2) : line);
    }
    flush();
    return out.where((b) => b.text.trim().isNotEmpty || b.kind != _Kind.text).toList();
  }
}

enum _Kind { text, quote, code }

class _Block {
  final _Kind kind;
  final String text;
  _Block(this.kind, this.text);
}

class _Spoiler extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _Spoiler(this.text, this.style);

  @override
  State<_Spoiler> createState() => _SpoilerState();
}

class _SpoilerState extends State<_Spoiler> {
  bool shown = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => setState(() => shown = true),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(color: shown ? context.cs.onSurface.withValues(alpha: .08) : context.cs.onSurface.withValues(alpha: .85), borderRadius: BorderRadius.circular(4)),
          child: Text(widget.text, style: widget.style.copyWith(color: shown ? widget.style.color : Colors.transparent)),
        ),
      );
}
