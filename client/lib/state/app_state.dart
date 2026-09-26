import 'dart:async';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api.dart';
import '../core/crypto.dart';
import '../core/files.dart';
import '../core/gifs.dart';
import '../core/hub.dart';
import '../core/media.dart';
import '../core/discord_rpc_stub.dart' if (dart.library.io) '../core/discord_rpc_io.dart';
import '../core/models.dart';
import '../core/notifier.dart';
import '../voice/voice_controller.dart';

const defaultServer = 'https://nyx.deltatechksp.eu';

String newUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int from, int to) => b.sublist(from, to).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

class VoiceParticipant {
  final String userId;
  final bool muted, deafened, streaming, camera;
  VoiceParticipant(this.userId, this.muted, this.deafened, this.streaming, [this.camera = false]);
}

/// Everything the UI shows, and every action the UI can take. Talks to the server, decrypts what comes
/// back, and keeps the keys. One instance for the whole app.
class AppState extends ChangeNotifier {
  static const _store = FlutterSecureStorage();

  late NyxApi api;
  late HubClient hub;
  late final VoiceController voice = VoiceController(this);
  late final MediaCache media = MediaCache(() => api);

  Identity? identity;
  UserModel? me;
  bool isInstanceAdmin = false, totpEnabled = false;
  bool ready = false, bootstrapping = false;
  String? notice;

  final users = <String, UserModel>{};
  final guilds = <String, GuildModel>{};
  final dms = <String, ChannelModel>{};

  /// Friends, requests and blocked people (ids of users).
  final friends = <String>{}, incomingFriends = <String>{}, outgoingFriends = <String>{}, blockedUsers = <String>{};

  /// Home shows the friends page instead of a conversation.
  bool friendsView = true;
  final messages = <String, List<MessageModel>>{};
  final hasMoreHistory = <String, bool>{};
  final lastRead = <String, int>{};
  final lastMsg = <String, int>{};
  final mentionCount = <String, int>{};
  final typing = <String, Map<String, Timer>>{};
  final voiceRooms = <String, List<VoiceParticipant>>{};

  final _keys = <String, Map<int, SecretKey>>{};
  final _profileKeys = <String, SecretKey>{};

  String? guildId; // null = Home (direct messages)
  String? channelId;
  String myPresence = 'online';

  // ---- activity ("Playing ...")
  Map<String, dynamic>? manualActivity, _rpcActivity;
  bool rpcEnabled = true;
  final _rpc = DiscordRpcBridge();
  bool get rpcSupported => _rpc.supported;
  String? get rpcPipe => _rpc.pipeName;

  /// Manual wins over whatever a game reports through the Discord-compatible pipe.
  Map<String, dynamic>? get myActivity => manualActivity ?? _rpcActivity;

  Future<void> _pushActivity() async {
    final a = myActivity;
    users[myId]?.activity = a;
    notifyListeners();
    try {
      await hub.invoke('SetActivity', [a?['name'], a?['details'], a?['state']]);
    } catch (_) {}
  }

  Future<void> setManualActivity(String? name, {String? details}) async {
    manualActivity = (name == null || name.trim().isEmpty) ? null : {'name': name.trim(), if (details != null && details.trim().isNotEmpty) 'details': details.trim()};
    await _pushActivity();
  }

  Future<void> setRpcEnabled(bool v) async {
    rpcEnabled = v;
    try {
      (await SharedPreferences.getInstance()).setBool('nyx.rpc', v);
    } catch (_) {}
    if (v) {
      await _startRpc();
    } else {
      _rpc.stop();
      _rpcActivity = null;
      await _pushActivity();
    }
    notifyListeners();
  }

  Future<void> _startRpc() async {
    if (!_rpc.supported || _rpc.running) return;
    await _rpc.start((a) {
      _rpcActivity = a;
      _pushActivity();
    });
  }

  bool get signedIn => me != null && identity != null;
  String get myId => me!.id;
  String get server => api.baseUrl;

  GuildModel? get guild => guildId == null ? null : guilds[guildId];
  ChannelModel? get channel => channelId == null ? null : channelById(channelId!);
  List<MessageModel> get currentMessages => messages[channelId] ?? const [];

  ChannelModel? channelById(String id) {
    if (dms.containsKey(id)) return dms[id];
    for (final g in guilds.values) {
      if (g.channels.containsKey(id)) return g.channels[id];
    }
    return null;
  }

  GuildModel? guildOfChannel(String id) {
    for (final g in guilds.values) {
      if (g.channels.containsKey(id)) return g;
    }
    return null;
  }

  void toast(String message) {
    notice = message;
    notifyListeners();
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }

  // ================================================================= start / auth

  Future<void> init() async {
    Notifier.instance.onOpenChannel = openChannel;
    Notifier.instance.init();
    try {
      rpcEnabled = (await SharedPreferences.getInstance()).getBool('nyx.rpc') ?? true;
    } catch (_) {}
    if (rpcEnabled) _startRpc();
    final server = await _store.read(key: 'server') ?? (kIsWeb ? Uri.base.origin : defaultServer);
    api = NyxApi(server, accessToken: await _store.read(key: 'access'), refreshToken: await _store.read(key: 'refresh'));
    _wireApi();
    final ed = await _store.read(key: 'ed'), x = await _store.read(key: 'x'), p = await _store.read(key: 'p');
    if (api.refreshToken != null && ed != null && x != null && p != null) {
      try {
        identity = await Identity.fromSeeds(NyxCrypto.unb64(ed), NyxCrypto.unb64(x), NyxCrypto.unb64(p));
        await _enter();
      } catch (e) {
        if (e is ApiException && (e.status == 401)) {
          await _wipe();
        } else if (me == null) {
          identity = null; // offline: stay on the login screen but keep the stored session
        }
      }
    }
    ready = true;
    notifyListeners();
  }

  void _wireApi() {
    api.onTokens = (a, r) {
      _store.write(key: 'access', value: a);
      _store.write(key: 'refresh', value: r);
    };
    api.onSessionLost = () {
      _wipe();
      toast('You were signed out. Please log in again.');
    };
    hub = HubClient(api);
    _wireHub();
  }

  Future<void> _wipe() async {
    await hub.stop();
    for (final k in ['access', 'refresh', 'ed', 'x', 'p']) {
      await _store.delete(key: k);
    }
    api.accessToken = api.refreshToken = null;
    identity = null;
    me = null;
    users.clear();
    guilds.clear();
    dms.clear();
    messages.clear();
    _keys.clear();
    _profileKeys.clear();
    guildId = channelId = null;
    friends.clear();
    incomingFriends.clear();
    outgoingFriends.clear();
    blockedUsers.clear();
    friendsView = true;
    GifLibrary.instance.clear();
    notifyListeners();
  }

  Future<void> signOut() async {
    try {
      await voice.leave();
      await api.post('/api/auth/logout');
    } catch (_) {}
    await _wipe();
  }

  Future<void> _persistSession(String server, Identity id) async {
    await _store.write(key: 'server', value: server);
    await _store.write(key: 'ed', value: NyxCrypto.b64(id.edSeed));
    await _store.write(key: 'x', value: NyxCrypto.b64(id.xSeed));
    await _store.write(key: 'p', value: NyxCrypto.b64(id.profileKeyBytes));
    await _store.write(key: 'access', value: api.accessToken);
    await _store.write(key: 'refresh', value: api.refreshToken);
  }

