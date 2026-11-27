import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pub_semver/pub_semver.dart';

/// Platforms that can install an update package themselves. iOS is absent on
/// purpose: the App Store and TestFlight deliver their own updates.
enum UpdatePlatform {
  macosArm64,
  windowsX64,
  androidArm64,
  androidArm,
  unsupported;

  static UpdatePlatform get current => switch (Abi.current()) {
    Abi.macosArm64 => macosArm64,
    Abi.windowsX64 => windowsX64,
    Abi.androidArm64 => androidArm64,
    Abi.androidArm => androidArm,
    _ => unsupported,
  };

  bool get isDesktop => this == macosArm64 || this == windowsX64;

  List<String> get assetNames => switch (this) {
    macosArm64 => const ['DropDrawer-macOS-arm64.dmg', 'DropDrawer-macOS.dmg'],
    windowsX64 => const ['DropDrawer-Windows-x64-Setup.exe'],
    // An arm64 install from the split APK has a higher version code than the
    // universal APK, so it must keep updating from the split APK.
    androidArm64 => const [
      'DropDrawer-Android-arm64.apk',
      'DropDrawer-Android-universal.apk',
    ],
    androidArm => const ['DropDrawer-Android-universal.apk'],
    unsupported => const [],
  };
}

/// The version this build reports, and whether it is a tagged release build.
///
/// Only release builds take part in updates. A build made without
/// `--dart-define=DROPDRAWER_RELEASE_TAG=vX.Y.Z[-pre]` (local development, an
/// untagged CI run) cannot tell which release it corresponds to: `0.1.0` would
/// otherwise rank above every `0.1.0-preview.N` and never be offered one.
class InstalledBuild {
  final Version? version;
  final bool isRelease;

  const InstalledBuild(this.version, {required this.isRelease});

  static const _tag = String.fromEnvironment('DROPDRAWER_RELEASE_TAG');

  static InstalledBuild fromPackage(PackageInfo info, {String releaseTag = _tag}) {
    final base = AppUpdateService.parseVersion(info.version);
    final tagged = AppUpdateService.parseVersion(releaseTag);
    if (base == null || tagged == null) {
      return InstalledBuild(base, isRelease: false);
    }
    final sameRelease = (tagged.major, tagged.minor, tagged.patch) ==
        (base.major, base.minor, base.patch);
    return InstalledBuild(
      sameRelease ? tagged : base,
      isRelease: sameRelease,
    );
  }
}

class AppUpdate {
  final Version version;
  final Uri releasePage;
  final ReleaseAsset package;

  const AppUpdate(this.version, this.releasePage, this.package);
}

class ReleaseAsset {
  final String name;
  final Uri url;
  final int size;
  final String sha256Digest;
  final Uri? mirrorUrl;

  const ReleaseAsset(
    this.name,
    this.url,
    this.size,
    this.sha256Digest, {
    this.mirrorUrl,
  });
}

/// Why a check or download failed, in terms a person can act on.
enum UpdateFailure { offline, rateLimited, unavailable, corrupted }

class UpdateException implements Exception {
  final UpdateFailure reason;
  final DateTime? retryAfter;

  const UpdateException(this.reason, {this.retryAfter});

  @override
  String toString() => 'UpdateException($reason)';
}

typedef UpdateCheck = ({AppUpdate? update, bool hasNewerRelease});

class AppUpdateService {
  static const _repo = '/StackTao/DropDrawer/releases';
  static const cacheFolder = 'dropdrawer-updates';
  static const _timeout = Duration(seconds: 20);
  static const _mirrorTimeout = Duration(seconds: 6);
  static const _mirrorHost = 'drop.stacktao.cn';
  static const _mirrorPath = '/api/updates/download/';
  static const _assetHosts = {
    'github.com',
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
  };
  static final _releases = Uri.https('api.github.com', '/repos$_repo', {
    'per_page': '20',
  });
  static final releasesPage = Uri.https('github.com', _repo);
  static final _sha256Digest = RegExp(r'^sha256:([a-f0-9]{64})$');
  static final _safeTag = RegExp(r'^[A-Za-z0-9.+-]+$');

  final http.Client _http;
  final Future<Directory> Function() _tempDir;

  AppUpdateService({http.Client? client, Future<Directory> Function()? tempDir})
      : _http = client ?? http.Client(),
        _tempDir = tempDir ?? getTemporaryDirectory;

  void close() => _http.close();

  static Version? parseVersion(String raw) {
    if (raw.isEmpty) return null;
    try {
      final version = Version.parse(raw.replaceFirst(RegExp(r'^v'), ''));
      // Build metadata (+N) never orders releases.
      return Version(
        version.major,
        version.minor,
        version.patch,
        pre: version.isPreRelease ? version.preRelease.join('.') : null,
      );
    } on FormatException {
      return null;
    }
  }

