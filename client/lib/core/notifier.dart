import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'taskbar_stub.dart' if (dart.library.io) 'taskbar_io.dart';

/// System notifications, sounds, taskbar flashing and per-channel mute. Everything is local: the message
/// is decrypted on this device and only then shown, so the notification service never sees the content.
class Notifier extends ChangeNotifier {
  Notifier._();
  static final instance = Notifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _player = AudioPlayer();
  bool _ready = false, _flashing = false;
  int _id = 0;
  void Function(String channelId)? onOpenChannel;

  /// Person-chosen options (persisted).
  bool desktop = true, sounds = true, flash = true, allMessages = false;
  final muted = <String>{};

  bool get _native => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    try {
      final sp = await SharedPreferences.getInstance();
      desktop = sp.getBool('nyx.n.desktop') ?? true;
      sounds = sp.getBool('nyx.n.sounds') ?? true;
      flash = sp.getBool('nyx.n.flash') ?? true;
      allMessages = sp.getBool('nyx.n.all') ?? false;
      muted.addAll(sp.getStringList('nyx.n.muted') ?? const []);
    } catch (_) {}
    if (!_native) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(appName: 'Nyx', appUserModelId: 'eu.deltatechksp.nyx', guid: 'b7d2f6a0-53c1-4a44-9c3e-6b7a9d5e2f10'),
        ),
        onDidReceiveNotificationResponse: (r) {
          final id = r.payload;
          if (id != null && id.isNotEmpty) onOpenChannel?.call(id);
        },
      );
      if (Platform.isAndroid) {
        await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      }
    } catch (e) {
      debugPrint('notifications unavailable: $e');
    }
  }

  Future<void> _save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('nyx.n.desktop', desktop);
      await sp.setBool('nyx.n.sounds', sounds);
      await sp.setBool('nyx.n.flash', flash);
      await sp.setBool('nyx.n.all', allMessages);
      await sp.setStringList('nyx.n.muted', muted.toList());
    } catch (_) {}
  }

  void update({bool? desktop, bool? sounds, bool? flash, bool? allMessages}) {
    this.desktop = desktop ?? this.desktop;
    this.sounds = sounds ?? this.sounds;
    this.flash = flash ?? this.flash;
    this.allMessages = allMessages ?? this.allMessages;
    notifyListeners();
    _save();
  }

  bool isMuted(String channelId) => muted.contains(channelId);

  void toggleMute(String channelId) {
    muted.contains(channelId) ? muted.remove(channelId) : muted.add(channelId);
    notifyListeners();
    _save();
  }

  Future<void> playSound(String name) async {
    if (!sounds) return;
    try {
      await _player.stop();
      await _player.setVolume(.7);
      await _player.play(AssetSource('sounds/$name.wav'));
    } catch (_) {}
  }

  /// Called for a message in a channel the person is not looking at. [ping] = direct message or @mention.
  Future<void> message({required String channelId, required String title, required String body, required bool ping, required bool appFocused}) async {
    if (isMuted(channelId)) return;
    if (!ping && !allMessages) return;
    await playSound(ping ? 'mention' : 'message');
    if (appFocused) return; // the sound is enough while the window is in front
    if (flash) {
      _flashing = true;
      flashTaskbar(true);
    }
    if (!desktop || !_native) return;
    try {
      await _plugin.show(
        _id++ & 0x7fffffff,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails('messages', 'Messages', importance: Importance.high, priority: Priority.high),
          iOS: DarwinNotificationDetails(presentSound: false),
          macOS: DarwinNotificationDetails(presentSound: false),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
        payload: channelId,
      );
    } catch (e) {
      debugPrint('notification failed: $e');
    }
  }

  /// The window came to the front: stop flashing.
  void focused() {
    if (_flashing) {
      _flashing = false;
      flashTaskbar(false);
    }
  }
}