  Future<void> register({
    required String server,
    required String username,
    required String displayName,
    required String password,
    required String invite,
  }) async {
    api.baseUrl = server;
    final salt = NyxCrypto.newSalt();
    final k = await NyxCrypto.deriveFromPassword(password, salt);
    final id = await NyxCrypto.generateIdentity();
    final res = await api.anon('POST', '/api/auth/register', body: {
      'username': username,
      'displayName': displayName,
      'kdfSalt': salt,
      'authKey': k.authKey,
      'identityPublicKey': id.edPublic,
      'agreementPublicKey': id.xPublic,
      'encryptedKeyBackup': await NyxCrypto.exportBackup(id, k.wrappingKey),
      'inviteCode': invite,
    });
    identity = id;
    api.setTokens(res['accessToken'], res['refreshToken']);
    await _persistSession(server, id);
    await _enter();
  }

  Future<void> login({required String server, required String username, required String password, String? totp, String? recoveryCode}) async {
    api.baseUrl = server;
    final salt = (await api.anon('GET', '/api/auth/salt', query: {'username': username}))['salt'] as String;
    final k = await NyxCrypto.deriveFromPassword(password, salt);
    final res = await api.anon('POST', '/api/auth/login', body: {
      'username': username,
      'authKey': k.authKey,
      if (totp != null && totp.isNotEmpty) 'totp': totp,
      if (recoveryCode != null && recoveryCode.isNotEmpty) 'recoveryCode': recoveryCode,
    });
    final id = await NyxCrypto.importBackup(res['encryptedKeyBackup'], k.wrappingKey);
    identity = id;
    api.setTokens(res['accessToken'], res['refreshToken']);
    await _persistSession(server, id);
    await _enter();
  }

  Future<void> _enter() async {
    await _bootstrap();
    await hub.start();
  }

  // ============================================================== bootstrap / sync

  Future<void> refresh() => _bootstrap();

  Timer? _resyncTimer;

  /// Many events just mean "something changed": refetch everything shortly after (cheap at this scale).
  void scheduleResync([Duration after = const Duration(milliseconds: 300)]) {
    _resyncTimer?.cancel();
    _resyncTimer = Timer(after, () => _bootstrap().catchError((_) {}));
  }

  Future<void> _bootstrap() async {
    if (bootstrapping) return;
    bootstrapping = true;
    try {
      final j = await api.get('/api/bootstrap') as Map<String, dynamic>;
      await _apply(j);
    } finally {
      bootstrapping = false;
    }
  }

  Future<void> _apply(Map<String, dynamic> j) async {
    final id = identity!;

    // ---- keys first: everything else needs them
    for (final k in (j['keys'] as List)) {
      final scope = k['scopeId'] as String, ver = k['version'] as int;
      if (_keys[scope]?[ver] != null) continue;
      try {
        (_keys[scope] ??= {})[ver] = SecretKey(await NyxCrypto.openSealed(id, k['sealed']));
      } catch (_) {}
    }
    _profileKeys.clear();
    for (final p in (j['profileKeys'] as List)) {
      try {
        _profileKeys[p['ownerId']] = SecretKey(await NyxCrypto.openSealed(id, p['sealed']));
      } catch (_) {}
    }

    // ---- people
    final seen = <String>{};
    for (final uj in (j['users'] as List)) {
      final m = uj as Map<String, dynamic>;
      final existing = users[m['id']];
      final u = existing ?? UserModel(m);
      if (existing != null) {
        u.displayName = m['displayName'];
        u.presence = m['presence'] ?? u.presence;
        u.profileCipher = m['profileCipher'];
        u.profileVersion = (m['profileVersion'] as num?)?.toInt() ?? 0;
      }
      users[u.id] = u;
      seen.add(u.id);
    }
    users.removeWhere((k, _) => !seen.contains(k));
    me = users[(j['me'] as Map)['id']];
    _profileKeys[me!.id] = id.profileKey;
    isInstanceAdmin = j['isInstanceAdmin'] == true;
    totpEnabled = j['totpEnabled'] == true;
    for (final u in users.values) {
      await _decodeProfile(u);
    }

    // ---- servers
    final newGuilds = <String, GuildModel>{};
    for (final gj in (j['guilds'] as List)) {
      final gm = gj['guild'] as Map<String, dynamic>;
      final g = GuildModel(gm['id'], gm['ownerId'], gm['keyVersion']);
      final meta = await _meta(g.id, 'guild|${g.id}', gm['metaCipher']);
      g.keysMissing = _keys[g.id]?.isEmpty ?? true;
      g.name = (meta?['name'] as String?) ?? (g.keysMissing ? 'Waiting for keys…' : 'Server');
      g.description = (meta?['desc'] as String?) ?? '';
      g.icon = BlobRef.from(meta?['icon']);
      g.banner = BlobRef.from(meta?['banner']);
      g.background = BlobRef.from(meta?['bg']);
      g.accent = (meta?['accent'] as num?)?.toInt();

      for (final r in (gj['roles'] as List)) {
        final rm = await _meta(g.id, 'role|${g.id}', r['metaCipher']);
        g.roles[r['id']] = RoleModel(r['id'], (rm?['name'] as String?) ?? (r['isEveryone'] == true ? '@everyone' : 'role'), (rm?['color'] as num?)?.toInt() ?? 0,
            (r['permissions'] as num).toInt(), r['position'], r['isEveryone'] == true, icon: BlobRef.from(rm?['icon']), hoist: rm?['hoist'] == true);
      }
      for (final m in (gj['members'] as List)) {
        final nick = await _meta(g.id, 'nick|${g.id}|${m['userId']}', m['nickCipher']);
        g.members[m['userId']] = MemberModel(m['userId'], (m['roleIds'] as List).cast<String>(), DateTime.parse(m['joinedAt']),
            nick: nick?['nick'] as String?, timeoutUntil: m['timeoutUntil'] == null ? null : DateTime.parse(m['timeoutUntil']));
      }
      for (final c in (gj['channels'] as List)) {
        final cm = await _meta(g.id, 'channel|${c['id']}', c['metaCipher']);
        g.channels[c['id']] = ChannelModel(
          id: c['id'],
          guildId: g.id,
          kind: c['kind'],
          parentId: c['parentId'],
          position: c['position'],
          keyVersion: c['keyVersion'],
          slowmode: c['slowmodeSeconds'] ?? 0,
          restricted: c['restricted'] == true,
          name: (cm?['name'] as String?) ?? 'channel',
          topic: (cm?['topic'] as String?) ?? '',
          members: ((c['members'] as List?) ?? const []).cast<String>(),
        );
      }
      for (final a in (gj['assets'] as List)) {
        final am = await _meta(g.id, 'asset|${g.id}', a['metaCipher']);
        final ref = am?['key'] == null ? null : BlobRef(id: a['blobId'], key: am!['key'], mime: (am['mime'] as String?) ?? 'image/png', name: (am['name'] as String?) ?? '');
        g.assets[a['id']] = AssetModel(a['id'], a['kind'], a['blobId'], (am?['name'] as String?) ?? 'emoji', am?['animated'] == true, ref);
      }
      newGuilds[g.id] = g;
    }
    guilds
      ..clear()
      ..addAll(newGuilds);

    // ---- direct messages
    dms.clear();
    for (final c in (j['dms'] as List)) {
      final cm = await _meta(c['id'], 'gdm|${c['id']}', c['metaCipher']);
      dms[c['id']] = ChannelModel(
        id: c['id'],
        kind: c['kind'],
        keyVersion: c['keyVersion'],
        ownerId: c['ownerId'],
        name: (cm?['name'] as String?) ?? '',
        members: ((c['members'] as List?) ?? const []).cast<String>(),
      );
    }

    _setRelations(j['relations']);
    unawaited(GifLibrary.instance.load(myId));

    // ---- unread state
    lastRead.clear();
    for (final r in (j['readStates'] as List)) {
      lastRead[r['channelId']] = (r['lastReadId'] as num).toInt();
    }
    for (final r in (j['lastMessageIds'] as List)) {
      final v = (r['lastId'] as num).toInt();
      if (v > (lastMsg[r['channelId']] ?? 0)) lastMsg[r['channelId']] = v;
    }

    // ---- keep the selection valid
    if (guildId != null && !guilds.containsKey(guildId)) guildId = null;
    if (channelId != null && channelById(channelId!) == null) channelId = null;
    if (channelId == null) _pickDefaultChannel();

    notifyListeners();
    // Re-decrypt messages that were waiting for a key that has arrived since.
    await _redecryptWaiting();
    if (channelId != null && !messages.containsKey(channelId)) await loadHistory(channelId!);
    // Hand out keys to people who are waiting for them.
    unawaited(_syncKeys(j));
  }

