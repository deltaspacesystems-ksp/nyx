import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/crypto.dart';
import '../state/app_state.dart';

/// One WebRTC connection to another participant.
///
/// Both sides pre-create an audio and a video transceiver, so connecting needs exactly one offer/answer and
/// starting/stopping a screen share is just `replaceTrack` (no renegotiation, no glare). Only the peer with
/// the larger user id sends the offer.
class VoicePeer {
  final String userId;
  final RTCPeerConnection pc;
  late final RTCRtpTransceiver audioTx, videoTx, camTx;
  final audioOut = RTCVideoRenderer(); // renders remote audio (needed on web, harmless on native)
  final video = RTCVideoRenderer(); // their screen share
  final cam = RTCVideoRenderer(); // their camera
  MediaStreamTrack? audioTrack;
  RTCPeerConnectionState state = RTCPeerConnectionState.RTCPeerConnectionStateNew;
  bool remoteDescSet = false, offered = false, speaking = false;
  final pendingIce = <RTCIceCandidate>[];
  double volume = 1.0;
  MediaStream? videoStream;
  bool wasStreaming = false, wasCamera = false;
  MediaStream? camStream;
  int lastFrames = -1, stalled = 0, retries = 0;

  bool get connected => state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;

  VoicePeer(this.userId, this.pc);

  Future<void> dispose() async {
    try {
      audioOut.srcObject = null;
      video.srcObject = null;
      cam.srcObject = null;
      await audioOut.dispose();
      await video.dispose();
      await cam.dispose();
      await pc.close();
    } catch (_) {}
  }
}

enum ShareQuality {
  p720x30('720p · 30 fps', 30, 3000000),
  p1080x30('1080p · 30 fps', 30, 6000000),
  p1080x60('1080p · 60 fps', 60, 10000000);

  final String label;
  final int fps, bitrate;
  const ShareQuality(this.label, this.fps, this.bitrate);
}

class VoiceController extends ChangeNotifier {
  final AppState app;
  VoiceController(this.app);

  String? channelId;
  bool muted = false, deafened = false, sharing = false, mySpeaking = false;
  String? error;
  final peers = <String, VoicePeer>{};
  final _creating = <String, Future<VoicePeer>>{};
  List<Map<String, dynamic>> _ice = [];
  MediaStream? _mic, _screen, _cam, _msidStream, _camMsid;
  final localScreen = RTCVideoRenderer();
  final localCam = RTCVideoRenderer();
  bool camera = false;
  /// Chosen devices (null = system default), remembered between sessions.
  String? micId, outId, camId;
  bool _prefsLoaded = false;
  bool _localScreenReady = false;
  Timer? _stats;
  ShareQuality quality = ShareQuality.p1080x30;
  DateTime? joinedAt;

  void setQuality(ShareQuality q) {
    quality = q;
    notifyListeners();
  }

  bool get inCall => channelId != null;

