import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto.dart';

/// Points at an encrypted blob on the server plus the key that opens it. Lives inside encrypted
/// messages / profiles / server settings, so the server never sees the key.
class BlobRef {
  final String id, key, mime, name;
  final int size; // plaintext size in bytes

  /// Non-destructive crop for avatars / banners / icons: the file is stored untouched (full quality, animation
  /// intact) and this says which part to show. [zoom] >= 1 on top of "cover"; [cx]/[cy] = the point of the picture
  /// (0..1) that sits in the middle of the frame.
  final double zoom, cx, cy;
  const BlobRef({required this.id, required this.key, this.mime = 'application/octet-stream', this.name = '', this.size = 0, this.zoom = 1, this.cx = .5, this.cy = .5});

  bool get adjusted => zoom != 1 || cx != .5 || cy != .5;

  BlobRef withAdjust(double zoom, double cx, double cy) => BlobRef(id: id, key: key, mime: mime, name: name, size: size, zoom: zoom.clamp(1, 8).toDouble(), cx: cx.clamp(0, 1).toDouble(), cy: cy.clamp(0, 1).toDouble());

  Map<String, dynamic> toJson() => {
        'id': id,
        'key': key,
        'mime': mime,
        'name': name,
        'size': size,
        if (adjusted) ...{'z': zoom, 'cx': cx, 'cy': cy},
      };

  static BlobRef? from(dynamic j) {
    if (j is! Map) return null;
    final id = j['id'], key = j['key'];
    if (id is! String || key is! String) return null;
    return BlobRef(
      id: id,
      key: key,
      mime: (j['mime'] as String?) ?? 'application/octet-stream',
      name: (j['name'] as String?) ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      zoom: ((j['z'] as num?)?.toDouble() ?? 1).clamp(1, 8).toDouble(),
      cx: ((j['cx'] as num?)?.toDouble() ?? .5).clamp(0, 1).toDouble(),
      cy: ((j['cy'] as num?)?.toDouble() ?? .5).clamp(0, 1).toDouble(),
    );
  }

  SecretKey get secretKey => SecretKey(NyxCrypto.unb64(key));
  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');
  bool get isAudio => mime.startsWith('audio/');
}

/// Chunked authenticated encryption for files of any size, one megabyte at a time.
class FileCrypto {
  static const overhead = 16;

  /// Size on the wire for [plainSize] bytes.
  static int encryptedSize(int plainSize) {
    final chunks = plainSize == 0 ? 1 : (plainSize + NyxCrypto.chunkSize - 1) ~/ NyxCrypto.chunkSize;
    return plainSize + chunks * overhead;
  }

  static Stream<Uint8List> rechunk(Stream<List<int>> src, int size) async* {
    final buf = BytesBuilder(copy: false);
    await for (final part in src) {
      buf.add(part);
      while (buf.length >= size) {
        final all = buf.takeBytes();
        yield Uint8List.sublistView(all, 0, size);
        buf.add(Uint8List.sublistView(all, size));
      }
    }
    if (buf.length > 0) yield buf.takeBytes();
  }

  static Stream<Uint8List> encryptStream(SecretKey key, Stream<List<int>> src) async* {
    Uint8List? pending;
    var index = 0;
    await for (final block in rechunk(src, NyxCrypto.chunkSize)) {
      if (pending != null) yield await NyxCrypto.encryptChunk(key, pending, index++, false);
      pending = block;
    }
    yield await NyxCrypto.encryptChunk(key, pending ?? Uint8List(0), index, true);
  }

  static Stream<Uint8List> decryptStream(SecretKey key, Stream<List<int>> src) async* {
    Uint8List? pending;
    var index = 0;
    await for (final block in rechunk(src, NyxCrypto.chunkSize + overhead)) {
      if (pending != null) yield await NyxCrypto.decryptChunk(key, pending, index++, false);
      pending = block;
    }
    if (pending == null) throw const FormatException('Empty file');
    yield await NyxCrypto.decryptChunk(key, pending, index, true);
  }

  static Future<Uint8List> collect(Stream<List<int>> s) async {
    final b = BytesBuilder(copy: false);
    await for (final c in s) {
      b.add(c);
    }
    return b.takeBytes();
  }
}

/// A file the user picked, not yet encrypted.
class PickedFile {
  final String name;
  final int size;
  final String mime;
  final Stream<List<int>> Function() open;
  PickedFile(this.name, this.size, this.open, {this.mime = 'application/octet-stream'});

  static PickedFile bytes(String name, Uint8List data, {String mime = 'application/octet-stream'}) =>
      PickedFile(name, data.length, () => Stream.value(data), mime: mime);
}

String guessMime(String name) {
  final e = name.toLowerCase().split('.').last;
  return switch (e) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'mp4' => 'video/mp4',
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    'mp3' => 'audio/mpeg',
    'ogg' => 'audio/ogg',
    'wav' => 'audio/wav',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    _ => 'application/octet-stream',
  };
}