  void _pickDefaultChannel() {
    final g = guild;
    if (g == null) {
      channelId = dms.keys.firstOrNull;
    } else {
      channelId = g.sortedChannels.where((c) => c.isText).firstOrNull?.id;
    }
  }

  Future<void> _decodeProfile(UserModel u) async {
    final key = _profileKeys[u.id];
    if (key == null || u.profileCipher == null) {
      u.profileLocked = key == null;
      if (u.profileCipher == null) u.profile = Profile();
      return;
    }
    final j = await NyxCrypto.decryptJson(key, 'profile|${u.id}', u.profileCipher);
    u.profileLocked = j == null;
    if (j != null) u.profile = Profile.from(j);
  }

  /// Lets tests provide keys without a server.
  @visibleForTesting
  void debugSetKey(String scope, int version, SecretKey key) => (_keys[scope] ??= {})[version] = key;

  SecretKey? keyFor(String scope, int version) => _keys[scope]?[version];

  SecretKey? currentKey(String scope, {int? version}) {
    final held = _keys[scope];
    if (held == null || held.isEmpty) return null;
    if (version != null && held[version] != null) return held[version];
    final best = held.keys.reduce(max);
    return held[best];
  }

  int keyVersionOf(String scope) => (_keys[scope]?.keys.fold<int>(0, max)) ?? 1;

  Future<Map<String, dynamic>?> _meta(String scope, String aad, String? cipher) async {
    if (cipher == null || cipher.isEmpty) return null;
    final held = _keys[scope];
    if (held == null) return null;
    for (final v in (held.keys.toList()..sort((a, b) => b.compareTo(a)))) {
      final r = await NyxCrypto.decryptJson(held[v]!, aad, cipher);
      if (r != null) return r;
    }
    return null;
  }

  /// Seals every key someone is still waiting for (a new member, a person who just joined).
  Future<void> _syncKeys(Map<String, dynamic> j) async {
    try {
      final shares = <Map<String, dynamic>>[];
      for (final p in (j['pendingKeys'] as List)) {
        final scope = p['scopeId'] as String, ver = p['version'] as int;
        final key = keyFor(scope, ver);
        if (key == null) continue;
        final bytes = await key.extractBytes();
        for (final uid in (p['userIds'] as List).cast<String>()) {
          final u = users[uid];
          if (u == null) continue;
          shares.add({'scopeId': scope, 'version': ver, 'userId': uid, 'sealed': await NyxCrypto.sealTo(u.xPublic, bytes)});
        }
      }
      if (shares.isNotEmpty) await api.post('/api/keys', {'shares': shares});

      final profileShares = <Map<String, dynamic>>[];
      final pk = identity!.profileKeyBytes;
      for (final uid in (j['pendingProfileKeys'] as List).cast<String>()) {
        final u = users[uid];
        if (u != null) profileShares.add({'viewerId': uid, 'version': 1, 'sealed': await NyxCrypto.sealTo(u.xPublic, pk)});
      }
      if (profileShares.isNotEmpty) await api.post('/api/users/me/profile-keys', profileShares);
    } catch (_) {}
  }

  // ==================================================================== live events

  void _wireHub() {
    Map<String, dynamic> m(dynamic d) => (d as Map).cast<String, dynamic>();

    hub.onConnected = () {
      // Whatever happened while we were offline: fetch it.
      scheduleResync(const Duration(milliseconds: 50));
      final c = channelId;
      if (c != null && channelById(c)?.isText == true) loadHistory(c, fresh: true).catchError((_) {});
    };

    hub.on('Ready', (d) {
      for (final u in users.values) {
        u.presence = 'offline';
      }
      for (final u in users.values) {
        u.activity = null;
      }
      for (final o in (m(d)['online'] as List)) {
        users[o['userId']]?.presence = o['presence'];
      }
      for (final o in (m(d)['activities'] as List? ?? const [])) {
        users[o['userId']]?.activity = (o['activity'] as Map?)?.cast<String, dynamic>();
      }
      if (myActivity != null) _pushActivity();
      notifyListeners();
    });
    hub.on('Activity', (d) {
      final x = m(d);
      users[x['userId']]?.activity = (x['activity'] as Map?)?.cast<String, dynamic>();
      notifyListeners();
    });
    hub.on('Presence', (d) {
      final x = m(d);
      users[x['userId']]?.presence = x['presence'];
      if (x['presence'] == 'offline') users[x['userId']]?.activity = null;
      notifyListeners();
    });
    hub.on('MessageCreate', (d) => _onMessage(m(d)));
    hub.on('MessageUpdate', (d) async {
      final msg = await _decryptMessage(m(d));
      if (msg == null) return;
      final list = messages[msg.channelId];
      final i = list?.indexWhere((x) => x.id == msg.id) ?? -1;
      if (i >= 0) list![i] = msg;
      notifyListeners();
    });
    hub.on('MessageDelete', (d) {
      final x = m(d);
      final list = messages[x['channelId']];
      final i = list?.indexWhere((e) => e.id == (x['id'] as num).toInt()) ?? -1;
      if (i >= 0) {
        list![i].deleted = true;
        list[i].content = null;
        list[i].reactions = const [];
        list[i].pinned = false;
      }
      notifyListeners();
    });
    hub.on('Typing', (d) {
      final x = m(d);
      final ch = x['channelId'] as String, u = x['userId'] as String;
      final map = typing[ch] ??= {};
      map[u]?.cancel();
      map[u] = Timer(const Duration(seconds: 6), () {
        map.remove(u);
        notifyListeners();
      });
      notifyListeners();
    });
    hub.on('ReadState', (d) {
      final x = m(d);
      final id = (x['lastReadId'] as num).toInt();
      if (id > (lastRead[x['channelId']] ?? 0)) lastRead[x['channelId']] = id;
      notifyListeners();
    });
    for (final e in ['ChannelCreate', 'ChannelUpdate', 'ChannelDelete', 'ChannelsReordered', 'GuildUpdate', 'GuildRemoved', 'MemberAdd', 'MemberRemove', 'MemberUpdate', 'RoleUpdate', 'RoleDelete', 'AssetUpdate', 'AssetDelete', 'UserUpdate', 'UserJoined', 'ProfileKey', 'KeysAvailable', 'Resync', 'ChannelMemberRemove']) {
      hub.on(e, (_) => scheduleResync());
    }
    hub.on('FriendsChanged', (_) => _loadRelations());
    hub.on('KeyRotationNeeded', (d) => _rotateIfAllowed(m(d)));
    hub.on('SessionRevoked', (_) {
      _wipe();
      toast('This device was signed out.');
    });

    hub.on('VoiceState', (d) {
      final x = m(d);
      voiceRooms[x['channelId']] = [
        for (final u in (x['users'] as List)) VoiceParticipant(u['userId'], u['muted'] == true, u['deafened'] == true, u['streaming'] == true, u['camera'] == true)
      ];
      notifyListeners();
      voice.onRoomState(x['channelId']);
    });
    hub.on('VoiceJoined', (d) => voice.onJoined(m(d)['channelId'], m(d)['userId']));
    hub.on('VoiceLeft', (d) => voice.onLeft(m(d)['channelId'], m(d)['userId']));
    hub.on('VoiceParticipants', (d) => voice.onParticipants(m(d)['channelId'], (m(d)['userIds'] as List).cast<String>()));
    hub.on('Signal', (d) => voice.onSignal(m(d)['from'], m(d)['channelId'], m(d)['payload']));
  }