  Future<UpdateCheck> check(Version installed, UpdatePlatform platform) async {
    final http.Response response;
    try {
      response = await _http
          .get(_releases, headers: {'Accept': 'application/vnd.github+json'})
          .timeout(_timeout);
    } on TimeoutException {
      throw const UpdateException(UpdateFailure.offline);
    } on SocketException {
      throw const UpdateException(UpdateFailure.offline);
    } on http.ClientException {
      throw const UpdateException(UpdateFailure.offline);
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw UpdateException(
        UpdateFailure.rateLimited,
        retryAfter: _rateLimitReset(response.headers),
      );
    }
    if (response.statusCode != 200) {
      throw const UpdateException(UpdateFailure.unavailable);
    }

    final List<dynamic> rows;
    try {
      rows = jsonDecode(response.body) as List<dynamic>;
    } on FormatException {
      throw const UpdateException(UpdateFailure.unavailable);
    }
    final releases = <({String tag, Version version, List<dynamic> assets})>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic> || row['draft'] == true) continue;
      final tag = row['tag_name'];
      final assets = row['assets'];
      if (tag is! String || assets is! List<dynamic> || !_safeTag.hasMatch(tag)) {
        continue;
      }
      final version = parseVersion(tag);
      if (version == null || version <= installed) continue;
      releases.add((tag: tag, version: version, assets: assets));
    }
    releases.sort((a, b) => b.version.compareTo(a.version));

    for (final release in releases) {
      for (final name in platform.assetNames) {
        final asset = _findAsset(release.tag, name, release.assets);
        if (asset == null) continue;
        final page = Uri.https('github.com', '$_repo/tag/${release.tag}');
        return (
          update: AppUpdate(release.version, page, asset),
          hasNewerRelease: true,
        );
      }
    }
    return (update: null, hasNewerRelease: releases.isNotEmpty);
  }

  static DateTime? _rateLimitReset(Map<String, String> headers) {
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    if (reset != null) {
      return DateTime.fromMillisecondsSinceEpoch(reset * 1000);
    }
    final after = int.tryParse(headers['retry-after'] ?? '');
    return after == null ? null : DateTime.now().add(Duration(seconds: after));
  }

  ReleaseAsset? _findAsset(String tag, String name, List<dynamic> assets) {
    for (final asset in assets) {
      if (asset is! Map<String, dynamic> || asset['name'] != name) continue;
      final size = asset['size'];
      final digest = _sha256Digest.firstMatch(
        asset['digest']?.toString() ?? '',
      );
      if (size is! int || size <= 0 || digest == null) continue;
      return ReleaseAsset(
        name,
        Uri.https('github.com', '$_repo/download/$tag/$name'),
        size,
        digest.group(1)!,
        mirrorUrl: Uri.https(_mirrorHost, '$_mirrorPath$tag/$name'),
      );
    }
    return null;
  }

  Future<Directory> _cache() async =>
      Directory(p.join((await _tempDir()).path, cacheFolder));

  /// Deletes previously downloaded packages.
  Future<void> clearDownloads() async {
    try {
      final cache = await _cache();
      if (await cache.exists()) await cache.delete(recursive: true);
    } catch (_) {
      // A package still open by an installer is removed next time; a missing
      // temporary directory means there is nothing to clear.
    }
  }

  /// Downloads the package and checks its size and SHA-256 digest.
  Future<File> download(
    AppUpdate update, {
    required void Function(int received, int total) onProgress,
  }) async {
    final asset = update.package;
    // Only the package being installed is kept on disk.
    await clearDownloads();
    final cache = await _cache();
    await cache.create(recursive: true);
    final folder = await cache.createTemp('package-');
    final file = File(p.join(folder.path, asset.name));
    try {
      final mirror = asset.mirrorUrl;
      if (mirror != null) {
        try {
          await _saveAsset(file, asset, mirror, onProgress);
          return file;
        } on Exception {
          onProgress(0, asset.size);
        }
      }
      await _saveAsset(file, asset, asset.url, onProgress);
      return file;
    } catch (error) {
      await folder.delete(recursive: true);
      if (error is UpdateException) rethrow;
      if (error is FormatException) {
        throw const UpdateException(UpdateFailure.corrupted);
      }
      throw const UpdateException(UpdateFailure.offline);
    }
  }

  Future<void> _saveAsset(
    File file,
    ReleaseAsset asset,
    Uri url,
    void Function(int, int) onProgress,
  ) async {
    final sink = file.openWrite(mode: FileMode.write);
    try {
      await sink.addStream(_assetBytes(asset, url, onProgress));
    } finally {
      await sink.close();
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != asset.sha256Digest) {
      throw const UpdateException(UpdateFailure.corrupted);
    }
  }

  Stream<List<int>> _assetBytes(
    ReleaseAsset asset,
    Uri url,
    void Function(int, int) onProgress,
  ) async* {
    final response = await _openAsset(url);
    var received = 0;
    await for (final chunk in response.stream.timeout(_timeout)) {
      received += chunk.length;
      if (received > asset.size) {
        throw const FormatException('Package is larger than its release metadata');
      }
      onProgress(received, asset.size);
      yield chunk;
    }
    if (received != asset.size) {
      throw const FormatException('Incomplete package download');
    }
  }

  Future<http.StreamedResponse> _openAsset(Uri url) async {
    final mirror = url.host == _mirrorHost;
    for (var hop = 0; hop < 5; hop++) {
      final allowed = mirror
          ? url.path.startsWith(_mirrorPath)
          : _assetHosts.contains(url.host);
      if (!_isHttps(url) || !allowed) {
        throw const FormatException('Untrusted release asset URL');
      }
      final request = http.Request('GET', url)..followRedirects = false;
      final timeout = mirror ? _mirrorTimeout : _timeout;
      final response = await _http.send(request).timeout(timeout);
      if (response.statusCode == 200) return response;
      await response.stream.timeout(timeout).drain<void>();
      final location = response.headers['location'];
      if (mirror ||
          ![301, 302, 303, 307, 308].contains(response.statusCode) ||
          location == null) {
        throw HttpException('Release asset HTTP ${response.statusCode}');
      }
      url = url.resolve(location);
    }
    throw const HttpException('Too many release asset redirects');
  }

  static bool _isHttps(Uri url) =>
      url.scheme == 'https' && url.userInfo.isEmpty && url.port == 443;
}
