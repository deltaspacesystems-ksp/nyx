import 'files.dart';

/// Permission bits, identical to the server's `Perm`.
class Perm {
  static const viewChannels = 1 << 0;
  static const sendMessages = 1 << 1;
  static const attachFiles = 1 << 2;
  static const addReactions = 1 << 3;
  static const mentionEveryone = 1 << 4;
  static const manageMessages = 1 << 5;
  static const connect = 1 << 6;
  static const speak = 1 << 7;
  static const stream = 1 << 8;
  static const muteMembers = 1 << 9;
  static const createInvite = 1 << 10;
  static const kickMembers = 1 << 11;
  static const banMembers = 1 << 12;
  static const manageChannels = 1 << 13;
  static const manageRoles = 1 << 14;
  static const manageGuild = 1 << 15;
  static const manageEmojis = 1 << 16;
  static const administrator = 1 << 17;
  static const all = (1 << 18) - 1;
  static const everyone = viewChannels | sendMessages | attachFiles | addReactions | connect | speak | stream | createInvite;

  static const labels = <int, (String, String)>{
    viewChannels: ('View channels', 'See channels and read their messages'),
    sendMessages: ('Send messages', 'Write in text channels'),
    attachFiles: ('Attach files', 'Upload files and images'),
    addReactions: ('Add reactions', 'React to messages with emoji'),
    mentionEveryone: ('Mention @everyone', 'Notify every member at once'),
    manageMessages: ('Manage messages', 'Delete and pin other people\'s messages'),
    connect: ('Connect', 'Join voice channels'),
    speak: ('Speak', 'Talk in voice channels'),
    stream: ('Video / screen share', 'Share your screen or camera'),
    muteMembers: ('Mute members', 'Mute others in voice'),
    createInvite: ('Create invites', 'Invite people to this server'),
    kickMembers: ('Kick & time out', 'Remove or silence members'),
    banMembers: ('Ban members', 'Permanently remove members'),
    manageChannels: ('Manage channels', 'Create, edit and delete channels'),
    manageRoles: ('Manage roles', 'Create roles and assign them to lower roles'),
    manageGuild: ('Manage server', 'Change name, icon, banner and see the audit log'),
    manageEmojis: ('Manage emoji', 'Add and remove custom emoji'),
    administrator: ('Administrator', 'Everything, and bypasses all other checks'),
  };
}

class ChannelKind {
  static const text = 0, voice = 1, category = 2, dm = 3, groupDm = 4, announcement = 5;
}

class Profile {
  String bio;
  String status;
  int? accent; // ARGB
  BlobRef? avatar, banner;
  Map<String, dynamic> extra; // theme, effects, pronouns...

  Profile({this.bio = '', this.status = '', this.accent, this.avatar, this.banner, Map<String, dynamic>? extra}) : extra = extra ?? {};

  Map<String, dynamic> toJson() => {
        'bio': bio,
        'status': status,
        if (accent != null) 'accent': accent,
        if (avatar != null) 'avatar': avatar!.toJson(),
        if (banner != null) 'banner': banner!.toJson(),
        'extra': extra,
      };

  static Profile from(Map<String, dynamic>? j) => j == null
      ? Profile()
      : Profile(
          bio: (j['bio'] as String?) ?? '',
          status: (j['status'] as String?) ?? '',
          accent: (j['accent'] as num?)?.toInt(),
          avatar: BlobRef.from(j['avatar']),
          banner: BlobRef.from(j['banner']),
          extra: (j['extra'] as Map?)?.cast<String, dynamic>() ?? {},
        );
}

class UserModel {
  final String id, username, edPublic, xPublic;
  String displayName;
  String presence; // online | idle | dnd | offline
  String? profileCipher;
  int profileVersion;
  Profile profile = Profile();
  bool profileLocked = true; // true until we hold the person's profile key

  UserModel(Map<String, dynamic> j)
      : id = j['id'],
        username = j['username'],
        displayName = j['displayName'],
        edPublic = j['identityPublicKey'],
        xPublic = j['agreementPublicKey'],
        presence = (j['presence'] as String?) ?? 'offline',
        profileCipher = j['profileCipher'],
        profileVersion = (j['profileVersion'] as num?)?.toInt() ?? 0;

  bool get online => presence != 'offline';
  String get name => displayName.isEmpty ? username : displayName;
}

class RoleModel {
  final String id;
  String name;
  int color; // ARGB, 0 = none
  int permissions, position;
  final bool isEveryone;
  BlobRef? icon;
  bool hoist;
  RoleModel(this.id, this.name, this.color, this.permissions, this.position, this.isEveryone, {this.icon, this.hoist = false});
}