  Future<void> _onMessage(Map<String, dynamic> j) async {
    final msg = await _decryptMessage(j);
    if (msg == null) return;
    final list = messages[msg.channelId];
    if (list != null && !list.any((x) => x.id == msg.id)) list.add(msg);
    if (msg.id > (lastMsg[msg.channelId] ?? 0)) lastMsg[msg.channelId] = msg.id;
    typing[msg.channelId]?.remove(msg.senderId)?.cancel();

    if (msg.senderId == myId) {
      lastRead[msg.channelId] = msg.id;
    } else if (msg.channelId == channelId && list != null && _appFocused) {
      markRead(msg.channelId);
    } else if (msg.mentions.contains(myId) || msg.mentionsEveryone) {
      mentionCount[msg.channelId] = (mentionCount[msg.channelId] ?? 0) + 1;
    }
    if (msg.senderId != myId && !(msg.channelId == channelId && _appFocused)) _notify(msg);
    notifyListeners();
  }

  /// Sound, taskbar flash and system notification for a message the person is not looking at.
  void _notify(MessageModel msg) {
    if (myPresence == 'dnd') return;
    final ch = channelById(msg.channelId);
    if (ch == null) return;
    final ping = ch.isDm || msg.mentions.contains(myId) || msg.mentionsEveryone;
    final who = displayNameIn(msg.senderId, ch.guildId);
    final title = ch.isDm ? who : '$who  ·  #${ch.name}';
    var body = msg.text.trim();
    if (body.isEmpty) body = msg.files.isNotEmpty ? (msg.content?['st'] == true ? 'sent a sticker' : (msg.files.first.mime == 'image/gif' ? 'sent a GIF' : 'sent a file')) : 'sent a message';
    if (body.length > 200) body = '${body.substring(0, 200)}…';
    Notifier.instance.message(channelId: ch.id, title: title, body: body, ping: ping, appFocused: _appFocused);
  }

  bool _appFocused = true;
  void setFocused(bool v) {
    _appFocused = v;
    if (v) Notifier.instance.focused();
    if (v && channelId != null) markRead(channelId!);
  }

  // =================================================================== messages

  Future<MessageModel?> _decryptMessage(Map<String, dynamic> j) async {
    final chId = j['channelId'] as String;
    final ch = channelById(chId);
    if (ch == null) return null;
    final ver = j['keyVersion'] as int;
    final key = keyFor(chId, ver);
    final sender = users[j['senderId']];
    final deleted = j['deleted'] == true;
    Map<String, dynamic>? content;
    if (!deleted && key != null && sender != null) {
      content = await NyxCrypto.decryptMessage(
          channelKey: key, channelId: chId, keyVersion: ver, senderEdPublicKey: sender.edPublic, ciphertext: j['ciphertext']);
    }
    final reactions = <ReactionModel>[];
    if (key != null) {
      for (final r in (j['reactions'] as List? ?? const [])) {
        final e = await NyxCrypto.decryptJson(key, 'react|$chId', r['cipher']);
        reactions.add(ReactionModel(r['tag'], (e?['e'] as String?) ?? '?', (r['users'] as List).cast<String>().toSet()));
      }
    }
    return MessageModel(
      id: (j['id'] as num).toInt(),
      channelId: chId,
      senderId: j['senderId'],
      createdAt: DateTime.parse(j['createdAt']).toLocal(),
      editedAt: j['editedAt'] == null ? null : DateTime.parse(j['editedAt']).toLocal(),
      pinned: j['pinned'] == true,
      deleted: deleted,
      replyTo: (j['replyTo'] as num?)?.toInt(),
      keyVersion: ver,
      content: content,
      waitingForKey: !deleted && key == null,
      reactions: reactions,
    );
  }

  Future<void> _redecryptWaiting() async {
    var changed = false;
    for (final list in messages.values) {
      for (var i = 0; i < list.length; i++) {
        final m = list[i];
        if (m.deleted || m.content != null) continue;
        if (keyFor(m.channelId, m.keyVersion) == null) continue;
        // Needs the original ciphertext: cheapest is to re-fetch the page; mark for reload.
        changed = true;
        break;
      }
    }
    if (changed) {
      for (final id in messages.keys.toList()) {
        if (messages[id]!.any((m) => !m.deleted && m.content == null && keyFor(m.channelId, m.keyVersion) != null)) {
          await loadHistory(id, fresh: true);
        }
      }
    }
  }

  Future<void> selectGuild(String? id) async {
    guildId = id;
    if (id == null) {
      friendsView = true;
      notifyListeners();
      return;
    }
    _pickDefaultChannel();
    notifyListeners();
    if (channelId != null) await openChannel(channelId!);
  }

  Future<void> openChannel(String id) async {
    channelId = id;
    friendsView = false;
    final ch = channelById(id);
    if (ch?.guildId != null && guildId != ch!.guildId) guildId = ch.guildId;
    if (ch?.guildId == null && ch != null) guildId = null;
    notifyListeners();
    if (ch != null && ch.isText) {
      if (!messages.containsKey(id)) await loadHistory(id);
      markRead(id);
    }
  }

