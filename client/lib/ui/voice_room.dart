import 'dart:async';

import 'package:flutter/foundation.dart';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import '../voice/voice_controller.dart';
import 'common.dart';
import 'device_panel.dart';

bool get _isDesktop => !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.macOS);

/// A voice channel (full page) or the call panel embedded above a direct-message chat.
class VoiceRoom extends StatefulWidget {
  final ChannelModel channel;
  final bool menu, embedded;
  final VoidCallback onToggleMembers;
  const VoiceRoom({super.key, required this.channel, required this.menu, required this.onToggleMembers, this.embedded = false});

  @override
  State<VoiceRoom> createState() => _VoiceRoomState();
}

class _VoiceRoomState extends State<VoiceRoom> {
  String? focused;

  VoiceController get call => context.appRead.voice;

  Future<void> _share() async {
    if (call.sharing) return call.stopShare();
    final g = context.appRead.guildOfChannel(widget.channel.id);
    if (g != null && !g.can(context.appRead.myId, Perm.stream)) return context.appRead.toast('You cannot share your screen in this server.');
    if (!_isDesktop) return call.startShare();
    final picked = await showDialog<String>(context: context, builder: (_) => _SourcePicker(call: call));
    if (picked != null) await call.startShare(sourceId: picked);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final ch = widget.channel;
    final content = ListenableBuilder(
      listenable: call,
      builder: (context, _) {
        final inThis = call.channelId == ch.id;
        final room = app.voiceRooms[ch.id] ?? const <VoiceParticipant>[];
        if (!inThis) return _lobby(context, room);

        final tiles = <_Tile>[
          for (final p in {...room.map((r) => r.userId), app.myId})
            _tile(context, p, room.where((r) => r.userId == p).firstOrNull),
        ];
        final sharer = tiles.where((t) => t.renderer != null).firstOrNull;
        final focus = tiles.where((t) => t.id == focused && t.renderer != null).firstOrNull ?? sharer;
        return Column(children: [
          if (call.error != null) Padding(padding: const EdgeInsets.all(8), child: Text(call.error!, style: TextStyle(color: context.nyx.danger))),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: focus == null
                  ? _grid(tiles)
                  : Column(children: [
                      Expanded(child: _TileView(tile: focus, big: true, onTap: () => setState(() => focused = null))),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 100,
                        child: ListView(scrollDirection: Axis.horizontal, children: [
                          for (final t in tiles.where((t) => t != focus)) Padding(padding: const EdgeInsets.only(right: 8), child: SizedBox(width: 170, child: _TileView(tile: t, onTap: () => setState(() => focused = t.id)))),
                        ]),
                      ),
                    ]),
            ),
          ),
          _controls(context),
        ]);
      },
    );
    if (widget.embedded) return content;
    final other = ch.name.isEmpty ? 'Voice' : ch.name;
    return Column(children: [
      SizedBox(
        height: 56,
        child: Row(children: [
          if (widget.menu) Builder(builder: (c) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(c).openDrawer())),
          Padding(padding: EdgeInsets.only(left: widget.menu ? 0 : 18, right: 8), child: Icon(Icons.volume_up_rounded, color: context.muted)),
          Expanded(child: Text(other, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800))),
          Icon(Icons.lock, size: 15, color: context.cs.secondary),
          IconButton(icon: const Icon(Icons.people_alt_outlined), onPressed: widget.onToggleMembers),
          const SizedBox(width: 6),
        ]),
      ),
      const Divider(height: 1),
      Expanded(child: content),
    ]);
  }

  _Tile _tile(BuildContext context, String userId, VoiceParticipant? state) {
    final app = context.appRead;
    final me = userId == app.myId;
    final peer = call.peers[userId];
    final streaming = state?.streaming ?? false;
    return _Tile(
      id: userId,
      name: app.displayNameIn(userId),
      user: app.users[userId],
      speaking: me ? call.mySpeaking : (peer?.speaking ?? false),
      muted: me ? call.muted : (state?.muted ?? false),
      deaf: me ? call.deafened : (state?.deafened ?? false),
      connecting: !me && (peer == null || !peer.connected),
      me: me,
      renderer: me ? (call.sharing ? call.localScreen : null) : (streaming ? peer?.video : null),
      cam: me ? (call.camera ? call.localCam : null) : ((state?.camera ?? false) ? peer?.cam : null),
      audioOut: peer?.audioOut,
      volume: peer?.volume ?? 1,
    );
  }

  Widget _grid(List<_Tile> tiles) => LayoutBuilder(builder: (context, box) {
        final n = tiles.length;
        final cols = n <= 1 ? 1 : (n <= 4 ? 2 : (n <= 9 ? 3 : 4));
        final rows = (n / cols).ceil();
        const gap = 10.0;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        final h = (box.maxHeight - gap * (rows - 1)) / rows;
        return Center(
          child: Wrap(spacing: gap, runSpacing: gap, alignment: WrapAlignment.center, children: [
            for (final t in tiles) SizedBox(width: w.clamp(120, 560), height: h.clamp(100, 340), child: _TileView(tile: t)),
          ]),
        );
      });

  Widget _lobby(BuildContext context, List<VoiceParticipant> room) {
    final app = context.app;
    return Center(
      child: Pop(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.graphic_eq_rounded, size: 56, color: context.cs.primary),
          const SizedBox(height: 12),
          Text(widget.channel.name.isEmpty ? 'Voice' : widget.channel.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(room.isEmpty ? 'Nobody is here yet' : '${room.map((p) => app.displayNameIn(p.userId)).join(', ')} in call', style: TextStyle(color: context.muted)),
          const SizedBox(height: 20),
          FilledButton.icon(icon: const Icon(Icons.call_rounded), label: const Text('Join voice'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28)), onPressed: () => call.join(widget.channel.id)),
          const SizedBox(height: 12),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock, size: 14, color: context.cs.secondary),
            const SizedBox(width: 6),
            Flexible(child: Text('Peer-to-peer, end-to-end encrypted', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: context.faint))),
          ]),
        ]),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    Widget btn(IconData icon, String tip, VoidCallback onTap, {bool on = false, Color? color}) => Tooltip(
          message: tip,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(shape: BoxShape.circle, color: color ?? (on ? context.nyx.danger.withValues(alpha: .9) : context.cs.onSurface.withValues(alpha: .12))),
            child: IconButton(iconSize: 24, padding: const EdgeInsets.all(13), color: color != null || on ? Colors.white : null, icon: Icon(icon), onPressed: onTap),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14, top: 4),
      child: Wrap(spacing: 12, alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.timer_outlined, size: 15, color: context.muted), const SizedBox(width: 5), CallTimer(since: call.joinedAt, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.muted))])),
        btn(call.muted ? Icons.mic_off_rounded : Icons.mic_rounded, call.muted ? 'Unmute' : 'Mute', call.toggleMute, on: call.muted),
        btn(call.deafened ? Icons.headset_off_rounded : Icons.headset_rounded, call.deafened ? 'Undeafen' : 'Deafen', call.toggleDeafen, on: call.deafened),
        btn(call.camera ? Icons.videocam_rounded : Icons.videocam_off_rounded, call.camera ? 'Turn off camera' : 'Turn on camera', call.toggleCamera, color: call.camera ? context.cs.primary : null),
        btn(call.sharing ? Icons.stop_screen_share_rounded : Icons.screen_share_rounded, call.sharing ? 'Stop sharing' : 'Share screen', _share, color: call.sharing ? context.cs.primary : null),
        btn(Icons.settings_voice_rounded, 'Audio & video devices', () => showDeviceDialog(context)),
        btn(Icons.call_end_rounded, 'Leave', call.leave, color: context.nyx.danger),
      ]),
    );
  }
}

