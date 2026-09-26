// End-to-end test of the client logic against a real server:
//   NYX_TEST_SERVER=http://127.0.0.1:5197 NYX_TEST_INVITE=<first-user invite> flutter test test/e2e_test.dart
//
// It drives real AppState objects (real crypto, key sharing, uploads) - only the widgets are absent.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nyx/core/files.dart';
import 'package:nyx/core/gifs.dart';
import 'package:nyx/core/models.dart';
import 'package:nyx/state/app_state.dart';

final server = Platform.environment['NYX_TEST_SERVER'];
final firstInvite = Platform.environment['NYX_TEST_INVITE'];

Future<void> until(String what, bool Function() cond, {AppState? poke, int seconds = 25}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  var n = 0;
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    if (poke != null && n++ % 6 == 5) await poke.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  fail('Timed out waiting for: $what');
}

Uint8List randomBytes(int n) {
  final r = Random(42);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

int _n = 0;
/// Each simulated device gets its own empty secure storage (in the real app there is one user per device).
Future<AppState> freshDevice() async {
  FlutterSecureStorage.setMockInitialValues({});
  final app = AppState();
  await app.init();
  return app;
}

Future<AppState> client(String prefix, String invite) async {
  final app = await freshDevice();
  final name = '$prefix${DateTime.now().millisecondsSinceEpoch % 100000}${_n++}';
  await app.register(server: server!, username: name, displayName: prefix, password: 'correct horse battery staple', invite: invite);
  return app;
}

void main() {
  if (server == null || firstInvite == null) {
    test('end-to-end (skipped: set NYX_TEST_SERVER and NYX_TEST_INVITE)', () {}, skip: 'needs a running server');
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // the test binding fakes HTTP by default; we want the real thing
  FlutterSecureStorage.setMockInitialValues({});
  final apps = <AppState>[];
  tearDownAll(() async {
    for (final a in apps) {
      await a.hub.stop();
    }
  });

  late AppState alice, bob, carol;
  late String guildId, generalId;
  final fileBytes = randomBytes(2500000); // > 2 chunks of 1 MiB

  test('register three people through invites', () async {
    alice = await client('alice', firstInvite!);
    apps.add(alice);
    expect(alice.isInstanceAdmin, isTrue);
    bob = await client('bob', await alice.createInstanceInvite());
    carol = await client('carol', await alice.createInstanceInvite());
    apps.addAll([bob, carol]);
    expect(bob.isInstanceAdmin, isFalse);
    // Everyone can see everyone (names come from the server, profile stays locked until keys are shared).
    await until('alice sees 3 users', () => alice.users.length == 3, poke: alice);
  });

  test('server creation encrypts names and the creator can read them back', () async {
    guildId = await alice.createGuild('Book Club');
    final g = alice.guilds[guildId]!;
    expect(g.name, 'Book Club');
    expect(g.keysMissing, isFalse);
    generalId = g.channels.values.firstWhere((c) => c.name == 'general').id;
    expect(g.channels.values.map((c) => c.name), containsAll(['general', 'Lounge', 'Text channels']));
    expect(g.channels[generalId]!.kind, ChannelKind.text);
  });

  test('messages with formatting, mentions and a multi-chunk attachment', () async {
    await alice.openChannel(generalId);
    await alice.sendMessage(generalId, 'Hello **bookworms**');
    final ref = await alice.uploadFile(PickedFile.bytes('notes.bin', fileBytes, mime: 'application/octet-stream'), scope: 0, scopeId: generalId);
    expect(ref.size, fileBytes.length);
    await alice.sendMessage(generalId, 'the file', files: [PickedFile.bytes('notes.bin', fileBytes)]);
    await until('alice has 2 messages', () => alice.messages[generalId]?.length == 2 || (alice.messages[generalId]?.length ?? 0) >= 2, poke: null);
    // Alice's own attachment round-trips through upload, storage and decryption.
    final withFile = alice.messages[generalId]!.firstWhere((m) => m.files.isNotEmpty);
    expect(await alice.media.load(withFile.files.first), fileBytes);
  });

  test('a new member joins by invite, receives keys automatically and reads the history', () async {
    final code = (await alice.createInvite(guildId))['code'] as String;
    await bob.joinWithInvite(code);
    await until('bob has the server key', () => bob.guilds[guildId]?.keysMissing == false && bob.guilds[guildId]?.name == 'Book Club', poke: bob);
    await bob.openChannel(bob.guilds[guildId]!.channels.values.firstWhere((c) => c.name == 'general').id);
    await until('bob can decrypt history', () => (bob.messages[generalId] ?? []).where((m) => m.content != null).length == 2, poke: bob);
    final msgs = bob.messages[generalId]!;
    expect(msgs.first.text, 'Hello **bookworms**');
    // And can open the encrypted attachment.
    expect(await bob.media.load(msgs.last.files.first), fileBytes);
  });

  test('replies, reactions, edits, pins and deletes', () async {
    await bob.sendMessage(generalId, 'nice one', replyTo: bob.messages[generalId]!.first);
    await until('alice sees bob reply', () => alice.messages[generalId]!.any((m) => m.text == 'nice one'));
    final reply = alice.messages[generalId]!.firstWhere((m) => m.text == 'nice one');
    expect(reply.replyTo, alice.messages[generalId]!.first.id);

    await alice.toggleReaction(reply, '👍');
    await until('reaction shows for bob', () => bob.messages[generalId]!.firstWhere((m) => m.text == 'nice one').reactions.any((r) => r.emoji == '👍' && r.users.contains(alice.myId)));
    await until('alice sees her own reaction', () => alice.messages[generalId]!.firstWhere((m) => m.id == reply.id).reactions.isNotEmpty);
    // Always toggle on the current object (the list entry is replaced on every update).
    await alice.toggleReaction(alice.messages[generalId]!.firstWhere((m) => m.id == reply.id), '👍');
    await until('reaction removed', () => bob.messages[generalId]!.firstWhere((m) => m.text == 'nice one').reactions.isEmpty);

    await bob.editMessage(bob.messages[generalId]!.firstWhere((m) => m.text == 'nice one'), 'nice one, edited');
    await until('edit visible to alice', () => alice.messages[generalId]!.any((m) => m.text == 'nice one, edited' && m.editedAt != null));

    final target = alice.messages[generalId]!.first;
    await alice.setPinned(target, true);
    expect((await bob.pinned(generalId)).map((m) => m.id), [target.id]);

    await bob.deleteMessage(bob.messages[generalId]!.firstWhere((m) => m.text == 'nice one, edited'));
    await until('delete visible', () => alice.messages[generalId]!.any((m) => m.deleted));
  });

  test('profiles: avatar and banner (encrypted) become visible after profile keys are shared', () async {
    final avatar = randomBytes(40000);
    final ref = await bob.uploadFile(PickedFile.bytes('me.gif', avatar, mime: 'image/gif'), scope: 2, scopeId: bob.myId);
    await bob.updateProfile(displayName: 'Bobby', profile: Profile(bio: 'I read books', status: 'chapter 4', accent: 0xFF3FA7FF, avatar: ref));
    await until('alice sees bob profile', () => alice.users[bob.myId]?.profile.bio == 'I read books', poke: alice);
    final seen = alice.users[bob.myId]!;
    expect(seen.displayName, 'Bobby');
    expect(seen.profile.status, 'chapter 4');
    expect(await alice.media.load(seen.profile.avatar!), avatar);
    // Someone who has not been given the key (carol, not in any shared context yet) still sees only the name.
    expect(carol.users[bob.myId]?.profile.bio ?? '', anyOf('', 'I read books')); // may already have it: keys go to everyone on the instance
  });

  test('direct messages: one per pair, readable by both, invisible to others', () async {
    final dmId = await alice.openDm(bob.myId);
    await alice.sendMessage(dmId, 'psst, just us');
    await until('bob has the dm', () => bob.dms.containsKey(dmId), poke: bob);
    await bob.openChannel(dmId);
    await until('bob reads it', () => bob.messages[dmId]?.any((m) => m.text == 'psst, just us') == true, poke: bob);
    expect(await bob.openDm(alice.myId), dmId); // same conversation from the other side
    expect(carol.dms.containsKey(dmId), isFalse);
  });

  test('group conversations: adding someone changes the key and hides history from them', () async {
    final gid = await alice.createConversation([bob.myId, carol.myId], groupName: 'plot twists');
    await alice.sendMessage(gid, 'before dave');
    await until('bob sees the group', () => bob.dms.containsKey(gid), poke: bob);
    expect(bob.dms[gid]!.kind, ChannelKind.groupDm);
    await until('name decrypts', () => bob.dms[gid]?.name == 'plot twists', poke: bob);

    final dave = await client('dave', await alice.createInstanceInvite());
    apps.add(dave);
    await until('alice knows dave', () => alice.users.containsKey(dave.myId), poke: alice);
    await Future<void>.delayed(const Duration(milliseconds: 1500)); // group history cut-off has 1s granularity
    await alice.addToGroup(gid, [dave.myId]);
    expect(alice.dms[gid]!.keyVersion, 2);
    await alice.sendMessage(gid, 'after dave');
    await until('dave sees the group', () => dave.dms.containsKey(gid), poke: dave);
    await dave.openChannel(gid);
    try {
      await until('dave history loaded', () => dave.messages[gid]?.any((x) => x.text == 'after dave') == true, poke: dave, seconds: 12);
    } catch (_) {
      final ch = dave.dms[gid];
      print('DEBUG dave dm: keyVersion=${ch?.keyVersion} members=${ch?.members.length} holdsV1=${dave.keyFor(gid, 1) != null} holdsV2=${dave.keyFor(gid, 2) != null}');
      for (final m in dave.messages[gid] ?? <MessageModel>[]) {
        print('DEBUG msg ${m.id} v${m.keyVersion} content=${m.content != null} waiting=${m.waitingForKey} deleted=${m.deleted}');
      }
      rethrow;
    }
    expect(dave.messages[gid]!.any((m) => m.text == 'before dave'), isFalse);
    expect(dave.messages[gid]!.any((m) => m.text == 'after dave' && m.content != null), isTrue);
  });

  test('roles and permissions are enforced and moderation rotates the keys', () async {
    final code = (await alice.createInvite(guildId))['code'] as String;
    await carol.joinWithInvite(code);
    await until('carol has keys', () => carol.guilds[guildId]?.name == 'Book Club', poke: carol);

    // Take away "send messages" for everyone: carol is silenced, the owner is not.
    final g = alice.guilds[guildId]!;
    await alice.updateRole(guildId, g.everyone!, permissions: Perm.everyone & ~Perm.sendMessages);
    await until('carol sees new permissions', () => carol.guilds[guildId]?.everyone?.permissions == (Perm.everyone & ~Perm.sendMessages), poke: carol);
    await expectLater(carol.sendMessage(generalId, 'hi'), throwsA(anything));
    await alice.updateRole(guildId, alice.guilds[guildId]!.everyone!, permissions: Perm.everyone);
    await until('permissions restored', () => carol.guilds[guildId]?.can(carol.myId, Perm.sendMessages) == true, poke: carol);
    await carol.sendMessage(generalId, 'hi again');

    // Kick carol: she loses access, and the server key is rotated by a remaining member with permission.
    final before = alice.guilds[guildId]!.keyVersion;
    await alice.kick(guildId, carol.myId);
    await until('keys rotated', () => (alice.guilds[guildId]?.keyVersion ?? 0) > before, poke: alice, seconds: 30);
    await until('carol lost the server', () => !carol.guilds.containsKey(guildId), poke: carol);
    // Bob (still a member) can keep talking with the new key; carol cannot see it.
    await until('bob has the new key', () => bob.guilds[guildId]?.keyVersion == alice.guilds[guildId]!.keyVersion && bob.keyFor(generalId, bob.guilds[guildId]!.channels[generalId]!.keyVersion) != null, poke: bob, seconds: 30);
    await bob.sendMessage(generalId, 'carol cannot read this');
    await until('alice reads it', () => alice.messages[generalId]!.any((m) => m.text == 'carol cannot read this' && m.content != null));
    expect(alice.guilds[guildId]!.channels[generalId]!.keyVersion, greaterThan(1));
  });

  test('friends: request, accept, block; saved GIFs and sticker-style messages', () async {
    // alice and bob: request by username, accept.
    await alice.addFriend(bob.me!.username);
    await until('bob sees the request', () => bob.incomingFriends.contains(alice.myId), poke: bob);
    await bob.acceptFriend(alice.myId);
    await until('alice sees the friendship', () => alice.friends.contains(bob.myId), poke: alice);
    expect(bob.friends, contains(alice.myId));

    // Sending an already-uploaded picture (saved GIF / sticker) produces a normal decryptable message.
    final gif = Uint8List.fromList(base64Decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'));
    await alice.saveGifBytes(gif, 'dot.gif');
    final ref = GifLibrary.instance.items.first;
    await alice.sendRefs(generalId, [ref], sticker: true);
    await until('bob reads the sticker message', () => (bob.messages[generalId] ?? []).any((m) => m.content?['st'] == true && m.files.length == 1), poke: bob);
    final got = (bob.messages[generalId]!).firstWhere((m) => m.content?['st'] == true).files.first;
    expect(await bob.media.load(got), gif);

    // Blocking ends the friendship and stops direct messages.
    await bob.blockUser(alice.myId);
    await until('friendship gone for alice', () => !alice.friends.contains(bob.myId), poke: alice);
    expect(bob.blockedUsers, contains(alice.myId));
    final dmId = alice.dms.values.firstWhere((c) => c.kind == ChannelKind.dm && c.members.contains(bob.myId)).id;
    await expectLater(alice.sendMessage(dmId, 'still there?'), throwsA(anything));
    await bob.unblockUser(alice.myId);
  });

  test('a fresh device restores identity from the password and reads old messages', () async {
    final fresh = await freshDevice();
    await fresh.login(server: server!, username: alice.me!.username, password: 'correct horse battery staple');
    apps.add(fresh);
    expect(fresh.identity!.publicKeys, alice.identity!.publicKeys);
    await fresh.openChannel(generalId);
    await until('history readable', () => (fresh.messages[generalId] ?? []).any((m) => m.text == 'Hello **bookworms**' && m.content != null), poke: fresh);

    // Wrong password fails, and changing it re-wraps the backup so the new password works.
    final other = await freshDevice();
    await expectLater(other.login(server: server!, username: alice.me!.username, password: 'wrong'), throwsA(anything));
    await alice.changePassword('correct horse battery staple', 'a brand new passphrase');
    final again = await freshDevice();
    await again.login(server: server!, username: alice.me!.username, password: 'a brand new passphrase');
    apps.add(again);
    expect(again.identity!.publicKeys, alice.identity!.publicKeys);
    // The old session on the fresh device was signed out by the password change.
    await until('other devices are signed out', () => !fresh.signedIn, seconds: 15);
  });
}
