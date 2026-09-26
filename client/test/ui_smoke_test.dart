// Renders the whole interface from a hand-built state (no network) at phone / tablet / desktop sizes and
// opens every settings tab and dialog. Any layout overflow or exception fails the test.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nyx/core/crypto.dart';
import 'package:nyx/core/files.dart';
import 'package:nyx/core/models.dart';
import 'package:nyx/main.dart';
import 'package:nyx/state/app_state.dart';
import 'package:nyx/theme/nyx_theme.dart';
import 'package:nyx/ui/dialogs.dart';
import 'package:nyx/ui/emoji_picker.dart';
import 'package:nyx/ui/message_tile.dart';
import 'package:nyx/ui/settings_guild.dart';
import 'package:nyx/ui/settings_user.dart';
import 'package:nyx/ui/shell.dart';

UserModel person(String id, String name, {String presence = 'online', Profile? profile}) => UserModel({
      'id': id,
      'username': name.toLowerCase(),
      'displayName': name,
      'identityPublicKey': 'ed-$id',
      'agreementPublicKey': 'x-$id',
      'presence': presence,
    })..profile = profile ?? Profile(bio: 'Loves long walks and end-to-end encryption.', status: 'reading', accent: 0xFF3FA7FF);

Future<AppState> fixture() async {
  FlutterSecureStorage.setMockInitialValues({});
  final app = AppState();
  await app.init();
  app.identity = await NyxCrypto.generateIdentity();
  final me = person('me', 'Alice');
  app.users.addAll({
    'me': me,
    'bob': person('bob', 'Bob'),
    'cy': person('cy', 'Cy the Very Long Named Person', presence: 'idle'),
    'di': person('di', 'Di', presence: 'offline'),
  });
  app.me = me;
  app.isInstanceAdmin = true;

  final g = GuildModel('g1', 'me', 1, name: 'Book Club With A Rather Long Server Name', description: 'We read things.')..accent = 0xFFFF7A59;
  g.roles['everyone'] = RoleModel('everyone', '@everyone', 0, Perm.everyone, 0, true);
  g.roles['mod'] = RoleModel('mod', 'Moderator', 0xFF42E8B4, Perm.kickMembers | Perm.manageMessages | Perm.sendMessages, 5, false, hoist: true);
  g.members['me'] = MemberModel('me', [], DateTime.now().subtract(const Duration(days: 40)));
  g.members['bob'] = MemberModel('bob', ['mod'], DateTime.now().subtract(const Duration(days: 3)));
  g.members['cy'] = MemberModel('cy', [], DateTime.now(), timeoutUntil: DateTime.now().add(const Duration(hours: 1)));
  g.members['di'] = MemberModel('di', [], DateTime.now());
  g.channels['cat'] = ChannelModel(id: 'cat', guildId: 'g1', kind: ChannelKind.category, name: 'Text channels');
  g.channels['general'] = ChannelModel(id: 'general', guildId: 'g1', kind: ChannelKind.text, parentId: 'cat', position: 1, name: 'general', topic: 'Where we talk about books and other things');
  g.channels['secret'] = ChannelModel(id: 'secret', guildId: 'g1', kind: ChannelKind.text, parentId: 'cat', position: 2, name: 'spoilers', restricted: true, members: ['me', 'bob']);
  g.channels['voice'] = ChannelModel(id: 'voice', guildId: 'g1', kind: ChannelKind.voice, position: 3, name: 'Lounge');
  app.guilds['g1'] = g;
  app.dms['dm1'] = ChannelModel(id: 'dm1', kind: ChannelKind.dm, members: ['me', 'bob']);
  app.dms['dm2'] = ChannelModel(id: 'dm2', kind: ChannelKind.groupDm, name: 'plot twists', members: ['me', 'bob', 'cy'], ownerId: 'me');

  MessageModel msg(int id, String ch, String from, String text, {int? reply, bool pinned = false, List<ReactionModel>? r, List<BlobRef>? files, int minutesAgo = 5}) => MessageModel(
        id: id,
        channelId: ch,
        senderId: from,
        createdAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
        replyTo: reply,
        pinned: pinned,
        reactions: r ?? const [],
        content: {'x': text, if (files != null) 'f': [for (final f in files) f.toJson()]},
      );
  final long = List.filled(30, 'a very long sentence that has to wrap around nicely').join(' ');
  for (final ch in ['general', 'dm1', 'dm2', 'secret']) {
    app.messages[ch] = [
      msg(1, ch, 'bob', 'Hello **everyone**, _welcome_ to `the club`!\n> a quote\n```\ncode block\n```', minutesAgo: 900),
      msg(2, ch, 'me', 'Reading ||the ending|| tonight :) https://example.com/some/really/long/link/that/keeps/going', minutesAgo: 30),
      msg(3, ch, 'me', 'second in a row', minutesAgo: 29),
      msg(4, ch, 'bob', '@Alice thanks!', reply: 2, r: [ReactionModel('t1', 'ðŸ‘', {'me', 'bob'}), ReactionModel('t2', 'ðŸŽ‰', {'cy'})], pinned: true, minutesAgo: 20),
      msg(5, ch, 'cy', long, minutesAgo: 10),
      msg(6, ch, 'bob', 'ðŸ˜€ðŸ˜€ðŸ˜€', minutesAgo: 9),
      msg(7, ch, 'bob', 'see file', files: [const BlobRef(id: 'nope', key: 'AAAA', mime: 'application/pdf', name: 'a-really-long-file-name-for-testing-overflow.pdf', size: 2500000)], minutesAgo: 8),
    ];
    app.hasMoreHistory[ch] = false;
    app.lastMsg[ch] = 7;
    app.lastRead[ch] = 5;
  }
  app.lastRead['secret'] = 7;
  app.voiceRooms['voice'] = [VoiceParticipant('bob', false, false, false), VoiceParticipant('cy', true, false, true)];
  for (final id in ['g1', 'general', 'secret', 'voice', 'dm1', 'dm2']) {
    app.debugSetKey(id, 1, NyxCrypto.newKey());
  }
  app.guildId = 'g1';
  app.channelId = 'general';
  app.ready = true;
  return app;
}