class _Tile {
  final String id, name;
  final UserModel? user;
  final bool speaking, muted, deaf, connecting, me;
  final RTCVideoRenderer? renderer, cam, audioOut;
  final double volume;
  _Tile({required this.id, required this.name, required this.user, this.speaking = false, this.muted = false, this.deaf = false, this.connecting = false, this.me = false, this.renderer, this.cam, this.audioOut, this.volume = 1});
}

class _TileView extends StatelessWidget {
  final _Tile tile;
  final bool big;
  final VoidCallback? onTap;
  const _TileView({required this.tile, this.big = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final t = tile;
    final glow = t.speaking && context.nyx.speakingGlow;
    final call = context.appRead.voice;
    return GestureDetector(
      onTap: onTap,
      onSecondaryTapDown: t.me ? null : (d) => _volume(context, d.globalPosition, call),
      onLongPressStart: t.me ? null : (d) => _volume(context, d.globalPosition, call),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: cs.surface.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(context.nyx.radius),
          border: Border.all(color: t.speaking ? cs.secondary : Colors.white.withValues(alpha: .06), width: t.speaking ? 3 : 1),
          boxShadow: glow ? [BoxShadow(color: cs.secondary.withValues(alpha: .45), blurRadius: 22)] : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(fit: StackFit.expand, children: [
          if (t.audioOut != null) Opacity(opacity: 0, child: SizedBox(width: 1, height: 1, child: RTCVideoView(t.audioOut!))),
          if ((big || t.cam == null) && t.renderer != null)
            RTCVideoView(t.renderer!, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
          else if (t.cam != null)
            RTCVideoView(t.cam!, mirror: t.me, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          else
            Center(child: UserAvatar(t.user, size: big ? 96 : 64, hoverToPlay: false)),
          Positioned(
            left: 10,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (t.muted || t.deaf) ...[Icon(t.deaf ? Icons.headset_off_rounded : Icons.mic_off_rounded, size: 14, color: Colors.redAccent), const SizedBox(width: 4)],
                Text(t.me ? '${t.name} (you)' : t.name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                if (t.connecting && !t.me) const Padding(padding: EdgeInsets.only(left: 6), child: SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70))),
              ]),
            ),
          ),
          if (t.renderer != null) Positioned(right: 10, top: 10, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: context.nyx.danger, borderRadius: BorderRadius.circular(6)), child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)))),
        ]),
      ),
    );
  }

  Future<void> _volume(BuildContext context, Offset pos, VoiceController call) async {
    var v = tile.volume;
    await showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (c) => Stack(children: [
        Positioned(
          left: (pos.dx - 110).clamp(8, MediaQuery.sizeOf(c).width - 240),
          top: pos.dy,
          child: Material(
            elevation: 10,
            borderRadius: BorderRadius.circular(14),
            color: c.cs.surface,
            child: StatefulBuilder(
              builder: (c, set) => SizedBox(
                width: 230,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${tile.name}\'s volume', style: const TextStyle(fontWeight: FontWeight.w700)),
                    Slider(value: v.clamp(0, 2), min: 0, max: 2, divisions: 20, label: '${(v * 100).round()}%', onChanged: (x) {
                      set(() => v = x);
                      call.setPeerVolume(tile.id, x);
                    }),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _SourcePicker extends StatefulWidget {
  final VoiceController call;
  const _SourcePicker({required this.call});

  @override
  State<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends State<_SourcePicker> {
  List<DesktopCapturerSource> sources = [];
  String? selected;

  @override
  void initState() {
    super.initState();
    desktopCapturer.getSources(types: [SourceType.Screen, SourceType.Window], thumbnailSize: ThumbnailSize(320, 180)).then((s) => mounted ? setState(() => sources = s) : null);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            const Align(alignment: Alignment.centerLeft, child: Text('Share your screen', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
            const SizedBox(height: 12),
            Expanded(
              child: sources.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : GridView.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, childAspectRatio: 1.4, mainAxisSpacing: 10, crossAxisSpacing: 10),
                      itemCount: sources.length,
                      itemBuilder: (_, i) {
                        final s = sources[i];
                        final sel = selected == s.id;
                        return InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => setState(() => selected = s.id),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: sel ? cs.primary : Colors.transparent, width: 2), color: cs.onSurface.withValues(alpha: .06)),
                            child: Column(children: [
                              Expanded(child: s.thumbnail == null ? const SizedBox() : ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(s.thumbnail!, fit: BoxFit.contain, gaplessPlayback: true))),
                              const SizedBox(height: 4),
                              Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [for (final q in ShareQuality.values) ChoiceChip(label: Text(q.label), selected: widget.call.quality == q, onSelected: (_) => setState(() => widget.call.setQuality(q)))]),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: selected == null ? null : () => Navigator.pop(context, selected), child: const Text('Share')),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Elapsed time in the current call, ticking once a second.
class CallTimer extends StatefulWidget {
  final DateTime? since;
  final TextStyle? style;
  const CallTimer({super.key, required this.since, this.style});

  @override
  State<CallTimer> createState() => _CallTimerState();
}

class _CallTimerState extends State<CallTimer> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final since = widget.since;
    final d = since == null ? Duration.zero : DateTime.now().difference(since);
    String two(int n) => n.toString().padLeft(2, '0');
    final txt = d.inHours > 0 ? '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}' : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
    return Text(txt, style: (widget.style ?? const TextStyle(fontSize: 12)).copyWith(fontFeatures: const [FontFeature.tabularFigures()]));
  }
}
