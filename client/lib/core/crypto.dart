import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// All cryptography lives here. The server only ever sees the outputs of this file.
///
/// - Password -> Argon2id -> 64 bytes: first half authenticates to the server, second half wraps the
///   private-key backup. The server never learns the wrapping key.
/// - Identity = Ed25519 (signatures) + X25519 (key agreement), generated on device.
/// - Guild / channel / profile keys = random 32 bytes, sealed per member to their X25519 public key.
/// - Messages, names, profiles = AES-256-GCM under those keys; messages are also signed by the sender.
/// - Files = chunked AES-256-GCM under a fresh per-file key that lives inside the encrypted message/profile.
class NyxCrypto {
  static final _aes = AesGcm.with256bits();
  static final _x25519 = X25519();
  static final _ed = Ed25519();
  static final _rng = Random.secure();

  static Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));
  static String b64(List<int> b) => base64Encode(b);
  static Uint8List unb64(String s) => base64Decode(s);

  // ---------------------------------------------------------------- password

  /// Returns (authKey, wrappingKey). OWASP minimum Argon2id (19 MiB, t=2, p=1): usable on phones.
  static Future<({String authKey, SecretKey wrappingKey})> deriveFromPassword(String password, String saltB64) async {
    final argon = Argon2id(memory: 19 * 1024, parallelism: 1, iterations: 2, hashLength: 64);
    final out = await (await argon.deriveKeyFromPassword(password: password, nonce: unb64(saltB64))).extractBytes();
    return (authKey: b64(out.sublist(0, 32)), wrappingKey: SecretKey(out.sublist(32)));
  }

  static String newSalt() => b64(randomBytes(16));

  // ---------------------------------------------------------------- identity

  static Future<Identity> generateIdentity() => Identity.fromSeeds(randomBytes(32), randomBytes(32), randomBytes(32));

  /// Private seeds + my profile key, encrypted so the server can store them for new devices.
  static Future<String> exportBackup(Identity id, SecretKey wrappingKey) => _seal(
      wrappingKey,
      utf8.encode(jsonEncode({'ed': b64(id.edSeed), 'x': b64(id.xSeed), 'p': b64(id.profileKeyBytes)})),
      aad: utf8.encode('nyx-backup-v2'));

  static Future<Identity> importBackup(String backup, SecretKey wrappingKey) async {
    final data = jsonDecode(utf8.decode(await _open(wrappingKey, backup, aad: utf8.encode('nyx-backup-v2'))));
    return Identity.fromSeeds(unb64(data['ed']), unb64(data['x']), unb64(data['p']));
  }

  // -------------------------------------------------------------- symmetric keys

  static SecretKey newKey() => SecretKey(randomBytes(32));

  /// Seals [plain] so only the holder of [recipientAgreementPub]'s private key can open it.
  static Future<String> sealTo(String recipientAgreementPub, List<int> plain) async {
    final eph = await _x25519.newKeyPair();
    final shared = await _x25519.sharedSecretKey(
        keyPair: eph, remotePublicKey: SimplePublicKey(unb64(recipientAgreementPub), type: KeyPairType.x25519));
    final ephPub = (await eph.extractPublicKey()).bytes;
    final box = await _seal(await _sealKey(shared), plain, aad: ephPub);
    return b64([...ephPub, ...unb64(box)]);
  }

  static Future<List<int>> openSealed(Identity me, String sealed) async {
    final raw = unb64(sealed);
    final ephPub = raw.sublist(0, 32);
    final shared = await _x25519.sharedSecretKey(
        keyPair: me.xKeyPair, remotePublicKey: SimplePublicKey(ephPub, type: KeyPairType.x25519));
    return _open(await _sealKey(shared), b64(raw.sublist(32)), aad: ephPub);
  }

  static Future<SecretKey> _sealKey(SecretKey shared) =>
      Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey: shared, info: utf8.encode('nyx-seal-v1'), nonce: const []);

  // ------------------------------------------------------------- encrypted JSON

  /// Names, topics, roles, profiles: small JSON documents bound to the thing they describe (aad).
  static Future<String> encryptJson(SecretKey key, String aad, Map<String, dynamic> json) =>
      _seal(key, utf8.encode(jsonEncode(json)), aad: utf8.encode('nyx-json|$aad'));

  static Future<Map<String, dynamic>?> decryptJson(SecretKey key, String aad, String? data) async {
    if (data == null || data.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(await _open(key, data, aad: utf8.encode('nyx-json|$aad')))) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Opaque, deterministic per channel: lets the server deduplicate reactions without learning the emoji.
  static Future<String> reactionTag(SecretKey channelKey, String emoji) async {
    final h = await Hmac.sha256().calculateMac(utf8.encode('react|$emoji'), secretKey: channelKey);
    return b64(h.bytes.sublist(0, 18)).replaceAll('+', '-').replaceAll('/', '_');
  }

  // ---------------------------------------------------------------- messages

  static List<int> _msgAad(String channelId, int keyVersion) => utf8.encode('nyx-msg|$channelId|$keyVersion');

  /// Signs then encrypts. The signature stops another channel member forging messages as someone else.
  static Future<String> encryptMessage({
    required SecretKey channelKey,
    required String channelId,
    required int keyVersion,
    required Identity sender,
    required Map<String, dynamic> content,
  }) async {
    final body = utf8.encode(jsonEncode(content));
    final sig = await _ed.sign([..._msgAad(channelId, keyVersion), ...body], keyPair: sender.edKeyPair);
    final env = utf8.encode(jsonEncode({'c': b64(body), 's': b64(sig.bytes)}));
    return _seal(channelKey, env, aad: _msgAad(channelId, keyVersion));
  }

  /// Returns null if decryption or signature verification fails.
  static Future<Map<String, dynamic>?> decryptMessage({
    required SecretKey channelKey,
    required String channelId,
    required int keyVersion,
    required String senderEdPublicKey,
    required String ciphertext,
  }) async {
    try {
      final aad = _msgAad(channelId, keyVersion);
      final env = jsonDecode(utf8.decode(await _open(channelKey, ciphertext, aad: aad)));
      final body = unb64(env['c']);
      final ok = await _ed.verify([...aad, ...body],
          signature: Signature(unb64(env['s']),
              publicKey: SimplePublicKey(unb64(senderEdPublicKey), type: KeyPairType.ed25519)));
      return ok ? jsonDecode(utf8.decode(body)) as Map<String, dynamic> : null;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------- call signalling

  static Future<String> encryptSignal({
    required SecretKey channelKey,
    required String channelId,
    required Identity sender,
    required Map<String, dynamic> content,
  }) =>
      encryptMessage(channelKey: channelKey, channelId: '$channelId|sig', keyVersion: 0, sender: sender, content: content);

  static Future<Map<String, dynamic>?> decryptSignal({
    required SecretKey channelKey,
    required String channelId,
    required String senderEdPublicKey,
    required String ciphertext,
  }) =>
      decryptMessage(
          channelKey: channelKey,
          channelId: '$channelId|sig',
          keyVersion: 0,
          senderEdPublicKey: senderEdPublicKey,
          ciphertext: ciphertext);

  // ------------------------------------------------------------------- files

  static const chunkSize = 1024 * 1024;

  /// Key is unique per file, so a counter nonce is safe; the final-chunk flag in the AAD stops truncation.
  static Future<Uint8List> encryptChunk(SecretKey fileKey, Uint8List plain, int index, bool last) async {
    final box = await _aes.encrypt(plain, secretKey: fileKey, nonce: _chunkNonce(index), aad: [last ? 1 : 0]);
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  static Future<Uint8List> decryptChunk(SecretKey fileKey, Uint8List enc, int index, bool last) async {
    final mac = Mac(enc.sublist(enc.length - 16));
    return Uint8List.fromList(await _aes.decrypt(SecretBox(enc.sublist(0, enc.length - 16), nonce: _chunkNonce(index), mac: mac),
        secretKey: fileKey, aad: [last ? 1 : 0]));
  }

  static List<int> _chunkNonce(int index) {
    final n = Uint8List(12);
    ByteData.view(n.buffer).setUint64(4, index);
    return n;
  }

  // ------------------------------------------------------------ verification

  static Future<String> safetyNumberFromKeys(String keysA, String keysB) async {
    final sorted = [keysA, keysB]..sort();
    final hash = await Sha256().hash(utf8.encode(sorted.join('|')));
    final digits = hash.bytes.take(15).map((b) => (b % 100).toString().padLeft(2, '0')).join();
    return List.generate(6, (i) => digits.substring(i * 5, i * 5 + 5)).join(' ');
  }

  // ---------------------------------------------------------------- internal

  static Future<String> _seal(SecretKey key, List<int> plain, {List<int> aad = const []}) async =>
      b64((await _aes.encrypt(plain, secretKey: key, aad: aad)).concatenation());

  static Future<List<int>> _open(SecretKey key, String data, {List<int> aad = const []}) =>
      _aes.decrypt(SecretBox.fromConcatenation(unb64(data), nonceLength: 12, macLength: 16), secretKey: key, aad: aad);
}

class Identity {
  final Uint8List edSeed, xSeed, profileKeyBytes;
  final SimpleKeyPair edKeyPair, xKeyPair;
  final String edPublic, xPublic;

  Identity._(this.edSeed, this.xSeed, this.profileKeyBytes, this.edKeyPair, this.xKeyPair, this.edPublic, this.xPublic);

  String get publicKeys => '$edPublic:$xPublic';
  SecretKey get profileKey => SecretKey(profileKeyBytes);

  static Future<Identity> fromSeeds(Uint8List edSeed, Uint8List xSeed, Uint8List profileKey) async {
    final ed = await Ed25519().newKeyPairFromSeed(edSeed);
    final x = await X25519().newKeyPairFromSeed(xSeed);
    return Identity._(edSeed, xSeed, profileKey, ed, x, NyxCrypto.b64((await ed.extractPublicKey()).bytes),
        NyxCrypto.b64((await x.extractPublicKey()).bytes));
  }
}