Future<void> settle(WidgetTester t, [int ms = 600]) async {
  await t.pump(const Duration(milliseconds: 50));
  await t.pump(Duration(milliseconds: ms));
}

/// Fails with the step's name if anything threw (overflow, assertion...) while it ran.
void check(WidgetTester t, String step) {
  final errors = <String>[];
  Object? e;
  while ((e = t.takeException()) != null) {
    errors.add(e.toString().split('\n').first);
  }
  if (errors.isNotEmpty) fail('[$step] ${errors.join(' | ')}');
}

void setSize(WidgetTester t, double w, double h) {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
}

void main() {
  SharedPreferences.setMockInitialValues({}); // the theme controller saves through it
  for (final size in [const Size(390, 800), const Size(820, 700), const Size(1400, 900)]) {
    testWidgets('main screens render without overflow at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
      setSize(t, size.width, size.height);
      addTearDown(t.view.resetPhysicalSize);
      final app = await fixture();
      await t.pumpWidget(NyxApp(app: app, theme: ThemeController()));
      await settle(t);
      check(t, 'initial server view');
      expect(find.byType(Shell), findsOneWidget);
      expect(find.textContaining('Message #general'), findsOneWidget);

      // Server text channel with mentions, replies, reactions, pins, quotes, code, spoilers, long text.
      expect(find.byType(MessageTile), findsWidgets);

      // Direct messages (home), group DM, private channel, voice lobby.
      for (final id in ['dm1', 'dm2', 'secret', 'voice', 'general']) {
        await app.openChannel(id);
        await settle(t);
        check(t, 'channel $id');
      }
      app.friends.add('bob');
      app.incomingFriends.add('cy');
      await app.selectGuild(null);
      await settle(t);
      check(t, 'home (friends)');
      await app.openChannel('dm2');
      await settle(t);
      check(t, 'group dm');
      await app.selectGuild('g1');
      await settle(t);
      check(t, 'back to server');
    });
  }

  for (final size in [const Size(390, 800), const Size(1400, 900)]) {
    testWidgets('every settings tab and dialog opens cleanly at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
      setSize(t, size.width, size.height);
      addTearDown(t.view.resetPhysicalSize);
      final app = await fixture();
      await t.pumpWidget(NyxApp(app: app, theme: ThemeController()));
      await settle(t);
      final ctx = t.element(find.byType(Shell));

      Future<void> closeTop() async {
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, 350);
      }

      // User settings: click through every tab.
      showUserSettings(ctx);
      await settle(t);
      final tabs = ['Profile', 'Security', 'Appearance', 'Theme packs', 'Voice & video', 'This instance', 'About', 'Log out'];
      for (final title in tabs) {
        final tab = find.text(title);
        if (tab.evaluate().isEmpty) {
          // Narrow layout: tabs live in a dropdown.
          await t.tap(find.byType(DropdownButton<int>).first);
          await settle(t, 300);
          await t.tap(find.text(title).last);
        } else {
          await t.tap(tab.first);
        }
        await settle(t, 400);
        check(t, 'user settings > $title');
      }
      await closeTop();

      // Server settings: every tab.
      showGuildSettings(ctx, 'g1');
      await settle(t);
      for (final title in ['Overview', 'Roles', 'Channels', 'Emoji', 'Members', 'Invites', 'Bans', 'Audit log', 'Delete server']) {
        final tab = find.text(title);
        if (tab.evaluate().isEmpty) {
          await t.tap(find.byType(DropdownButton<int>).first);
          await settle(t, 300);
          await t.tap(find.text(title).last);
        } else {
          await t.tap(tab.first);
        }
        await settle(t, 400);
        check(t, 'server settings > $title');
      }
      await closeTop();

      // Dialogs.
      final dialogs = <String, void Function()>{
        'add server': () => showAddServer(ctx),
        'create server': () => showCreateGuild(ctx),
        'join server': () => showJoinGuild(ctx),
        'new dm': () => showNewDm(ctx),
        'create channel': () => showCreateChannel(ctx, app.guilds['g1']!),
        'edit channel': () => showEditChannel(ctx, app.guilds['g1']!.channels['general']!),
        'profile': () => showProfile(ctx, 'bob'),
        'verify': () => showVerify(ctx, 'bob'),
        'pins': () => showPins(ctx, app.guilds['g1']!.channels['general']!),
        'search': () => showChannelSearch(ctx, app.guilds['g1']!.channels['general']!),
        'add to group': () => showAddToGroup(ctx, app.dms['dm2']!),
        'member roles': () => showMemberRoles(ctx, app.guilds['g1']!, 'cy'),
        'invite': () => showInvite(ctx, app.guilds['g1']!),
        'emoji picker': () => showEmojiPicker(ctx, guild: app.guilds['g1'], channelId: 'general'),
        'presence menu': () => showPresenceMenu(ctx, const Offset(40, 700)),
      };
      for (final e in dialogs.entries) {
        e.value();
        await settle(t);
        check(t, 'dialog: ${e.key}');
        await closeTop();
      }
    });
  }

  testWidgets('themes: every preset and both message styles render', (t) async {
    setSize(t, 1200, 800);
    addTearDown(t.view.resetPhysicalSize);
    final app = await fixture();
    final theme = ThemeController();
    await t.pumpWidget(NyxApp(app: app, theme: theme));
    await settle(t);
    for (final p in presets) {
      await theme.replace(p.settings.copy()..messageStyle = MessageStyle.bubbles);
      await settle(t, 300);
      await theme.replace(p.settings.copy()..backgroundKind = BackgroundKind.gradient..compact = true..fontScale = 1.5);
      await settle(t, 300);
    }
    await theme.update((s) => s.reduceMotion = true);
    await settle(t);
  });
}