  Future<void> loadHistory(String id, {bool fresh = false}) async {
    final rows = await api.get('/api/channels/$id/messages', {'limit': 50}) as List;
    final list = <MessageModel>[];
    for (final r in rows) {
      final msg = await _decryptMessage((r as Map).cast<String, dynamic>());
      if (msg != null) list.add(msg);
    }
    messages[id] = list;
    hasMoreHistory[id] = rows.length >= 50;
    if (list.isNotEmpty && list.last.id > (lastMsg[id] ?? 0)) lastMsg[id] = list.last.id;
    _countMentions(id);
    notifyListeners();
  }

  void _countMentions(String id) {
    final after = lastRead[id] ?? 0;
    mentionCount[id] = (messages[id] ?? const []).where((m) => m.id > after && m.senderId != myId && (m.mentions.contains(myId) || m.mentionsEveryone)).length;
  }

  Future<bool> loadOlder(String id) async {
    final list = messages[id];
    if (list == null || list.isEmpty || hasMoreHistory[id] == false) return false;
    final rows = await api.get('/api/channels/$id/messages', {'limit': 50, 'before': list.first.id}) as List;
    final older = <MessageModel>[];
    for (final r in rows) {
      final msg = await _decryptMessage((r as Map).cast<String, dynamic>());
      if (msg != null) older.add(msg);
    }
    list.insertAll(0, older);
    hasMoreHistory[id] = rows.length >= 50;
    notifyListeners();
    return older.isNotEmpty;
  }

  void markRead(String id) {
    final last = lastMsg[id] ?? 0;
    if (last == 0 || (lastRead[id] ?? 0) >= last) {
      if (mentionCount.remove(id) != null) notifyListeners();
      return;
    }
    lastRead[id] = last;
    mentionCount.remove(id);
    notifyListeners();
    api.put('/api/channels/$id/read', {'messageId': last}).catchError((_) {});
  }

  bool hasUnread(String id) => (lastMsg[id] ?? 0) > (lastRead[id] ?? 0);
  int mentionsIn(String id) => mentionCount[id] ?? 0;

  bool guildHasUnread(GuildModel g) => g.channels.values.any((c) => c.isText && hasUnread(c.id));
  int guildMentions(GuildModel g) => g.channels.values.fold(0, (a, c) => a + mentionsIn(c.id));
  bool get dmsHaveUnread => dms.values.any((c) => hasUnread(c.id));
  int get dmMentions => dms.values.fold(0, (a, c) => a + (hasUnread(c.id) ? 1 : 0)) + incomingFriends.length;

  void typingPing() {
    final c = channelId;
    if (c != null && hub.connected) hub.invoke('Typing', [c]).catchError((_) => null);
  }

  List<String> typingIn(String id) => (typing[id]?.keys ?? const <String>[]).where((u) => u != myId).toList();

  Future<BlobRef> uploadFile(PickedFile f, {required int scope, required String scopeId, void Function(double)? onProgress}) async {
    final key = NyxCrypto.newKey();
    final total = FileCrypto.encryptedSize(f.size);
    final id = await api.uploadBlob(
      scope: scope,
      scopeId: scopeId,
      totalSize: total,
      chunks: FileCrypto.encryptStream(key, f.open()),
      onProgress: (sent) => onProgress?.call(total == 0 ? 1 : (sent / total).clamp(0, 1).toDouble()),
    );
    return BlobRef(id: id, key: NyxCrypto.b64(await key.extractBytes()), mime: f.mime, name: f.name, size: f.size);
  }

  /// Sends files that are already uploaded (saved GIFs, server stickers). [sticker] shows them big and unframed.
  Future<void> sendRefs(String channelId, List<BlobRef> refs, {bool sticker = false, MessageModel? replyTo}) async {
    final ch = channelById(channelId);
    final key = currentKey(channelId);
    if (ch == null || key == null) throw ApiException(0, 'You do not have the key for this channel yet.');
    final ver = keyVersionOf(channelId).clamp(1, ch.keyVersion);
    final content = <String, dynamic>{'x': '', 'f': [for (final r in refs) r.toJson()], if (sticker) 'st': true};
    final cipher = await NyxCrypto.encryptMessage(channelKey: keyFor(channelId, ver) ?? key, channelId: channelId, keyVersion: ver, sender: identity!, content: content);
    await api.post('/api/channels/$channelId/messages', {'ciphertext': cipher, 'keyVersion': ver, if (replyTo != null) 'replyTo': replyTo.id});
  }

  /// Keeps a GIF: a copy is uploaded under my own profile scope (readable by anyone I send it to) and remembered locally.
  Future<void> saveGif(BlobRef source) async {
    if (GifLibrary.instance.has(source.id)) return;
    final bytes = await media.load(source);
    final ref = await uploadFile(PickedFile.bytes(source.name.isEmpty ? 'saved.gif' : source.name, bytes, mime: source.mime), scope: 2, scopeId: myId);
    await GifLibrary.instance.add(BlobRef(id: ref.id, key: ref.key, mime: source.mime, name: source.name, size: bytes.length));
  }

  Future<void> saveGifBytes(Uint8List bytes, String name) async {
    final ref = await uploadFile(PickedFile.bytes(name, bytes, mime: 'image/gif'), scope: 2, scopeId: myId);
    await GifLibrary.instance.add(BlobRef(id: ref.id, key: ref.key, mime: 'image/gif', name: name, size: bytes.length));
  }

  Future<void> sendMessage(
    String channelId,
    String text, {
    List<PickedFile> files = const [],
    MessageModel? replyTo,
    void Function(double)? onProgress,
  }) async {
    final ch = channelById(channelId);
    final key = currentKey(channelId);
    if (ch == null || key == null) throw ApiException(0, 'You do not have the key for this channel yet.');
    final refs = <BlobRef>[];
    for (var i = 0; i < files.length; i++) {
      refs.add(await uploadFile(files[i], scope: 0, scopeId: channelId, onProgress: (p) => onProgress?.call((i + p) / files.length)));
    }
    final ver = keyVersionOf(channelId).clamp(1, ch.keyVersion);
    final mention = _findMentions(text, ch);
    final content = <String, dynamic>{
      'x': text,
      if (refs.isNotEmpty) 'f': [for (final r in refs) r.toJson()],
      if (mention.$1.isNotEmpty) 'm': mention.$1,
      if (mention.$2) 'ev': true,
    };
    final cipher = await NyxCrypto.encryptMessage(channelKey: keyFor(channelId, ver) ?? key, channelId: channelId, keyVersion: ver, sender: identity!, content: content);
    await api.post('/api/channels/$channelId/messages', {'ciphertext': cipher, 'keyVersion': ver, if (replyTo != null) 'replyTo': replyTo.id});
  }