  Future<void> loadPrefs() async {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      micId = sp.getString('nyx.dev.mic');
      outId = sp.getString('nyx.dev.out');
      camId = sp.getString('nyx.dev.cam');
    } catch (_) {}
  }

  Future<void> _savePref(String key, String? v) async {
    try {
      final sp = await SharedPreferences.getInstance();
      v == null ? await sp.remove(key) : await sp.setString(key, v);
    } catch (_) {}
  }

  /// Inputs, outputs and cameras the system currently offers (labels appear once permission was granted).
  Future<Map<String, List<MediaDeviceInfo>>> devices() async {
    List<MediaDeviceInfo> all = [];
    try {
      all = await navigator.mediaDevices.enumerateDevices();
    } catch (_) {}
    List<MediaDeviceInfo> of(String kind) => [for (final d in all) if (d.kind == kind && d.deviceId.isNotEmpty) d];
    return {'mics': of('audioinput'), 'outs': of('audiooutput'), 'cams': of('videoinput')};
  }

  Future<MediaStream> _openMic() => navigator.mediaDevices.getUserMedia({
        'audio': {
          if (micId != null) 'deviceId': {'exact': micId},
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });

  /// Switches the microphone, also while in a call (the new track replaces the old one on every connection).
  Future<void> setMic(String? id) async {
    micId = id;
    await _savePref('nyx.dev.mic', id);
    if (_mic != null) {
      try {
        final old = _mic!;
        MediaStream fresh;
        try {
          fresh = await _openMic();
        } catch (_) {
          micId = null; // the chosen device vanished: fall back to the default one
          fresh = await _openMic();
        }
        final track = fresh.getAudioTracks().first;
        track.enabled = !muted && !deafened;
        for (final p in peers.values) {
          await p.audioTx.sender.replaceTrack(track);
        }
        _mic = fresh;
        for (final t in old.getTracks()) {
          await t.stop();
        }
        await old.dispose();
        error = null;
      } catch (_) {
        error = 'Could not switch the microphone.';
      }
    }
    notifyListeners();
  }

  Future<void> setOutput(String? id) async {
    outId = id;
    await _savePref('nyx.dev.out', id);
    await _applyOutput();
    notifyListeners();
  }

  Future<void> _applyOutput() async {
    final id = outId;
    if (id == null) return;
    try {
      if (kIsWeb) {
        for (final p in peers.values) {
          await p.audioOut.audioOutput(id);
        }
      } else {
        await Helper.selectAudioOutput(id);
      }
    } catch (e) {
      debugPrint('select output failed: $e');
    }
  }

  Future<void> setCameraDevice(String? id) async {
    camId = id;
    await _savePref('nyx.dev.cam', id);
    if (camera) {
      await stopCamera();
      await startCamera();
    }
    notifyListeners();
  }
  String get _me => app.myId;

  // ------------------------------------------------------------------ join/leave

  Future<void> join(String channel) async {
    if (channelId == channel) return;
    if (channelId != null) await leave();
    error = null;
    channelId = channel;
    notifyListeners();
    try {
      final rtc = await app.api.get('/api/rtc') as Map;
      _ice = (rtc['iceServers'] as List).cast<Map<String, dynamic>>();
    } catch (_) {
      _ice = [
        {'urls': ['stun:stun.l.google.com:19302']}
      ];
    }
    try {
      await loadPrefs();
      try {
        _mic = await _openMic();
      } catch (_) {
        if (micId == null) rethrow;
        micId = null; // the remembered microphone is gone: use the default one
        _mic = await _openMic();
      }
      for (final t in _mic!.getAudioTracks()) {
        t.enabled = !muted && !deafened;
      }
    } catch (_) {
      error = 'Microphone unavailable, you can still listen.';
    }
    _msidStream = await createLocalMediaStream('nyx-screen-$_me');
    _camMsid = await createLocalMediaStream('nyx-cam-$_me');
    if (!_localScreenReady) {
      await localScreen.initialize();
      await localCam.initialize();
      _localScreenReady = true;
    }
    _applyOutput();
    _stats = Timer.periodic(const Duration(milliseconds: 350), (_) => _pollLevels());
    try {
      await app.hub.invoke('JoinVoice', [channel]);
      joinedAt = DateTime.now();
    } catch (e) {
      error = e.toString();
      await leave();
    }
    notifyListeners();
  }

  Future<void> leave() async {
    final ch = channelId;
    _stats?.cancel();
    if (sharing) await stopShare(notify: false);
    if (camera) await stopCamera(notify: false);
    for (final p in peers.values) {
      await p.dispose();
    }
    peers.clear();
    _creating.clear();
    for (final t in _mic?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _mic?.dispose();
    _mic = null;
    channelId = null;
    joinedAt = null;
    mySpeaking = false;
    notifyListeners();
    if (ch != null) {
      try {
        await app.hub.invoke('LeaveVoice');
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------- hub callbacks

  void onRoomState(String channel) {
    if (channel != channelId) return;
    // A share that just started often leaves the remote renderer on a stale (black) surface: rebind it.
    for (final p in peers.values) {
      final now = app.voiceRooms[channel]?.where((x) => x.userId == p.userId).firstOrNull?.streaming ?? false;
      if (now && !p.wasStreaming) {
        p.retries = 0;
        p.lastFrames = -1;
        p.stalled = 0;
        _rebind(p);
      }
      p.wasStreaming = now;
      final cam = app.voiceRooms[channel]?.where((x) => x.userId == p.userId).firstOrNull?.camera ?? false;
      if (cam && !p.wasCamera) _rebindCam(p);
      p.wasCamera = cam;
    }
    notifyListeners();
  }

  Future<void> _rebind(VoicePeer p) async {
    final s = p.videoStream;
    if (s == null) return;
    try {
      p.video.srcObject = null;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (peers[p.userId] != p) return;
      p.video.srcObject = s;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _rebindCam(VoicePeer p) async {
    final s = p.camStream;
    if (s == null) return;
    try {
      p.cam.srcObject = null;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (peers[p.userId] != p) return;
      p.cam.srcObject = s;
    } catch (_) {}
    notifyListeners();
  }

  /// Hub callbacks are fire-and-forget, so failures are surfaced in the UI instead of vanishing.
  Future<void> _guard(String what, Future<void> Function() body) async {
    try {
      await body();
    } catch (e, st) {
      debugPrint('voice $what failed: $e\n$st');
      error = 'Call problem ($what): $e';
      notifyListeners();
    }
  }

  Future<void> onParticipants(String channel, List<String> ids) => _guard('participants', () async {
        if (channel != channelId) return;
        for (final id in ids.where((i) => i != _me)) {
          await _connectTo(id);
        }
      });

  Future<void> onJoined(String channel, String user) => _guard('join', () async {
        if (channel != channelId || user == _me) return;
        await _connectTo(user);
      });

  Future<void> onLeft(String channel, String user) async {
    if (channel != channelId) return;
    _creating.remove(user);
    final p = peers.remove(user);
    await p?.dispose();
    notifyListeners();
  }

  Future<void> _connectTo(String user) async {
    final p = await _peer(user);
    // Deterministic caller avoids simultaneous offers.
    if (_me.compareTo(user) > 0 && !p.offered && !p.remoteDescSet) await _offer(p);
  }

  Future<void> onSignal(String from, String channel, String payload) async {
    if (channel != channelId) return;
    final key = app.currentKey(channel);
    final sender = app.users[from];
    if (key == null || sender == null) return;
    final c = await NyxCrypto.decryptSignal(channelKey: key, channelId: channel, senderEdPublicKey: sender.edPublic, ciphertext: payload);
    if (c == null) return; // forged or corrupt
    try {
      switch (c['t']) {
        case 'offer':
          final p = await _peer(from);
          await p.pc.setRemoteDescription(RTCSessionDescription(c['sdp'], c['type']));
          p.remoteDescSet = true;
          await _flushIce(p);
          final answer = await p.pc.createAnswer();
          await p.pc.setLocalDescription(answer);
          await _send(from, {'t': 'answer', 'sdp': answer.sdp, 'type': answer.type});
        case 'answer':
          final p = peers[from];
          if (p == null) return;
          await p.pc.setRemoteDescription(RTCSessionDescription(c['sdp'], c['type']));
          p.remoteDescSet = true;
          await _flushIce(p);
        case 'ice':
          final p = await _peer(from);
          final m = c['c'] as Map;
          final cand = RTCIceCandidate(m['candidate'], m['sdpMid'], m['sdpMLineIndex']);
          p.remoteDescSet ? await p.pc.addCandidate(cand) : p.pendingIce.add(cand);
      }
    } catch (e) {
      debugPrint('signal error: $e');
    }
  }

  Future<void> _flushIce(VoicePeer p) async {
    for (final c in p.pendingIce) {
      await p.pc.addCandidate(c);
    }
    p.pendingIce.clear();
  }

  // ---------------------------------------------------------------- peers

  Future<VoicePeer> _peer(String user) => peers[user] != null
      ? Future.value(peers[user]!)
      : _creating[user] ??= _createPeer(user).whenComplete(() {
          // Block body on purpose: returning the removed Future would make it await itself.
          _creating.remove(user);
        });

  Future<VoicePeer> _createPeer(String user) async {
    final pc = await createPeerConnection({'iceServers': _ice, 'sdpSemantics': 'unified-plan'});
    final p = VoicePeer(user, pc);
    await p.audioOut.initialize();
    await p.video.initialize();
    await p.cam.initialize();

    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _send(user, {
        't': 'ice',
        'c': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex}
      });
    };
    pc.onTrack = (e) async {
      final stream = e.streams.isNotEmpty ? e.streams.first : null;
      if (e.track.kind == 'audio') {
        p.audioTrack = e.track;
        e.track.enabled = !deafened;
        if (stream != null) p.audioOut.srcObject = stream;
      } else if (stream != null) {
        // Two video transceivers exist on every connection: the first carries the screen, the second the camera.
        if (await _isCameraTrack(pc, e)) {
          p.camStream = stream;
          p.cam.srcObject = stream;
        } else {
          p.videoStream = stream;
          p.video.srcObject = stream;
        }
      }
      notifyListeners();
    };
    pc.onConnectionState = (s) {
      p.state = s;
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed && _me.compareTo(user) > 0) _iceRestart(p);
      notifyListeners();
    };

    final micTrack = _mic?.getAudioTracks().firstOrNull;
    p.audioTx = await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [?_mic]),
    );
    if (micTrack != null) await p.audioTx.sender.replaceTrack(micTrack);
    p.videoTx = await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [_msidStream!]),
    );
    p.camTx = await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [_camMsid!]),
    );
    final screenTrack = _screen?.getVideoTracks().firstOrNull;
    if (screenTrack != null) {
      await p.videoTx.sender.replaceTrack(screenTrack);
      await _tune(p.videoTx, quality.bitrate, quality.fps);
    }
    final camTrack = _cam?.getVideoTracks().firstOrNull;
    if (camTrack != null) {
      await p.camTx.sender.replaceTrack(camTrack);
      await _tune(p.camTx, _camBitrate, 30);
    }
    peers[user] = p;
    notifyListeners();
    return p;
  }

  static const _camBitrate = 1500000;

  /// Transceivers keep their creation order on both ends, so the second video one is the camera.
  Future<bool> _isCameraTrack(RTCPeerConnection pc, RTCTrackEvent e) async {
    try {
      final videos = [for (final t in await pc.getTransceivers()) if (t.receiver.track?.kind == 'video') t];
      final i = videos.indexWhere((t) => t.receiver.track?.id == e.track.id);
      if (i >= 0) return i == 1;
    } catch (_) {}
    return e.streams.firstOrNull?.id.contains('cam') ?? false;
  }

  Future<void> _offer(VoicePeer p, {bool iceRestart = false}) async {
    p.offered = true;
    final offer = await p.pc.createOffer(iceRestart ? {'iceRestart': true} : {});
    await p.pc.setLocalDescription(offer);
    p.remoteDescSet = false;
    await _send(p.userId, {'t': 'offer', 'sdp': offer.sdp, 'type': offer.type});
  }

  Future<void> _iceRestart(VoicePeer p) async {
    try {
      await _offer(p, iceRestart: true);
    } catch (_) {}
  }

  Future<void> _send(String to, Map<String, dynamic> content) async {
    final ch = channelId;
    final key = ch == null ? null : app.currentKey(ch);
    if (ch == null || key == null) return;
    final ct = await NyxCrypto.encryptSignal(channelKey: key, channelId: ch, sender: app.identity!, content: content);
    await app.hub.invoke('Signal', [to, ch, ct]);
  }

  // ------------------------------------------------------------------ controls

  void _pushState() => app.hub.invoke('SetVoiceState', [muted, deafened, sharing]).catchError((_) => null);

  void toggleMute() {
    muted = !muted;
    if (!muted && deafened) deafened = false;
    _applyAudioState();
  }

  void toggleDeafen() {
    deafened = !deafened;
    _applyAudioState();
  }

  void _applyAudioState() {
    for (final t in _mic?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted && !deafened;
    }
    for (final p in peers.values) {
      p.audioTrack?.enabled = !deafened;
    }
    notifyListeners();
    _pushState();
  }

  void setPeerVolume(String user, double v) {
    final p = peers[user];
    if (p == null) return;
    p.volume = v;
    try {
      Helper.setVolume(v, p.audioTrack!);
    } catch (_) {}
    notifyListeners();
  }

  /// [sourceId] is only used on desktop (chosen in the picker); on web the browser shows its own picker.
  Future<void> startShare({String? sourceId}) async {
    if (sharing || !inCall) return;
    try {
      final constraints = sourceId == null
          ? {'video': {'frameRate': quality.fps}, 'audio': false}
          : {
              'video': {
                'deviceId': {'exact': sourceId},
                'mandatory': {'frameRate': quality.fps.toDouble()},
              },
              'audio': false,
            };
      _screen = await navigator.mediaDevices.getDisplayMedia(constraints);
    } catch (e) {
      error = 'Could not start screen share.';
      notifyListeners();
      return;
    }
    final track = _screen!.getVideoTracks().first;
    track.onEnded = () => stopShare();
    localScreen.srcObject = _screen;
    sharing = true;
    for (final p in peers.values) {
      await p.videoTx.sender.replaceTrack(track);
      await _tune(p.videoTx, quality.bitrate, quality.fps);
    }
    notifyListeners();
    _pushState();
  }

  Future<void> stopShare({bool notify = true}) async {
    if (!sharing) return;
    sharing = false;
    for (final p in peers.values) {
      try {
        await p.videoTx.sender.replaceTrack(null);
      } catch (_) {}
    }
    for (final t in _screen?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _screen?.dispose();
    _screen = null;
    localScreen.srcObject = null;
    if (notify) {
      notifyListeners();
      _pushState();
    }
  }

  Future<void> _tune(RTCRtpTransceiver tx, int bitrate, int fps) async {
    try {
      final params = tx.sender.parameters;
      final enc = params.encodings;
      if (enc != null && enc.isNotEmpty) {
        enc[0].maxBitrate = bitrate;
        enc[0].maxFramerate = fps;
        await tx.sender.setParameters(params);
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------------ camera

  Future<void> toggleCamera() => camera ? stopCamera() : startCamera();

  Future<void> startCamera() async {
    if (camera || !inCall) return;
    try {
      Future<MediaStream> open(bool useId) => navigator.mediaDevices.getUserMedia({
            'audio': false,
            'video': {
              if (useId && camId != null) 'deviceId': {'exact': camId} else 'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
              'frameRate': {'ideal': 30},
            },
          });
      try {
        _cam = await open(true);
      } catch (_) {
        if (camId == null) rethrow;
        camId = null;
        _cam = await open(false);
      }
    } catch (_) {
      error = 'Camera unavailable.';
      notifyListeners();
      return;
    }
    final track = _cam!.getVideoTracks().first;
    track.onEnded = () => stopCamera();
    localCam.srcObject = _cam;
    camera = true;
    for (final p in peers.values) {
      await p.camTx.sender.replaceTrack(track);
      await _tune(p.camTx, _camBitrate, 30);
    }
    notifyListeners();
    app.hub.invoke('SetVoiceCamera', [true]).catchError((_) => null);
  }

  Future<void> stopCamera({bool notify = true}) async {
    if (!camera) return;
    camera = false;
    for (final p in peers.values) {
      try {
        await p.camTx.sender.replaceTrack(null);
      } catch (_) {}
    }
    for (final t in _cam?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _cam?.dispose();
    _cam = null;
    localCam.srcObject = null;
    if (notify) {
      notifyListeners();
      app.hub.invoke('SetVoiceCamera', [false]).catchError((_) => null);
    }
  }

  // ------------------------------------------------------------ speaking level

  bool _polling = false;
  Future<void> _pollLevels() async {
    if (_polling) return;
    _polling = true;
    var changed = false;
    try {
      double? local;
      for (final p in peers.values) {
        if (!p.connected) continue;
        double? remote;
        int? frames;
        for (final r in await p.pc.getStats()) {
          final kind = r.values['kind'] ?? r.values['mediaType'];
          if (kind == 'video' && r.type == 'inbound-rtp') frames = (r.values['framesDecoded'] as num?)?.toInt();
          if (kind != 'audio') continue;
          final lvl = (r.values['audioLevel'] as num?)?.toDouble();
          if (lvl == null) continue;
          if (r.type == 'inbound-rtp') remote = lvl;
          if (r.type == 'media-source') local = lvl;
        }
        if (p.wasStreaming && frames != null) {
          if (frames == p.lastFrames) {
            // Frames are arriving (or not) but nothing is shown: after ~2 s of no progress re-attach the stream.
            if (++p.stalled >= 6 && p.retries < 3) {
              p.stalled = 0;
              p.retries++;
              _rebind(p);
            }
          } else {
            p.stalled = 0;
          }
          p.lastFrames = frames;
        }
        final muted = app.voiceRooms[channelId]?.where((x) => x.userId == p.userId).firstOrNull?.muted ?? false;
        final s = (remote ?? 0) > .02 && !muted;
        if (s != p.speaking) {
          p.speaking = s;
          changed = true;
        }
      }
      final me = (local ?? 0) > .02 && !muted && !deafened;
      if (me != mySpeaking) {
        mySpeaking = me;
        changed = true;
      }
    } catch (_) {}
    _polling = false;
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _stats?.cancel();
    super.dispose();
  }
}
