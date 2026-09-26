import 'dart:async';
import 'dart:typed_data';

import 'api.dart';
import 'files.dart';

/// Downloads, decrypts and remembers avatars, banners, emoji and image attachments.
/// Everything is decrypted on this device; the cache only ever holds plaintext in memory.
class MediaCache {
  final NyxApi Function() api;
  MediaCache(this.api);

  static const budget = 160 * 1024 * 1024;
  final _cache = <String, Uint8List>{}; // insertion order = age (LinkedHashMap)
  final _pending = <String, Future<Uint8List>>{};
  int _bytes = 0;

  Uint8List? peek(String blobId) => _cache[blobId];

  Future<Uint8List> load(BlobRef ref) {
    final hit = _cache.remove(ref.id);
    if (hit != null) {
      _cache[ref.id] = hit; // refresh recency
      return Future.value(hit);
    }
    return _pending[ref.id] ??= _fetch(ref).whenComplete(() {
      _pending.remove(ref.id);
    });
  }

  Future<Uint8List> _fetch(BlobRef ref) async {
    final res = await api().downloadBlob(ref.id);
    final bytes = await FileCrypto.collect(FileCrypto.decryptStream(ref.secretKey, res.stream));
    _cache[ref.id] = bytes;
    _bytes += bytes.length;
    while (_bytes > budget && _cache.length > 1) {
      final oldest = _cache.keys.first;
      _bytes -= _cache.remove(oldest)!.length;
    }
    return bytes;
  }
}