  /// @name -> user ids (by display name or username, longest match first); @everyone / @here.
  (List<String>, bool) _findMentions(String text, ChannelModel ch) {
    final ids = <String>{};
    final pool = ch.guildId != null ? (guilds[ch.guildId]?.members.keys.toList() ?? []) : ch.members;
    final everyone = RegExp(r'(^|\s)@(everyone|here)\b').hasMatch(text) &&
        (ch.guildId == null || guilds[ch.guildId]?.can(myId, Perm.mentionEveryone) == true);
    for (final id in pool) {
      final u = users[id];
      if (u == null) continue;
      final names = {u.username, u.displayName, guilds[ch.guildId]?.members[id]?.nick ?? ''}..remove('');
      for (final n in names) {
        if (RegExp('(^|\\s)@${RegExp.escape(n)}(?![\\w.])', caseSensitive: false).hasMatch(text)) ids.add(id);
      }
    }
    return (ids.toList(), everyone);
  }

  Future<void> editMessage(MessageModel msg, String text) async {
    final key = currentKey(msg.channelId);
    if (key == null) return;
    final ver = keyVersionOf(msg.channelId);
    final content = Map<String, dynamic>.from(msg.content ?? {})..['x'] = text;
    final ch = channelById(msg.channelId);
    if (ch != null) {
      final mention = _findMentions(text, ch);
      content['m'] = mention.$1;
      content['ev'] = mention.$2;
    }
    final cipher = await NyxCrypto.encryptMessage(channelKey: keyFor(msg.channelId, ver) ?? key, channelId: msg.channelId, keyVersion: ver, sender: identity!, content: content);
    await api.put('/api/messages/${msg.id}', {'ciphertext': cipher, 'keyVersion': ver});
  }

  Future<void> deleteMessage(MessageModel msg) => api.delete('/api/messages/${msg.id}');
  Future<void> setPinned(MessageModel msg, bool pin) => pin ? api.put('/api/messages/${msg.id}/pin') : api.delete('/api/messages/${msg.id}/pin');

  Future<void> toggleReaction(MessageModel msg, String emoji) async {
    final key = currentKey(msg.channelId);
    if (key == null) return;
    final tag = await NyxCrypto.reactionTag(key, emoji);
    final mine = msg.reactions.any((r) => r.tag == tag && r.users.contains(myId));
    if (mine) {
      await api.delete('/api/messages/${msg.id}/reactions/$tag');
    } else {
      final cipher = await NyxCrypto.encryptJson(key, 'react|${msg.channelId}', {'e': emoji});
      await api.put('/api/messages/${msg.id}/reactions/$tag', {'cipher': cipher});
    }
  }

  Future<List<MessageModel>> pinned(String channelId) async {
    final rows = await api.get('/api/channels/$channelId/pins') as List;
    return [for (final r in rows) ?await _decryptMessage((r as Map).cast<String, dynamic>())];
  }

  MessageModel? messageById(String channelId, int id) => messages[channelId]?.where((m) => m.id == id).firstOrNull;

  // ================================================================ people / profile

  String displayNameIn(String userId, [String? guildId]) {
    final u = users[userId];
    final nick = guilds[guildId ?? this.guildId]?.members[userId]?.nick;
    return nick ?? u?.name ?? 'Unknown';
  }

  Future<void> setPresence(String p) async {
    myPresence = p;
    notifyListeners();
    try {
      await hub.invoke('SetPresence', [p]);
    } catch (_) {}
  }

  Future<void> updateProfile({String? displayName, Profile? profile}) async {
    final cipher = profile == null ? null : await NyxCrypto.encryptJson(identity!.profileKey, 'profile|$myId', profile.toJson());
    await api.put('/api/users/me', {
      if (displayName != null) 'displayName': displayName,
      if (cipher != null) 'profileCipher': cipher,
      if (cipher != null) 'profileVersion': me!.profileVersion + 1,
    });
    await _bootstrap();
  }

  // =============================================================== friends

  void showFriends() {
    friendsView = true;
    notifyListeners();
  }

  void _setRelations(dynamic r) {
    if (r is! Map) return;
    Set<String> ids(String k) => ((r[k] as List?) ?? const []).cast<String>().toSet();
    friends
      ..clear()
      ..addAll(ids('friends'));
    incomingFriends
      ..clear()
      ..addAll(ids('incoming'));
    outgoingFriends
      ..clear()
      ..addAll(ids('outgoing'));
    blockedUsers
      ..clear()
      ..addAll(ids('blocked'));
  }

  Future<void> _loadRelations() async {
    try {
      _setRelations(await api.get('/api/friends'));
      notifyListeners();
    } catch (_) {}
  }

  /// Returns "pending" or "friends".
  Future<String> addFriend(String username) async {
    final r = await api.post('/api/friends', {'username': username});
    await _loadRelations();
    return (r['status'] as String?) ?? 'pending';
  }

  Future<void> acceptFriend(String id) async {
    await api.post('/api/friends/$id/accept');
    await _loadRelations();
  }

  Future<void> removeFriend(String id) async {
    await api.delete('/api/friends/$id');
    await _loadRelations();
  }

  Future<void> blockUser(String id) async {
    await api.post('/api/users/$id/block');
    await _loadRelations();
  }

  Future<void> unblockUser(String id) async {
    await api.delete('/api/users/$id/block');
    await _loadRelations();
  }

  // =============================================================== direct messages

  Future<String> openDm(String userId) async {
    final existing = dms.values.where((c) => c.kind == ChannelKind.dm && c.members.contains(userId)).firstOrNull;
    if (existing != null) {
      await openChannel(existing.id);
      return existing.id;
    }
    return createConversation([userId]);
  }

  Future<String> createConversation(List<String> others, {String? groupName}) async {
    final everyone = {...others, myId}.toList();
    final key = NyxCrypto.newKey();
    final bytes = await key.extractBytes();
    final keys = [for (final u in everyone) {'userId': u, 'sealed': await NyxCrypto.sealTo(users[u]!.xPublic, bytes)}];
    final res = await api.post('/api/dms', {'userIds': others, 'keys': keys});
    final id = res['channel']['id'] as String;
    if (res['existing'] != true) {
      (_keys[id] ??= {})[1] = key;
      // The channel id did not exist yet when the key was made; the name is bound to it now.
      if (others.length > 1 && groupName != null && groupName.isNotEmpty) {
        await api.put('/api/channels/$id', {'metaCipher': await NyxCrypto.encryptJson(key, 'gdm|$id', {'name': groupName})});
      }
    }
    await _bootstrap();
    await openChannel(id);
    return id;
  }

  Future<void> renameGroup(String id, String name) async {
    final key = currentKey(id);
    if (key == null) return;
    await api.put('/api/channels/$id', {'metaCipher': await NyxCrypto.encryptJson(key, 'gdm|$id', {'name': name})});
    await _bootstrap();
  }

  Future<void> addToGroup(String id, List<String> userIds) async {
    final ch = dms[id];
    if (ch == null) return;
    final key = NyxCrypto.newKey();
    final bytes = await key.extractBytes();
    final all = {...ch.members, ...userIds}.toList();
    final keys = [for (final u in all) {'userId': u, 'sealed': await NyxCrypto.sealTo(users[u]!.xPublic, bytes)}];
    await api.post('/api/channels/$id/members', {'userIds': userIds, 'version': ch.keyVersion + 1, 'keys': keys});
    (_keys[id] ??= {})[ch.keyVersion + 1] = key;
    await _bootstrap();
  }

