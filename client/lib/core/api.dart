import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final int status;
  final String message;
  final Map<String, dynamic> body;
  ApiException(this.status, this.message, [this.body = const {}]);
  bool get needsTwoFactor => body['twoFactor'] == true;
  @override
  String toString() => message;
}

/// HTTP client for the Nyx server. Access tokens live 15 minutes; this renews them transparently with the
/// rotating refresh token (one renewal at a time, even when many requests notice at once).
class NyxApi {
  String baseUrl;
  String? accessToken;
  String? refreshToken;

  /// Called whenever tokens change, so the app can persist them.
  void Function(String access, String refresh)? onTokens;

  /// Called when the session is no longer valid (revoked, expired, refresh reuse detected).
  void Function()? onSessionLost;

  NyxApi(this.baseUrl, {this.accessToken, this.refreshToken});

  Future<bool>? _refreshing;

  Uri uri(String path, [Map<String, dynamic>? q]) => _u(path, q);

  Uri _u(String path, [Map<String, dynamic>? q]) => Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), '') + path)
      .replace(queryParameters: q?.map((k, v) => MapEntry(k, '$v')));

  static DateTime? _expiry(String? jwt) {
    try {
      final payload = jwt!.split('.')[1];
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload)))) as Map;
      return DateTime.fromMillisecondsSinceEpoch((json['exp'] as int) * 1000, isUtc: true);
    } catch (_) {
      return null;
    }
  }

  /// A token that is valid for at least another minute (renews first if needed). Used by the live connection too.
  Future<String?> validToken() async {
    final exp = _expiry(accessToken);
    if (accessToken == null || exp == null || exp.difference(DateTime.now().toUtc()) < const Duration(minutes: 1)) {
      if (refreshToken != null) await _refresh();
    }
    return accessToken;
  }

  Future<bool> _refresh() => _refreshing ??= () async {
        try {
          final res = await http.post(_u('/api/auth/refresh'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'refreshToken': refreshToken}));
          if (res.statusCode == 200) {
            final j = jsonDecode(res.body) as Map<String, dynamic>;
            accessToken = j['accessToken'];
            refreshToken = j['refreshToken'];
            onTokens?.call(accessToken!, refreshToken!);
            return true;
          }
          if (res.statusCode == 401) {
            accessToken = refreshToken = null;
            onSessionLost?.call();
          }
          return false;
        } catch (_) {
          return false; // offline: keep the tokens, try again later
        } finally {
          _refreshing = null;
        }
      }();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      };

  dynamic _decode(http.Response r) {
    dynamic body;
    try {
      body = r.body.isEmpty ? null : jsonDecode(r.body);
    } catch (_) {}
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    var msg = 'Request failed (${r.statusCode})';
    if (body is Map && body['error'] is String) msg = body['error'];
    if (r.statusCode == 429 && !(body is Map && body['error'] is String)) msg = 'Too many requests, slow down.';
    throw ApiException(r.statusCode, msg, body is Map<String, dynamic> ? body : const {});
  }

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, dynamic>? query, bool auth = true}) async {
    if (auth) await validToken();
    Future<http.Response> once() async {
      final req = http.Request(method, _u(path, query))..headers.addAll(_headers);
      if (body != null) req.body = jsonEncode(body);
      return http.Response.fromStream(await req.send());
    }

    var res = await once();
    if (res.statusCode == 401 && auth && refreshToken != null && await _refresh()) res = await once();
    return _decode(res);
  }

  Future<dynamic> get(String path, [Map<String, dynamic>? query]) => _send('GET', path, query: query);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body ?? const {});
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body: body ?? const {});
  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// Requests that must work without being signed in (login, register, salt).
  Future<dynamic> anon(String method, String path, {Object? body, Map<String, dynamic>? query}) =>
      _send(method, path, body: body, query: query, auth: false);

  void setTokens(String access, String refresh) {
    accessToken = access;
    refreshToken = refresh;
    onTokens?.call(access, refresh);
  }

  // ------------------------------------------------------------------ blobs

  static const partSize = 32 * 1024 * 1024;

  /// Uploads already-encrypted [chunks] (of [totalSize] bytes) in parts, retrying failed parts. Returns the blob id.
  Future<String> uploadBlob({
    required int scope,
    required String scopeId,
    required int totalSize,
    required Stream<List<int>> chunks,
    void Function(int sent)? onProgress,
  }) async {
    final id = (await post('/api/blobs/uploads', {'scope': scope, 'scopeId': scopeId, 'size': totalSize}))['id'] as String;
    final buf = BytesBuilder(copy: false);
    var part = 0, sent = 0;

    Future<void> flush() async {
      final data = buf.takeBytes();
      for (var attempt = 1;; attempt++) {
        try {
          await validToken();
          final res = await http.put(_u('/api/blobs/uploads/$id/$part'),
              headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/octet-stream'}, body: data);
          _decode(res);
          break;
        } catch (e) {
          final retryable = e is! ApiException || e.status >= 500 || e.status == 429 || e.status == 401;
          if (attempt >= 4 || !retryable) {
            try {
              await delete('/api/blobs/uploads/$id');
            } catch (_) {}
            rethrow;
          }
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
      part++;
      sent += data.length;
      onProgress?.call(sent);
    }

    await for (final c in chunks) {
      buf.add(c);
      if (buf.length >= partSize) await flush();
    }
    if (buf.length > 0 || part == 0) await flush();
    await post('/api/blobs/uploads/$id/complete', {'parts': part});
    return id;
  }

  Future<http.StreamedResponse> downloadBlob(String id) async {
    await validToken();
    final req = http.Request('GET', _u('/api/blobs/$id'))..headers['Authorization'] = 'Bearer $accessToken';
    final res = await req.send();
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'Download failed (${res.statusCode})');
    return res;
  }

  /// Authenticated GET of a binary response (GIF picker pictures).
  Future<Uint8List> getBytes(String path) async {
    await validToken();
    final res = await http.get(_u(path), headers: {'Authorization': 'Bearer $accessToken'});
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'Request failed (${res.statusCode})');
    return res.bodyBytes;
  }

  Future<Uint8List> downloadBytes(String id) async {
    final res = await downloadBlob(id);
    return Uint8List.fromList(await res.stream.expand((c) => c).toList());
  }
}
