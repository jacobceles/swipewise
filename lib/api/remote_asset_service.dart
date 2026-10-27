import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_check_service.dart';

/// ETag-gated HTTP fetch for R2-hosted static assets (brands.json,
/// catalog.json). Files and their ETags are stored side-by-side in the
/// app's documents directory as `<key>.json` and `<key>.etag`.
///
/// Usage pattern:
///   1. Call [readCached] immediately at startup — fast, offline-safe.
///   2. Call [fetchIfUpdated] in the background / after login — downloads only
///      when the server reports a new version (ETag mismatch → 200; same → 304).
class RemoteAssetService {
  // ignore: prefer_initializing_formals
  RemoteAssetService({String baseUrl = _kR2BaseUrl}) : _baseUrl = baseUrl;

  static const _kR2BaseUrl = String.fromEnvironment('R2_BASE_URL');
  final String _baseUrl;

  static String brandsUrl() => '$_kR2BaseUrl/brands.json';
  static String categoriesUrl() => '$_kR2BaseUrl/categories.json';
  static String catalogUrl() => '$_kR2BaseUrl/catalog.json';

  /// Returns the JSON string for [key] if a local file cache exists, else null.
  /// Returns null on any error (plugin unavailable in tests, disk error, etc.).
  Future<String?> readCached(String key) async {
    try {
      final file = await _cacheFile(key);
      if (!file.existsSync()) return null;
      return file.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  /// The `dataVersion` of the cached [key] file, or null if unknown.
  ///
  /// Lets a caller skip reading a large cached file it has already loaded.
  /// Stored as `<key>.version`, beside the ETag.
  Future<int?> cachedDataVersion(String key) async {
    try {
      final f = await _versionFile(key);
      if (!f.existsSync()) return null;
      return int.tryParse(f.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  /// Records [version] as the cached [key] file's `dataVersion`. For a cache
  /// written before versions were stored, once the caller has parsed it.
  Future<void> saveCachedDataVersion(String key, int version) async {
    try {
      await (await _versionFile(key)).writeAsString('$version');
    } catch (_) {}
  }

  /// Fetches [url] with an `If-None-Match` ETag header.
  ///
  /// - **304** → no change; returns null.
  /// - **200** → saves body + new ETag to disk; returns the body string.
  /// - **Any error** → logs and returns null (caller uses existing cache).
  ///
  /// The body is validated as parseable JSON *before* it (or its ETag) is
  /// persisted. A truncated/corrupt 200 body must not be cached alongside a
  /// valid ETag — that would wedge the cache: the next conditional GET returns
  /// 304 and the corrupt body is re-parsed forever until the server changes the
  /// catalog. On parse failure we persist nothing, so the next fetch re-requests.
  Future<String?> fetchIfUpdated(String key, String url) async {
    if (_baseUrl.isEmpty) return null;
    try {
      final etag = await _readEtag(key);
      final headers = <String, String>{};
      if (etag != null) headers['If-None-Match'] = etag;
      // Attest the catalog fetch the same way every other client already does.
      //
      // Deliberately shipped BEFORE the Worker gates these routes, and in that
      // order: enforcement that lands first would 401 every install still on an
      // older build, and because those installs fall back to the bundled
      // offline catalog they would keep working while silently serving stale
      // rewards — the worst kind of breakage, invisible from the outside.
      //
      // A null token is normal (no Play Services, unregistered emulator), so
      // the header is omitted rather than sent empty and the request proceeds.
      // While the routes stay ungated that is indistinguishable from today.
      final token = await AppCheckService.token();
      if (token != null) headers['X-Firebase-AppCheck'] = token;

      final resp = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 20));

      if (resp.statusCode == 304) return null;
      if (resp.statusCode != 200) return null;

      final body = resp.body;
      final Object? decoded;
      try {
        // Off the UI isolate: the catalog is several MB.
        decoded = await compute(json.decode, body);
      } catch (_) {
        // Corrupt/truncated payload — leave body+ETag untouched so the next
        // fetch re-requests instead of caching a poisoned ETag.
        return null;
      }
      // Drop the old version first: a crash between the two writes must leave
      // "version unknown" (read the file), never the old version beside the
      // new body (skipped forever).
      final versionFile = await _versionFile(key);
      if (versionFile.existsSync()) versionFile.deleteSync();
      await _writeCache(key, body);
      final version = decoded is Map ? decoded['dataVersion'] : null;
      if (version is num) await versionFile.writeAsString('${version.toInt()}');
      final newEtag = resp.headers['etag'];
      if (newEtag != null) await _writeEtag(key, newEtag);
      return body;
    } catch (_) {
      return null;
    }
  }

  Future<File> _cacheFile(String key) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$key.json');
  }

  Future<File> _etagFile(String key) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$key.etag');
  }

  Future<File> _versionFile(String key) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$key.version');
  }

  Future<String?> _readEtag(String key) async {
    final f = await _etagFile(key);
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  }

  Future<void> _writeCache(String key, String body) async {
    final f = await _cacheFile(key);
    await f.writeAsString(body);
  }

  Future<void> _writeEtag(String key, String etag) async {
    final f = await _etagFile(key);
    await f.writeAsString(etag);
  }
}
