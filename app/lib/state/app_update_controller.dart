import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_update_service.dart';
import '../services/drawer_window_service.dart';
import '../l10n/l10n.dart';

enum UpdatePhase {
  /// Nothing checked yet in this session.
  idle,
  checking,
  upToDate,
  available,
  downloading,
  /// The installer is running; desktop apps quit and relaunch.
  installing,
  failed,
}

/// Checks for, downloads and installs app updates, and holds the state the
/// drawer banner and the preferences page show.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required this.window,
    AppUpdateService? service,
    UpdatePlatform? platform,
    Future<PackageInfo> Function()? packageInfo,
    this.checkInterval = const Duration(hours: 24),
    this.firstCheckDelay = const Duration(seconds: 8),
    this.installTimeout = const Duration(minutes: 2),
  })  : _service = service ?? AppUpdateService(),
        platform = platform ?? UpdatePlatform.current,
        _packageInfo = packageInfo ?? PackageInfo.fromPlatform;

  static const _autoCheckKey = 'update_auto_check';
  static const _lastCheckKey = 'update_last_check';
  static const _dismissedKey = 'update_dismissed_version';

  final DrawerWindowService window;
  final AppUpdateService _service;
  final Future<PackageInfo> Function() _packageInfo;
  final UpdatePlatform platform;
  final Duration checkInterval;
  final Duration firstCheckDelay;

  /// A desktop app still running this long after its installer started was
  /// not replaced (for example, the installer window was cancelled).
  final Duration installTimeout;

  InstalledBuild? installed;
  bool autoCheck = true;
  UpdatePhase phase = UpdatePhase.idle;
  AppUpdate? update;
  double? progress;

  /// The latest problem, worded for the person reading it.
  String? message;

  /// The update can still be installed by hand (macOS fallback).
  File? manualPackage;
  bool hasNewerReleaseForOtherPlatforms = false;

  String? _dismissedVersion;
  Timer? _timer;
  Timer? _installWatch;
  bool _started = false;
  bool _disposed = false;

  /// Updates are offered only on supported platforms, to tagged release builds.
  bool get canUpdate =>
      platform != UpdatePlatform.unsupported &&
      (installed?.isRelease ?? false) &&
      installed?.version != null;

  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.installing;

  /// Whether the drawer shows the update banner.
  bool get showBanner {
    final found = update;
    if (found == null) return false;
    if (phase == UpdatePhase.downloading || phase == UpdatePhase.installing) {
      return true;
    }
    return _dismissedVersion != found.version.toString() &&
        (phase == UpdatePhase.available || phase == UpdatePhase.failed);
  }

  /// Reads the installed version and starts automatic checks.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      installed = InstalledBuild.fromPackage(await _packageInfo());
    } catch (_) {
      installed = const InstalledBuild(null, isRelease: false);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      autoCheck = prefs.getBool(_autoCheckKey) ?? true;
      _dismissedVersion = prefs.getString(_dismissedKey);
    } catch (_) {}
    if (_disposed) return;
    notifyListeners();
    unawaited(_service.clearDownloads());
    _schedule(initial: true);
  }

  void _schedule({bool initial = false}) {
    _timer?.cancel();
    if (!autoCheck || !canUpdate || _disposed) return;
    _timer = Timer(initial ? firstCheckDelay : checkInterval, () async {
      await _autoCheck();
      _schedule();
    });
  }

  Future<void> _autoCheck() async {
    // Restarting the app should not hit GitHub's unauthenticated rate limit.
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastCheckKey);
      if (last != null &&
          DateTime.now().millisecondsSinceEpoch - last <
              checkInterval.inMilliseconds ~/ 2) {
        return;
      }
    } catch (_) {}
    await check(quiet: true);
  }

  Future<void> setAutoCheck(bool enabled) async {
    autoCheck = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoCheckKey, enabled);
    } catch (_) {}
    _schedule(initial: true);
  }

  /// Looks for a newer release. A [quiet] (automatic) check keeps failures out
  /// of sight; the banner only appears when there is something to install.
  Future<void> check({bool quiet = false}) async {
    final version = installed?.version;
    if (!canUpdate || version == null || busy) return;
    final previous = phase;
    phase = UpdatePhase.checking;
    message = null;
    notifyListeners();
    try {
      final result = await _service.check(version, platform);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);
      } catch (_) {}
      update = result.update;
      hasNewerReleaseForOtherPlatforms =
          result.update == null && result.hasNewerRelease;
      phase = update == null ? UpdatePhase.upToDate : UpdatePhase.available;
    } catch (error) {
      if (quiet) {
        phase = previous == UpdatePhase.checking ? UpdatePhase.idle : previous;
      } else {
        phase = UpdatePhase.failed;
        message = error is UpdateException
            ? describeFailure(error)
            : l10n.couldnTCheckForUpdatesTry;
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// Downloads, verifies and installs the update. On desktop the app quits and
  /// relaunches as the new version; Android hands over to the system installer.
  Future<void> install() async {
    final found = update;
    if (found == null || busy) return;
    phase = UpdatePhase.downloading;
    progress = 0;
    message = null;
    manualPackage = null;
    notifyListeners();

    final File package;
    try {
      package = await _service.download(found, onProgress: (received, total) {
        final next = received / total;
        if (received == 0 ||
            (next - (progress ?? 0)) >= 0.01 ||
            received == total) {
          progress = next;
          if (!_disposed) notifyListeners();
        }
      });
    } on UpdateException catch (error) {
      _fail(describeFailure(error));
      return;
    } catch (_) {
      _fail(l10n.couldnTSaveTheInstallerCheck);
      return;
    }

    phase = UpdatePhase.installing;
    progress = null;
    notifyListeners();
    final UpdateInstallResult result;
    try {
      result = await window.installUpdate(package.path);
    } catch (_) {
      _fail(l10n.couldnTStartTheInstallerTry);
      return;
    }
    switch (result) {
      case UpdateInstallResult.installing:
        // Desktop: the app is about to quit. Android: the system installer is open.
        message = platform.isDesktop ? null : l10n.confirmTheUpdateInTheSystem;
        _installWatch?.cancel();
        _installWatch = Timer(installTimeout, () {
          if (phase == UpdatePhase.installing) {
            _fail(platform.isDesktop
                ? l10n.theUpdateDidnTFinishYou
                : l10n.ifTheInstallationDidnTFinish);
          }
        });
      case UpdateInstallResult.permissionRequired:
        _fail(l10n.allowDropdrawerToInstallAppsThen);
      case UpdateInstallResult.signatureMismatch:
        if (platform == UpdatePlatform.macosArm64) {
          manualPackage = package;
          _fail(l10n.theNewVersionIsSignedDifferently);
        } else {
          _fail(l10n.theNewVersionUsesTheRelease);
        }
      case UpdateInstallResult.notWritable:
        manualPackage = package;
        _fail(l10n.dropdrawerDoesnTHavePermissionTo);
      case UpdateInstallResult.versionTooOld:
        _fail(l10n.thisInstallerSBuildNumberIsn);
      case UpdateInstallResult.unavailable:
        _fail(l10n.couldnTStartTheInstallerTry);
    }
    if (!_disposed) notifyListeners();
  }

  void _fail(String text) {
    phase = UpdatePhase.failed;
    progress = null;
    message = text;
    if (!_disposed) notifyListeners();
  }

  /// Opens the downloaded package so it can be installed by hand.
  Future<void> openManualPackage() async {
    final package = manualPackage;
    if (package == null) return;
    if (!await package.exists() || !await window.openUpdatePackage(package.path)) {
      _fail(l10n.couldnTOpenTheInstallerDownload);
    }
  }

  /// Hides the banner until a newer version than this one appears.
  Future<void> dismiss() async {
    final found = update;
    if (found == null) return;
    _dismissedVersion = found.version.toString();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedKey, _dismissedVersion!);
    } catch (_) {}
  }

  Future<bool> openReleasePage() async {
    final page = update?.releasePage ?? AppUpdateService.releasesPage;
    try {
      return await window.openExternalUrl(page.toString());
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static String describeFailure(UpdateException error) => switch (error.reason) {
        UpdateFailure.offline => l10n.canTReachGithubCheckYour,
        UpdateFailure.rateLimited => error.retryAfter == null
            ? l10n.githubIsTemporarilyLimitingUpdateChecks
            : l10n.githubRateLimitedUntil(_clock(error.retryAfter!)),
        UpdateFailure.unavailable => l10n.githubCanTProvideVersionInformation,
        UpdateFailure.corrupted => l10n.theDownloadedInstallerIsIncompleteOr,
      };

  static String _clock(DateTime time) {
    return AppLocale.time(time.toLocal());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _installWatch?.cancel();
    _service.close();
    super.dispose();
  }
}