class MemberModel {
  final String userId;
  List<String> roleIds;
  String? nick;
  DateTime joinedAt;
  DateTime? timeoutUntil;
  MemberModel(this.userId, this.roleIds, this.joinedAt, {this.nick, this.timeoutUntil});
  bool get timedOut => timeoutUntil != null && timeoutUntil!.isAfter(DateTime.now());
}

class ChannelModel {
  final String id;
  final String? guildId;
  final int kind;
  String? parentId;
  int position, keyVersion, slowmode;
  bool restricted;
  String name, topic;
  String? ownerId;
  List<String> members; // only for DMs and private channels
  ChannelModel({
    required this.id,
    this.guildId,
    required this.kind,
    this.parentId,
    this.position = 0,
    this.keyVersion = 1,
    this.slowmode = 0,
    this.restricted = false,
    this.name = '',
    this.topic = '',
    this.ownerId,
    this.members = const [],
  });

  bool get isText => kind == ChannelKind.text || kind == ChannelKind.dm || kind == ChannelKind.groupDm || kind == ChannelKind.announcement;
  bool get isVoice => kind == ChannelKind.voice;
  bool get isCategory => kind == ChannelKind.category;
  bool get isDm => kind == ChannelKind.dm || kind == ChannelKind.groupDm;
  bool get canCall => isVoice || isDm;
}

class AssetModel {
  final String id, kind, blobId;
  String name;
  bool animated;
  final BlobRef? ref; // where the picture is + its key
  AssetModel(this.id, this.kind, this.blobId, this.name, this.animated, this.ref);
}

class GuildModel {
  final String id;
  String ownerId;
  int keyVersion;
  String name, description;
  BlobRef? icon, banner, background;
  int? accent;
  final Map<String, RoleModel> roles = {};
  final Map<String, MemberModel> members = {};
  final Map<String, ChannelModel> channels = {};
  final Map<String, AssetModel> assets = {};
  bool keysMissing = false; // we are a member but nobody has sealed the key to us yet

  GuildModel(this.id, this.ownerId, this.keyVersion, {this.name = '', this.description = ''});

  RoleModel? get everyone => roles.values.where((r) => r.isEveryone).firstOrNull;

  int permsOf(String userId) {
    if (userId == ownerId) return Perm.all;
    final m = members[userId];
    if (m == null) return 0;
    var p = everyone?.permissions ?? 0;
    for (final r in m.roleIds) {
      p |= roles[r]?.permissions ?? 0;
    }
    return (p & Perm.administrator) != 0 ? Perm.all : p;
  }

  bool can(String userId, int perm) => (permsOf(userId) & perm) == perm;

  int rankOf(String userId) {
    if (userId == ownerId) return 1 << 30;
    final m = members[userId];
    var best = 0;
    for (final r in m?.roleIds ?? const <String>[]) {
      final pos = roles[r]?.position ?? 0;
      if (pos > best) best = pos;
    }
    return best;
  }

  /// The colour of the member's highest coloured role, like Discord.
  int? colorOf(String userId) {
    final m = members[userId];
    RoleModel? best;
    for (final r in m?.roleIds ?? const <String>[]) {
      final role = roles[r];
      if (role != null && role.color != 0 && (best == null || role.position > best.position)) best = role;
    }
    return best?.color;
  }

  RoleModel? topRole(String userId) {
    final m = members[userId];
    RoleModel? best;
    for (final r in m?.roleIds ?? const <String>[]) {
      final role = roles[r];
      if (role != null && (best == null || role.position > best.position)) best = role;
    }
    return best;
  }

  List<ChannelModel> get sortedChannels => channels.values.toList()
    ..sort((a, b) => a.position != b.position ? a.position.compareTo(b.position) : a.id.compareTo(b.id));
}

class ReactionModel {
  final String tag;
  String emoji;
  final Set<String> users;
  ReactionModel(this.tag, this.emoji, this.users);
}

class MessageModel {
  final int id;
  final String channelId, senderId;
  final DateTime createdAt;
  DateTime? editedAt;
  bool pinned, deleted;
  int? replyTo;
  int keyVersion;
  Map<String, dynamic>? content; // null = could not decrypt / verify
  bool waitingForKey; // we do not hold this key version yet
  List<ReactionModel> reactions;

  MessageModel({
    required this.id,
    required this.channelId,
    required this.senderId,
    required this.createdAt,
    this.editedAt,
    this.pinned = false,
    this.deleted = false,
    this.replyTo,
    this.keyVersion = 1,
    this.content,
    this.waitingForKey = false,
    this.reactions = const [],
  });

  String get text => (content?['x'] as String?) ?? '';
  List<BlobRef> get files => [for (final f in (content?['f'] as List?) ?? const []) ?BlobRef.from(f)];
  List<String> get mentions => ((content?['m'] as List?) ?? const []).cast<String>();
  bool get mentionsEveryone => content?['ev'] == true;
  String? get sticker => content?['st'] as String?;
}
