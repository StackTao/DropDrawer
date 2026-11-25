import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pub_semver/pub_semver.dart';

enum UpdatePlatform {
  macosArm64,
  windowsX64,
  androidArm64,
  androidArm,
  ios,
  unsupported;

  static UpdatePlatform get current => switch (Abi.current()) {
    Abi.macosArm64 => macosArm64,
    Abi.windowsX64 => windowsX64,
    Abi.androidArm64 => androidArm64,
    Abi.androidArm => androidArm,
    Abi.iosArm64 || Abi.iosX64 => ios,
    _ => unsupported,
  };

  List<String> get assetNames => switch (this) {
    macosArm64 => const ['DropDrawer-macOS-arm64.dmg', 'DropDrawer-macOS.dmg'],
    windowsX64 => const ['DropDrawer-Windows-x64-Setup.exe'],
    androidArm64 => const [
      'DropDrawer-Android-arm64.apk',
      'DropDrawer-Android-universal.apk',
    ],
    androidArm => const ['DropDrawer-Android-universal.apk'],
    ios => const ['DropDrawer-iOS-update.json'],
    unsupported => const [],
  };
}

class AppUpdate {
  final Version version;
  final Uri releasePage;
  final Uri? storeUrl;
  final _ReleaseAsset? _package;

  const AppUpdate._(
    this.version,
    this.releasePage, {
    this.storeUrl,
    this._package,
  });

  int? get packageSize => _package?.size;
}

typedef UpdateCheck = ({AppUpdate? update, bool hasNewerRelease});

class AppUpdateService {
  static const _repo = '/StackTao/DropDrawer/releases';
  static const _cacheName = 'dropdrawer-updates';
  static const _timeout = Duration(seconds: 20);
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

  final http.Client _http;

  AppUpdateService({http.Client? client}) : _http = client ?? http.Client();

  void close() => _http.close();

  static Version? installedVersion(
    PackageInfo info, {
    String releaseTag = const String.fromEnvironment('DROPDRAWER_RELEASE_TAG'),
  }) {
    final base = _parseVersion(info.version);
    final tagged = _parseVersion(releaseTag);
    if (base == null || tagged == null) return base;
    if ((tagged.major, tagged.minor, tagged.patch) ==
        (base.major, base.minor, base.patch)) {
      return tagged;
    }
    return base;
  }