  Future<void> leaveGroup(String id) async {
    await api.delete('/api/channels/$id/members/$myId');
    if (channelId == id) channelId = null;
    await _bootstrap();
  }

  // ==================================================================== servers

  Future<List<Map<String, dynamic>>> _sealFor(Iterable<String> userIds, SecretKey key) async {
    final bytes = await key.extractBytes();
    return [for (final u in userIds) if (users[u] != null) {'userId': u, 'sealed': await NyxCrypto.sealTo(users[u]!.xPublic, bytes)}];
  }

  Future<String> createGuild(String name, {PickedFile? icon}) async {
    final gkey = NyxCrypto.newKey();
    final catId = newUuid(), textId = newUuid(), voiceId = newUuid();
    final textKey = NyxCrypto.newKey(), voiceKey = NyxCrypto.newKey();
    final mySeal = (String? u) async => NyxCrypto.sealTo(me!.xPublic, await (u == null ? gkey : textKey).extractBytes());
    final res = await api.post('/api/guilds', {
      'metaCipher': await NyxCrypto.encryptJson(gkey, 'guild|PENDING', {'name': name}),
      'everyoneMeta': await NyxCrypto.encryptJson(gkey, 'role|PENDING', {'name': '@everyone'}),
      'ownerKey': await mySeal(null),
      'channels': [
        {'id': catId, 'kind': ChannelKind.category, 'position': 0, 'metaCipher': await NyxCrypto.encryptJson(gkey, 'channel|$catId', {'name': 'Text channels'})},
        {
          'id': textId,
          'kind': ChannelKind.text,
          'parentId': catId,
          'position': 1,
          'metaCipher': await NyxCrypto.encryptJson(gkey, 'channel|$textId', {'name': 'general', 'topic': 'Welcome!'}),
          'keys': [{'userId': myId, 'sealed': await NyxCrypto.sealTo(me!.xPublic, await textKey.extractBytes())}],
        },
        {
          'id': voiceId,
          'kind': ChannelKind.voice,
          'position': 2,
          'metaCipher': await NyxCrypto.encryptJson(gkey, 'channel|$voiceId', {'name': 'Lounge'}),
          'keys': [{'userId': myId, 'sealed': await NyxCrypto.sealTo(me!.xPublic, await voiceKey.extractBytes())}],
        },
      ],
    });
    final gid = res['guild']['id'] as String;
    (_keys[gid] ??= {})[1] = gkey;
    (_keys[textId] ??= {})[1] = textKey;
    (_keys[voiceId] ??= {})[1] = voiceKey;
    // The server encrypted-meta aad used placeholders because ids did not exist yet: re-encrypt with real ids.
    await api.put('/api/guilds/$gid', {'metaCipher': await NyxCrypto.encryptJson(gkey, 'guild|$gid', {'name': name})});
    final everyone = await _everyoneRoleId(gid);
    if (everyone != null) {
      await api.put('/api/guilds/$gid/roles/$everyone', {'metaCipher': await NyxCrypto.encryptJson(gkey, 'role|$gid', {'name': '@everyone'}), 'permissions': Perm.everyone, 'position': 0});
    }
    await _bootstrap();
    if (icon != null) {
      final ref = await uploadFile(icon, scope: 1, scopeId: gid);
      await updateGuild(gid, icon: ref);
    }
    await selectGuild(gid);
    return gid;
  }

  Future<String?> _everyoneRoleId(String gid) async {
    final b = await api.get('/api/bootstrap');
    for (final g in (b['guilds'] as List)) {
      if (g['guild']['id'] == gid) {
        for (final r in (g['roles'] as List)) {
          if (r['isEveryone'] == true) return r['id'];
        }
      }
    }
    return null;
  }

  Future<void> updateGuild(String id, {String? name, String? description, Object? icon = _keep, Object? banner = _keep, Object? background = _keep, Object? accent = _keep}) async {
    final g = guilds[id];
    final key = currentKey(id);
    if (g == null || key == null) return;
    final meta = <String, dynamic>{
      'name': name ?? g.name,
      'desc': description ?? g.description,
    };
    final i = identical(icon, _keep) ? g.icon : icon as BlobRef?;
    final b = identical(banner, _keep) ? g.banner : banner as BlobRef?;
    final bg = identical(background, _keep) ? g.background : background as BlobRef?;
    final ac = identical(accent, _keep) ? g.accent : accent as int?;
    if (i != null) meta['icon'] = i.toJson();
    if (b != null) meta['banner'] = b.toJson();
    if (bg != null) meta['bg'] = bg.toJson();
    if (ac != null) meta['accent'] = ac;
    await api.put('/api/guilds/$id', {'metaCipher': await NyxCrypto.encryptJson(key, 'guild|$id', meta)});
    await _bootstrap();
  }

  static const Object _keep = Object();

  Future<void> deleteGuild(String id) async {
    await api.delete('/api/guilds/$id');
    if (guildId == id) guildId = null;
    await _bootstrap();
  }

  Future<void> leaveGuild(String id) async {
    await api.post('/api/guilds/$id/leave');
    if (guildId == id) guildId = null;
    await _bootstrap();
  }

  Future<void> joinWithInvite(String code) async {
    final res = await api.post('/api/invites/${code.trim().toUpperCase()}/join');
    await _bootstrap();
    await selectGuild(res['guildId']);
  }

  Future<Map<String, dynamic>> createInvite(String guildId, {int maxUses = 0, int hours = 168}) async =>
      (await api.post('/api/guilds/$guildId/invites', {'maxUses': maxUses, 'expiresHours': hours})) as Map<String, dynamic>;

  Future<List<dynamic>> listInvites(String guildId) async => (await api.get('/api/guilds/$guildId/invites')) as List;

  Future<String> createChannel(String gid, String name, int kind, {String? parentId, bool restricted = false, List<String> members = const [], String topic = ''}) async {
    final g = guilds[gid]!;
    final gkey = currentKey(gid)!;
    final id = newUuid();
    final ckey = NyxCrypto.newKey();
    final eligible = kind == ChannelKind.category ? <String>[] : (restricted ? {myId, ...members}.toList() : g.members.keys.toList());
    await api.post('/api/guilds/$gid/channels', {
      'id': id,
      'kind': kind,
      'parentId': parentId,
      'position': g.channels.length,
      'restricted': restricted,
      'members': members,
      'metaCipher': await NyxCrypto.encryptJson(gkey, 'channel|$id', {'name': name, if (topic.isNotEmpty) 'topic': topic}),
      if (kind != ChannelKind.category) 'keys': await _sealFor(eligible, ckey),
    });
    (_keys[id] ??= {})[1] = ckey;
    await _bootstrap();
    return id;
  }

  Future<void> updateChannel(ChannelModel c, {String? name, String? topic, int? slowmode, String? parentId, bool clearParent = false}) async {
    final gkey = currentKey(c.guildId!)!;
    await api.put('/api/channels/${c.id}', {
      if (name != null || topic != null) 'metaCipher': await NyxCrypto.encryptJson(gkey, 'channel|${c.id}', {'name': name ?? c.name, 'topic': topic ?? c.topic}),
      if (slowmode != null) 'slowmodeSeconds': slowmode,
      if (parentId != null) 'parentId': parentId,
      if (clearParent) 'clearParent': true,
    });
    await _bootstrap();
  }

