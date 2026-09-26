import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyx/core/crypto.dart';
import 'package:nyx/core/files.dart';

void main() {
  test('password derivation is deterministic and splits auth/wrap keys', () async {
    final salt = NyxCrypto.newSalt();
    final a = await NyxCrypto.deriveFromPassword('hunter2', salt);
    final b = await NyxCrypto.deriveFromPassword('hunter2', salt);
    final c = await NyxCrypto.deriveFromPassword('hunter3', salt);
    expect(a.authKey, b.authKey);
    expect(a.authKey, isNot(c.authKey));
    expect(await a.wrappingKey.extractBytes(), await b.wrappingKey.extractBytes());
  });

  test('key backup round-trips (identity + profile key) and rejects the wrong password', () async {
    final salt = NyxCrypto.newSalt();
    final id = await NyxCrypto.generateIdentity();
    final k = await NyxCrypto.deriveFromPassword('pw', salt);
    final backup = await NyxCrypto.exportBackup(id, k.wrappingKey);
    final restored = await NyxCrypto.importBackup(backup, k.wrappingKey);
    expect(restored.publicKeys, id.publicKeys);
    expect(restored.profileKeyBytes, id.profileKeyBytes);
    final wrong = await NyxCrypto.deriveFromPassword('nope', salt);
    expect(() => NyxCrypto.importBackup(backup, wrong.wrappingKey), throwsA(anything));
  });

  test('sealed keys only open for the intended recipient', () async {
    final alice = await NyxCrypto.generateIdentity();
    final bob = await NyxCrypto.generateIdentity();
    final eve = await NyxCrypto.generateIdentity();
    final key = await NyxCrypto.newKey().extractBytes();
    final sealed = await NyxCrypto.sealTo(bob.xPublic, key);
    expect(await NyxCrypto.openSealed(bob, sealed), key);
    expect(() => NyxCrypto.openSealed(eve, sealed), throwsA(anything));
    expect(() => NyxCrypto.openSealed(alice, sealed), throwsA(anything));
  });

  test('encrypted JSON is bound to what it describes (aad) and to the key', () async {
    final key = NyxCrypto.newKey();
    final other = NyxCrypto.newKey();
    final cipher = await NyxCrypto.encryptJson(key, 'guild|1', {'name': 'Book Club', 'n': 3});
    expect((await NyxCrypto.decryptJson(key, 'guild|1', cipher))!['name'], 'Book Club');
    expect(await NyxCrypto.decryptJson(key, 'guild|2', cipher), isNull); // moved onto another object
    expect(await NyxCrypto.decryptJson(other, 'guild|1', cipher), isNull);
    expect(await NyxCrypto.decryptJson(key, 'guild|1', null), isNull);
    expect(await NyxCrypto.decryptJson(key, 'guild|1', 'not-base64!!'), isNull);
  });

  test('reaction tags are stable per channel key and reveal nothing about the emoji', () async {
    final k1 = NyxCrypto.newKey(), k2 = NyxCrypto.newKey();
    expect(await NyxCrypto.reactionTag(k1, '👍'), await NyxCrypto.reactionTag(k1, '👍'));
    expect(await NyxCrypto.reactionTag(k1, '👍'), isNot(await NyxCrypto.reactionTag(k1, '👎')));
    expect(await NyxCrypto.reactionTag(k1, '👍'), isNot(await NyxCrypto.reactionTag(k2, '👍')));
    expect((await NyxCrypto.reactionTag(k1, '👍')).length, greaterThanOrEqualTo(8));
  });

  test('messages: encrypt, verify sender, reject tampering and forgery', () async {
    final alice = await NyxCrypto.generateIdentity();
    final mallory = await NyxCrypto.generateIdentity();
    final key = NyxCrypto.newKey();
    final ct = await NyxCrypto.encryptMessage(channelKey: key, channelId: 'c1', keyVersion: 1, sender: alice, content: {'x': 'hi'});

    Future<Map<String, dynamic>?> open(String ch, int v, String sender, String data) =>
        NyxCrypto.decryptMessage(channelKey: key, channelId: ch, keyVersion: v, senderEdPublicKey: sender, ciphertext: data);

    expect((await open('c1', 1, alice.edPublic, ct))!['x'], 'hi');
    expect(await open('c1', 1, mallory.edPublic, ct), isNull); // wrong claimed sender
    expect(await open('c2', 1, alice.edPublic, ct), isNull); // replayed into another channel
    expect(await open('c1', 2, alice.edPublic, ct), isNull); // wrong key version
    final bytes = NyxCrypto.unb64(ct)..[20] ^= 1;
    expect(await open('c1', 1, alice.edPublic, NyxCrypto.b64(bytes)), isNull); // tampered
  });

  test('call signalling is separate from messages (cannot be replayed as chat)', () async {
    final alice = await NyxCrypto.generateIdentity();
    final key = NyxCrypto.newKey();
    final sig = await NyxCrypto.encryptSignal(channelKey: key, channelId: 'v1', sender: alice, content: {'t': 'offer'});
    expect((await NyxCrypto.decryptSignal(channelKey: key, channelId: 'v1', senderEdPublicKey: alice.edPublic, ciphertext: sig))!['t'], 'offer');
    expect(await NyxCrypto.decryptMessage(channelKey: key, channelId: 'v1', keyVersion: 1, senderEdPublicKey: alice.edPublic, ciphertext: sig), isNull);
  });

  test('file chunks round-trip; reorder and truncation are detected', () async {
    final key = NyxCrypto.newKey();
    final p0 = NyxCrypto.randomBytes(1000), p1 = NyxCrypto.randomBytes(500);
    final c0 = await NyxCrypto.encryptChunk(key, p0, 0, false);
    final c1 = await NyxCrypto.encryptChunk(key, p1, 1, true);
    expect(await NyxCrypto.decryptChunk(key, c0, 0, false), p0);
    expect(await NyxCrypto.decryptChunk(key, c1, 1, true), p1);
    expect(() => NyxCrypto.decryptChunk(key, c1, 0, true), throwsA(anything)); // reordered
    expect(() => NyxCrypto.decryptChunk(key, c0, 0, true), throwsA(anything)); // truncated stream
  });

  test('file streams: any size round-trips, size math matches, truncation and tampering fail', () async {
    for (final n in [0, 1, NyxCrypto.chunkSize - 1, NyxCrypto.chunkSize, NyxCrypto.chunkSize + 1, 2 * NyxCrypto.chunkSize + 123]) {
      final key = NyxCrypto.newKey();
      final data = NyxCrypto.randomBytes(n);
      // Feed the source in awkward slices to exercise re-chunking.
      Stream<List<int>> src() async* {
        for (var i = 0; i < data.length; i += 7777) {
          yield data.sublist(i, i + 7777 > data.length ? data.length : i + 7777);
        }
      }

      final enc = await FileCrypto.collect(FileCrypto.encryptStream(key, src()));
      expect(enc.length, FileCrypto.encryptedSize(n), reason: 'size for $n');
      expect(await FileCrypto.collect(FileCrypto.decryptStream(key, Stream.value(enc))), data, reason: 'round trip $n');

      if (n > NyxCrypto.chunkSize) {
        final cut = Uint8List.sublistView(enc, 0, NyxCrypto.chunkSize + FileCrypto.overhead); // drop the tail
        await expectLater(FileCrypto.collect(FileCrypto.decryptStream(key, Stream.value(cut))), throwsA(anything));
      }
      if (n > 0) {
        final bad = Uint8List.fromList(enc)..[enc.length ~/ 2] ^= 1;
        await expectLater(FileCrypto.collect(FileCrypto.decryptStream(key, Stream.value(bad))), throwsA(anything));
      }
    }
  });

  test('safety number is symmetric', () async {
    final a = await NyxCrypto.generateIdentity();
    final b = await NyxCrypto.generateIdentity();
    expect(await NyxCrypto.safetyNumberFromKeys(a.publicKeys, b.publicKeys), await NyxCrypto.safetyNumberFromKeys(b.publicKeys, a.publicKeys));
  });
}