  static Version? _parseVersion(String raw) {
    try {
      final version = Version.parse(raw.replaceFirst(RegExp(r'^v'), ''));
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

  Future<UpdateCheck> check(
    Version installed,
    UpdatePlatform platform, {
    String? iosInstaller,
  }) async {
    final response = await _http
        .get(_releases, headers: {'Accept': 'application/vnd.github+json'})
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw HttpException('GitHub Releases HTTP ${response.statusCode}');
    }

    final releases = <({String tag, Version version, List<dynamic> assets})>[];
    for (final row in jsonDecode(response.body) as List<dynamic>) {
      if (row is! Map<String, dynamic> || row['draft'] == true) continue;
      final tag = row['tag_name'];
      final assets = row['assets'];
      if (tag is! String || assets is! List<dynamic>) continue;
      final version = _parseVersion(tag);
      if (version == null ||
          version <= installed ||
          !RegExp(r'^[A-Za-z0-9.+-]+$').hasMatch(tag)) {
        continue;
      }
      releases.add((tag: tag, version: version, assets: assets));
    }
    releases.sort((a, b) => b.version.compareTo(a.version));

    for (final release in releases) {
      for (final name in platform.assetNames) {
        final asset = _findAsset(release.tag, name, release.assets);
        if (asset == null) continue;
        final page = Uri.https('github.com', '$_repo/tag/${release.tag}');
        if (platform != UpdatePlatform.ios) {
          return (
            update: AppUpdate._(release.version, page, package: asset),
            hasNewerRelease: true,
          );
        }
        final store = await _readIosStore(asset, iosInstaller);
        if (store != null) {
          return (
            update: AppUpdate._(release.version, page, storeUrl: store),
            hasNewerRelease: true,
          );
        }
      }
    }

    return (update: null, hasNewerRelease: releases.isNotEmpty);
  }

  _ReleaseAsset? _findAsset(String tag, String name, List<dynamic> assets) {
    for (final asset in assets) {
      if (asset is! Map<String, dynamic> || asset['name'] != name) continue;
      final size = asset['size'];
      final digest = _sha256Digest.firstMatch(
        asset['digest']?.toString() ?? '',
      );
      if (size is! int || size <= 0 || digest == null) continue;
      return _ReleaseAsset(
        name,
        Uri.https('github.com', '$_repo/download/$tag/$name'),
        size,
        digest.group(1)!,
      );
    }
    return null;
  }

  Future<Uri?> _readIosStore(_ReleaseAsset asset, String? installer) async {
    if (asset.size > 16 * 1024) {
      throw const FormatException('Invalid iOS release metadata size');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in _assetBytes(asset)) {
      bytes.add(chunk);
    }
    final body = bytes.takeBytes();
    if (sha256.convert(body).toString() != asset.sha256Digest) {
      throw const FormatException('Invalid iOS release metadata digest');
    }
    final data = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    final keys = switch (installer) {
      'com.apple' => const ['appStoreUrl'],
      'com.apple.testflight' => const ['testFlightUrl'],
      _ => const ['appStoreUrl', 'testFlightUrl'],
    };
    for (final key in keys) {
      final value = data[key];
      if (value is! String) continue;
      final url = Uri.tryParse(value);
      if (url == null || !_isHttps(url)) continue;
      final expectedHost = key == 'appStoreUrl'
          ? 'apps.apple.com'
          : 'testflight.apple.com';
      if (url.host == expectedHost &&
          (key == 'appStoreUrl'
              ? url.pathSegments.any((s) => RegExp(r'^id\d+$').hasMatch(s))
              : RegExp(r'^/join/[A-Za-z0-9]+/?$').hasMatch(url.path))) {
        return url;
      }
    }
    return null;
  }

  Future<File> download(
    AppUpdate update, {
    required void Function(int received, int total) onProgress,
  }) async {
    final asset = update._package;
    if (asset == null) throw StateError('This update uses an app store');
    final cache = Directory(
      p.join((await getTemporaryDirectory()).path, _cacheName),
    );
    await cache.create(recursive: true);
    final folder = await cache.createTemp('package-');
    final file = File(p.join(folder.path, asset.name));
    try {
      final sink = file.openWrite();
      try {
        await sink.addStream(_assetBytes(asset, onProgress: onProgress));
      } finally {
        await sink.close();
      }
      if ((await sha256.bind(file.openRead()).first).toString() !=
          asset.sha256Digest) {
        throw const FormatException('Install package SHA-256 mismatch');
      }
      return file;
    } catch (_) {
      await folder.delete(recursive: true);
      rethrow;
    }
  }

  Stream<List<int>> _assetBytes(
    _ReleaseAsset asset, {
    void Function(int received, int total)? onProgress,
  }) async* {
    final response = await _openAsset(asset.url);
    var received = 0;
    await for (final chunk in response.stream.timeout(_timeout)) {
      received += chunk.length;
      if (received > asset.size) {
        throw const FormatException(
          'Install package is larger than its release metadata',
        );
      }
      onProgress?.call(received, asset.size);
      yield chunk;
    }
    if (received != asset.size) {
      throw const FormatException('Incomplete release asset download');
    }
  }

  Future<http.StreamedResponse> _openAsset(Uri url) async {
    for (var hop = 0; hop < 5; hop++) {
      if (!_isHttps(url) || !_assetHosts.contains(url.host)) {
        throw const FormatException('Untrusted release asset URL');
      }
      final request = http.Request('GET', url)..followRedirects = false;
      final response = await _http.send(request).timeout(_timeout);
      if (response.statusCode == 200) return response;
      await response.stream.timeout(_timeout).drain<void>();
      final location = response.headers['location'];
      if (![301, 302, 303, 307, 308].contains(response.statusCode) ||
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

class _ReleaseAsset {
  final String name;
  final Uri url;
  final int size;
  final String sha256Digest;

  const _ReleaseAsset(this.name, this.url, this.size, this.sha256Digest);
}