  Future<void> deleteChannel(String id) async {
    await api.delete('/api/channels/$id');
    if (channelId == id) channelId = null;
    await _bootstrap();
  }

  Future<void> createRole(String gid, String name, int color, int permissions, int position) async {
    final gkey = currentKey(gid)!;
    await api.post('/api/guilds/$gid/roles', {'metaCipher': await NyxCrypto.encryptJson(gkey, 'role|$gid', {'name': name, 'color': color}), 'permissions': permissions, 'position': position});
    await _bootstrap();
  }

  Future<void> updateRole(String gid, RoleModel r, {String? name, int? color, int? permissions, int? position, bool? hoist}) async {
    final gkey = currentKey(gid)!;
    final meta = {'name': name ?? r.name, 'color': color ?? r.color, if (hoist ?? r.hoist) 'hoist': true};
    await api.put('/api/guilds/$gid/roles/${r.id}', {
      'metaCipher': await NyxCrypto.encryptJson(gkey, 'role|$gid', meta),
      'permissions': permissions ?? r.permissions,
      'position': position ?? r.position,
    });
    await _bootstrap();
  }

  Future<void> deleteRole(String gid, String roleId) async {
    await api.delete('/api/guilds/$gid/roles/$roleId');
    await _bootstrap();
  }

  Future<void> setMemberRoles(String gid, String userId, List<String> roleIds) async {
    await api.put('/api/guilds/$gid/members/$userId/roles', {'roleIds': roleIds});
    await _bootstrap();
  }

  Future<void> setNick(String gid, String? nick) async {
    final key = currentKey(gid);
    if (key == null) return;
    await api.put('/api/guilds/$gid/members/me', {'nickCipher': nick == null || nick.isEmpty ? null : await NyxCrypto.encryptJson(key, 'nick|$gid|$myId', {'nick': nick})});
    await _bootstrap();
  }

  Future<void> kick(String gid, String userId) async {
    await api.delete('/api/guilds/$gid/members/$userId');
    await _bootstrap();
  }

  Future<void> ban(String gid, String userId) async {
    await api.put('/api/guilds/$gid/bans/$userId');
    await _bootstrap();
  }

  Future<void> timeout(String gid, String userId, Duration? d) async {
    await api.put('/api/guilds/$gid/members/$userId/timeout', {'until': d == null ? null : DateTime.now().toUtc().add(d).toIso8601String()});
    await _bootstrap();
  }

  Future<void> addAsset(String gid, String kind, String name, PickedFile file, bool animated) async {
    final ref = await uploadFile(file, scope: 1, scopeId: gid);
    final key = currentKey(gid)!;
    await api.post('/api/guilds/$gid/assets', {'kind': kind, 'blobId': ref.id, 'metaCipher': await NyxCrypto.encryptJson(key, 'asset|$gid', {'name': name, 'animated': animated, 'key': ref.key, 'mime': ref.mime})});
    await _bootstrap();
  }

  Future<void> deleteAsset(String gid, String id) async {
    await api.delete('/api/guilds/$gid/assets/$id');
    await _bootstrap();
  }

  // ================================================================ key rotation

  /// After someone leaves or is removed, someone with permission gives everyone else a fresh key.
  Future<void> _rotateIfAllowed(Map<String, dynamic> d) async {
    await Future<void>.delayed(Duration(milliseconds: 300 + Random().nextInt(1500))); // avoid everyone racing
    try {
      if (d['guildId'] != null) {
        final g = guilds[d['guildId']];
        if (g != null && g.can(myId, Perm.manageGuild)) await _rotateGuild(g);
      } else if (d['channelId'] != null) {
        final c = channelById(d['channelId']);
        if (c != null) await _rotateChannel(c);
      }
    } catch (_) {
      scheduleResync();
    }
  }

  Future<void> _rotateGuild(GuildModel g) async {
    final gkey = NyxCrypto.newKey();
    final channels = <Map<String, dynamic>>[];
    for (final c in g.channels.values.where((c) => !c.isCategory)) {
      if (keyFor(c.id, c.keyVersion) == null) continue;
      final members = c.restricted ? c.members : g.members.keys.toList();
      final key = NyxCrypto.newKey();
      channels.add({'channelId': c.id, 'version': c.keyVersion + 1, 'keys': await _sealFor(members, key)});
      (_keys[c.id] ??= {})[c.keyVersion + 1] = key;
    }
    await api.post('/api/guilds/${g.id}/rotate', {'version': g.keyVersion + 1, 'guildKeys': await _sealFor(g.members.keys, gkey), 'channels': channels});
    (_keys[g.id] ??= {})[g.keyVersion + 1] = gkey;
    await _bootstrap();
  }

  Future<void> _rotateChannel(ChannelModel c) async {
    if (keyFor(c.id, c.keyVersion) == null) return;
    final key = NyxCrypto.newKey();
    await api.post('/api/channels/${c.id}/rotate', {'version': c.keyVersion + 1, 'keys': await _sealFor(c.members, key)});
    (_keys[c.id] ??= {})[c.keyVersion + 1] = key;
    await _bootstrap();
  }

  // ==================================================================== account

  Future<List<dynamic>> sessions() async => (await api.get('/api/auth/sessions')) as List;
  Future<void> revokeSession(String id) => api.delete('/api/auth/sessions/$id');
  Future<void> revokeOtherSessions() => api.delete('/api/auth/sessions');
  Future<List<dynamic>> securityLog() async => (await api.get('/api/auth/audit')) as List;

  Future<Map<String, dynamic>> totpSetup() async => (await api.post('/api/auth/totp/setup')) as Map<String, dynamic>;
  Future<List<String>> totpEnable(String code) async => ((await api.post('/api/auth/totp/enable', {'code': code}))['recoveryCodes'] as List).cast<String>();

  Future<void> totpDisable(String password, String code) async {
    final k = await _authKeyFor(password);
    await api.post('/api/auth/totp/disable', {'authKey': k, 'code': code});
  }

  Future<String> _authKeyFor(String password) async {
    final salt = (await api.anon('GET', '/api/auth/salt', query: {'username': me!.username}))['salt'] as String;
    return (await NyxCrypto.deriveFromPassword(password, salt)).authKey;
  }

  Future<void> changePassword(String oldPassword, String newPassword, {String? totp}) async {
    final oldKey = await _authKeyFor(oldPassword);
    final salt = NyxCrypto.newSalt();
    final k = await NyxCrypto.deriveFromPassword(newPassword, salt);
    await api.post('/api/auth/password', {
      'oldAuthKey': oldKey,
      'newAuthKey': k.authKey,
      'newKdfSalt': salt,
      'newEncryptedKeyBackup': await NyxCrypto.exportBackup(identity!, k.wrappingKey),
      if (totp != null && totp.isNotEmpty) 'totp': totp,
    });
  }

  Future<String> createInstanceInvite() async => (await api.post('/api/invites'))['code'] as String;

  // ===================================================================== voice helpers

  SecretKey? signalKey(String channelId) => currentKey(channelId);
}
