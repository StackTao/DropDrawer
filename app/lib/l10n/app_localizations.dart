import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @serverAnnouncement.
  ///
  /// In zh, this message translates to:
  /// **'服务器公告'**
  String get serverAnnouncement;

  /// No description provided for @dismissAnnouncement.
  ///
  /// In zh, this message translates to:
  /// **'关闭公告'**
  String get dismissAnnouncement;

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @waitingForStorageConfirmation.
  ///
  /// In zh, this message translates to:
  /// **'等待存储确认…'**
  String get waitingForStorageConfirmation;

  /// No description provided for @sendingFile.
  ///
  /// In zh, this message translates to:
  /// **'正在发送文件'**
  String get sendingFile;

  /// No description provided for @transferCanceled.
  ///
  /// In zh, this message translates to:
  /// **'传输已取消'**
  String get transferCanceled;

  /// No description provided for @googleSignInRequiresAnHttps.
  ///
  /// In zh, this message translates to:
  /// **'Google 登录需要 HTTPS 服务器地址。'**
  String get googleSignInRequiresAnHttps;

  /// No description provided for @googleSignInIsNotEnabled.
  ///
  /// In zh, this message translates to:
  /// **'此服务器尚未启用 Google 登录。'**
  String get googleSignInIsNotEnabled;

  /// No description provided for @theServerReturnedAnInvalidGoogle.
  ///
  /// In zh, this message translates to:
  /// **'服务器返回了无效的 Google 授权地址。'**
  String get theServerReturnedAnInvalidGoogle;

  /// No description provided for @back.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get back;

  /// No description provided for @closeMenu.
  ///
  /// In zh, this message translates to:
  /// **'关闭菜单'**
  String get closeMenu;

  /// No description provided for @remove.
  ///
  /// In zh, this message translates to:
  /// **'移出'**
  String get remove;

  /// No description provided for @settings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settings;

  /// No description provided for @downloadingUpdateProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在下载 {version} · {value}%'**
  String downloadingUpdateProgress(Object version, Object value);

  /// No description provided for @installingDropdrawerWillRestartAutomatically.
  ///
  /// In zh, this message translates to:
  /// **'正在安装 {version}，DropDrawer 将自动重启'**
  String installingDropdrawerWillRestartAutomatically(Object version);

  /// No description provided for @openingTheSystemInstaller.
  ///
  /// In zh, this message translates to:
  /// **'正在打开系统安装界面'**
  String get openingTheSystemInstaller;

  /// No description provided for @updateFailed.
  ///
  /// In zh, this message translates to:
  /// **'更新失败'**
  String get updateFailed;

  /// No description provided for @versionIsAvailable.
  ///
  /// In zh, this message translates to:
  /// **'新版本 {version} 可用'**
  String versionIsAvailable(Object version);

  /// No description provided for @openInstaller.
  ///
  /// In zh, this message translates to:
  /// **'打开安装包'**
  String get openInstaller;

  /// No description provided for @retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retry;

  /// No description provided for @update.
  ///
  /// In zh, this message translates to:
  /// **'更新'**
  String get update;

  /// No description provided for @later.
  ///
  /// In zh, this message translates to:
  /// **'稍后'**
  String get later;

  /// No description provided for @couldnTCheckForUpdatesTry.
  ///
  /// In zh, this message translates to:
  /// **'检查更新失败，请稍后重试。'**
  String get couldnTCheckForUpdatesTry;

  /// No description provided for @couldnTSaveTheInstallerCheck.
  ///
  /// In zh, this message translates to:
  /// **'无法保存安装包，请检查磁盘空间后重试。'**
  String get couldnTSaveTheInstallerCheck;

  /// No description provided for @couldnTStartTheInstallerTry.
  ///
  /// In zh, this message translates to:
  /// **'无法启动安装程序，请稍后重试。'**
  String get couldnTStartTheInstallerTry;

  /// No description provided for @confirmTheUpdateInTheSystem.
  ///
  /// In zh, this message translates to:
  /// **'请在系统安装界面中确认更新。'**
  String get confirmTheUpdateInTheSystem;

  /// No description provided for @theUpdateDidnTFinishYou.
  ///
  /// In zh, this message translates to:
  /// **'更新没有完成，可以再试一次。'**
  String get theUpdateDidnTFinishYou;

  /// No description provided for @ifTheInstallationDidnTFinish.
  ///
  /// In zh, this message translates to:
  /// **'如果没有完成安装，可以再点一次「更新」。'**
  String get ifTheInstallationDidnTFinish;

  /// No description provided for @allowDropdrawerToInstallAppsThen.
  ///
  /// In zh, this message translates to:
  /// **'请允许 DropDrawer 安装应用，返回后再点一次「更新」。'**
  String get allowDropdrawerToInstallAppsThen;

  /// No description provided for @theNewVersionIsSignedDifferently.
  ///
  /// In zh, this message translates to:
  /// **'新版本的签名与当前应用不同，无法自动替换。可以打开安装包手动安装。'**
  String get theNewVersionIsSignedDifferently;

  /// No description provided for @theNewVersionUsesTheRelease.
  ///
  /// In zh, this message translates to:
  /// **'新版本使用了正式签名，与当前安装的测试版不同。请先卸载 DropDrawer 再安装新版本；抽屉内容保存在服务端，不会丢失。'**
  String get theNewVersionUsesTheRelease;

  /// No description provided for @dropdrawerDoesnTHavePermissionTo.
  ///
  /// In zh, this message translates to:
  /// **'没有权限替换当前的 DropDrawer，可以打开安装包手动安装。'**
  String get dropdrawerDoesnTHavePermissionTo;

  /// No description provided for @thisInstallerSBuildNumberIsn.
  ///
  /// In zh, this message translates to:
  /// **'这个安装包的构建号不比当前版本新，请从发布页选择对应的安装包。'**
  String get thisInstallerSBuildNumberIsn;

  /// No description provided for @couldnTOpenTheInstallerDownload.
  ///
  /// In zh, this message translates to:
  /// **'无法打开安装包，请从发布页下载。'**
  String get couldnTOpenTheInstallerDownload;

  /// No description provided for @canTReachGithubCheckYour.
  ///
  /// In zh, this message translates to:
  /// **'连不上 GitHub，请检查网络后重试。'**
  String get canTReachGithubCheckYour;

  /// No description provided for @githubIsTemporarilyLimitingUpdateChecks.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 暂时限制了检查次数，请稍后再试。'**
  String get githubIsTemporarilyLimitingUpdateChecks;

  /// No description provided for @githubRateLimitedUntil.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 暂时限制了检查次数，请在 {value} 之后再试。'**
  String githubRateLimitedUntil(Object value);

  /// No description provided for @githubCanTProvideVersionInformation.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 暂时无法提供版本信息，请稍后重试。'**
  String get githubCanTProvideVersionInformation;

  /// No description provided for @theDownloadedInstallerIsIncompleteOr.
  ///
  /// In zh, this message translates to:
  /// **'下载的安装包不完整或已损坏，请重新下载。'**
  String get theDownloadedInstallerIsIncompleteOr;

  /// No description provided for @checkAutomatically.
  ///
  /// In zh, this message translates to:
  /// **'自动检查'**
  String get checkAutomatically;

  /// No description provided for @checkForUpdates.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get checkForUpdates;

  /// No description provided for @releases.
  ///
  /// In zh, this message translates to:
  /// **'发布页'**
  String get releases;

  /// No description provided for @releaseNotes.
  ///
  /// In zh, this message translates to:
  /// **'更新说明'**
  String get releaseNotes;

  /// No description provided for @aboutUpdates.
  ///
  /// In zh, this message translates to:
  /// **'关于与更新'**
  String get aboutUpdates;

  /// No description provided for @checkForUpdatesAutomatically.
  ///
  /// In zh, this message translates to:
  /// **'自动检查更新'**
  String get checkForUpdatesAutomatically;

  /// No description provided for @updateToMbAndRestart.
  ///
  /// In zh, this message translates to:
  /// **'更新到 {version}（{mb} MB）并重启'**
  String updateToMbAndRestart(Object version, Object mb);

  /// No description provided for @updateToMb.
  ///
  /// In zh, this message translates to:
  /// **'更新到 {version}（{mb} MB）'**
  String updateToMb(Object version, Object mb);

  /// No description provided for @readingVersion.
  ///
  /// In zh, this message translates to:
  /// **'正在读取版本…'**
  String get readingVersion;

  /// No description provided for @getNewVersionsForThisPlatform.
  ///
  /// In zh, this message translates to:
  /// **'这个平台的新版本请从发布页获取。'**
  String get getNewVersionsForThisPlatform;

  /// No description provided for @developmentBuildNoReleaseTagAt.
  ///
  /// In zh, this message translates to:
  /// **'开发版本（构建时未指定发布标签），不检查更新。'**
  String get developmentBuildNoReleaseTagAt;

  /// No description provided for @checksForANewVersionOnce.
  ///
  /// In zh, this message translates to:
  /// **'每天自动检查一次新版本。'**
  String get checksForANewVersionOnce;

  /// No description provided for @automaticChecksAreOff.
  ///
  /// In zh, this message translates to:
  /// **'已关闭自动检查。'**
  String get automaticChecksAreOff;

  /// No description provided for @checkingForUpdates.
  ///
  /// In zh, this message translates to:
  /// **'正在检查更新…'**
  String get checkingForUpdates;

  /// No description provided for @aNewVersionWasReleasedBut.
  ///
  /// In zh, this message translates to:
  /// **'已有新版本发布，但还没有这个平台的安装包。'**
  String get aNewVersionWasReleasedBut;

  /// No description provided for @youReUpToDate.
  ///
  /// In zh, this message translates to:
  /// **'已是最新版本。'**
  String get youReUpToDate;

  /// No description provided for @versionIsReadyToInstall.
  ///
  /// In zh, this message translates to:
  /// **'新版本 {version} 可以更新。'**
  String versionIsReadyToInstall(Object version);

  /// No description provided for @downloadingAndVerifyingProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在下载并校验 {value}%…'**
  String downloadingAndVerifyingProgress(Object value);

  /// No description provided for @installingDropdrawerWillRestartAutomatically2.
  ///
  /// In zh, this message translates to:
  /// **'正在安装，DropDrawer 将自动重启。'**
  String get installingDropdrawerWillRestartAutomatically2;

  /// No description provided for @openingTheSystemInstaller2.
  ///
  /// In zh, this message translates to:
  /// **'正在打开系统安装界面…'**
  String get openingTheSystemInstaller2;

  /// No description provided for @updateFailedTryAgain.
  ///
  /// In zh, this message translates to:
  /// **'更新失败，请重试。'**
  String get updateFailedTryAgain;

  /// No description provided for @enterAValidEmailAddressFirst.
  ///
  /// In zh, this message translates to:
  /// **'请先填写有效的邮箱地址'**
  String get enterAValidEmailAddressFirst;

  /// No description provided for @verificationCodeSentCheckYourEmail.
  ///
  /// In zh, this message translates to:
  /// **'验证码已发送，请查收邮件（10 分钟内有效）'**
  String get verificationCodeSentCheckYourEmail;

  /// No description provided for @passwordResetSignInWithYour.
  ///
  /// In zh, this message translates to:
  /// **'密码已重置，请使用新密码登录'**
  String get passwordResetSignInWithYour;

  /// No description provided for @thisServerRequiresAnInvitationCode.
  ///
  /// In zh, this message translates to:
  /// **'当前服务器需要邀请码，请先填写邀请码再使用 Google 注册'**
  String get thisServerRequiresAnInvitationCode;

  /// No description provided for @enterAValidServerAddressFirst.
  ///
  /// In zh, this message translates to:
  /// **'请先填写有效的服务器地址。'**
  String get enterAValidServerAddressFirst;

  /// No description provided for @continueLabel.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get continueLabel;

  /// No description provided for @createAccountAndConnect.
  ///
  /// In zh, this message translates to:
  /// **'创建账号并连接'**
  String get createAccountAndConnect;

  /// No description provided for @resetPassword.
  ///
  /// In zh, this message translates to:
  /// **'确认重置密码'**
  String get resetPassword;

  /// No description provided for @resetYourPasswordWithAnEmail.
  ///
  /// In zh, this message translates to:
  /// **'通过邮箱验证码重置密码'**
  String get resetYourPasswordWithAnEmail;

  /// No description provided for @aDrawerForFilesAcrossYour.
  ///
  /// In zh, this message translates to:
  /// **'跨端文件暂存抽屉'**
  String get aDrawerForFilesAcrossYour;

  /// No description provided for @server.
  ///
  /// In zh, this message translates to:
  /// **'服务器'**
  String get server;

  /// No description provided for @account.
  ///
  /// In zh, this message translates to:
  /// **'账号'**
  String get account;

  /// No description provided for @usernameOrVerifiedEmail.
  ///
  /// In zh, this message translates to:
  /// **'用户名或已验证邮箱'**
  String get usernameOrVerifiedEmail;

  /// No description provided for @enterYourUsername.
  ///
  /// In zh, this message translates to:
  /// **'输入用户名'**
  String get enterYourUsername;

  /// No description provided for @email.
  ///
  /// In zh, this message translates to:
  /// **'邮箱'**
  String get email;

  /// No description provided for @verificationCode.
  ///
  /// In zh, this message translates to:
  /// **'验证码'**
  String get verificationCode;

  /// No description provided for @n6Digits.
  ///
  /// In zh, this message translates to:
  /// **'6 位数字'**
  String get n6Digits;

  /// No description provided for @sending.
  ///
  /// In zh, this message translates to:
  /// **'发送中…'**
  String get sending;

  /// No description provided for @sendCode.
  ///
  /// In zh, this message translates to:
  /// **'获取验证码'**
  String get sendCode;

  /// No description provided for @invitationCode.
  ///
  /// In zh, this message translates to:
  /// **'邀请码'**
  String get invitationCode;

  /// No description provided for @enterTheInvitationCodeFromYour.
  ///
  /// In zh, this message translates to:
  /// **'输入管理员发放的邀请码'**
  String get enterTheInvitationCodeFromYour;

  /// No description provided for @newPassword.
  ///
  /// In zh, this message translates to:
  /// **'新密码'**
  String get newPassword;

  /// No description provided for @password.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get password;

  /// No description provided for @atLeast6Characters.
  ///
  /// In zh, this message translates to:
  /// **'至少 6 位'**
  String get atLeast6Characters;

  /// No description provided for @finishGoogleAuthorizationInYourBrowser.
  ///
  /// In zh, this message translates to:
  /// **'请在系统浏览器完成 Google 授权，然后返回 DropDrawer。'**
  String get finishGoogleAuthorizationInYourBrowser;

  /// No description provided for @stopWaiting.
  ///
  /// In zh, this message translates to:
  /// **'取消等待'**
  String get stopWaiting;

  /// No description provided for @signUpWithGoogle.
  ///
  /// In zh, this message translates to:
  /// **'使用 Google 注册'**
  String get signUpWithGoogle;

  /// No description provided for @signInWithGoogle.
  ///
  /// In zh, this message translates to:
  /// **'使用 Google 登录'**
  String get signInWithGoogle;

  /// No description provided for @forgotPassword.
  ///
  /// In zh, this message translates to:
  /// **'忘记密码？'**
  String get forgotPassword;

  /// No description provided for @privacy.
  ///
  /// In zh, this message translates to:
  /// **'隐私说明'**
  String get privacy;

  /// No description provided for @noAccountCreateOne.
  ///
  /// In zh, this message translates to:
  /// **'还没有账号？创建一个'**
  String get noAccountCreateOne;

  /// No description provided for @haveAnAccountSignIn.
  ///
  /// In zh, this message translates to:
  /// **'已有账号，返回登录'**
  String get haveAnAccountSignIn;

  /// No description provided for @fromDevice.
  ///
  /// In zh, this message translates to:
  /// **'来自 {cleanDeviceName}'**
  String fromDevice(Object cleanDeviceName);

  /// No description provided for @sourceOffline.
  ///
  /// In zh, this message translates to:
  /// **'来源离线'**
  String get sourceOffline;

  /// No description provided for @p2pCloud.
  ///
  /// In zh, this message translates to:
  /// **'P2P · 云端'**
  String get p2pCloud;

  /// No description provided for @p2pDirect.
  ///
  /// In zh, this message translates to:
  /// **'P2P 直连'**
  String get p2pDirect;

  /// No description provided for @savedToCloud.
  ///
  /// In zh, this message translates to:
  /// **'已存云盘'**
  String get savedToCloud;

  /// No description provided for @createShareLink.
  ///
  /// In zh, this message translates to:
  /// **'创建外链分享'**
  String get createShareLink;

  /// No description provided for @copyText.
  ///
  /// In zh, this message translates to:
  /// **'复制文本'**
  String get copyText;

  /// No description provided for @copiedToClipboard.
  ///
  /// In zh, this message translates to:
  /// **'已复制到剪贴板'**
  String get copiedToClipboard;

  /// No description provided for @saveToCloudAvailableOffline.
  ///
  /// In zh, this message translates to:
  /// **'转存到云盘 (离线可下)'**
  String get saveToCloudAvailableOffline;

  /// No description provided for @copyFilePasteIntoFileExplorer.
  ///
  /// In zh, this message translates to:
  /// **'复制文件 (可直接 Ctrl+V 粘贴到资源管理器)'**
  String get copyFilePasteIntoFileExplorer;

  /// No description provided for @copyFilePasteIntoFinderOr.
  ///
  /// In zh, this message translates to:
  /// **'复制文件 (可直接 ⌘V 粘贴到微信/访达)'**
  String get copyFilePasteIntoFinderOr;

  /// No description provided for @fileCopiedPasteItWith.
  ///
  /// In zh, this message translates to:
  /// **'已复制文件，可直接 {pasteShortcutLabel} 粘贴'**
  String fileCopiedPasteItWith(Object pasteShortcutLabel);

  /// No description provided for @couldnTCopyTheFile.
  ///
  /// In zh, this message translates to:
  /// **'复制文件失败'**
  String get couldnTCopyTheFile;

  /// No description provided for @showInFileExplorerOrDrag.
  ///
  /// In zh, this message translates to:
  /// **'在资源管理器中显示 (也可直接按住卡片拖出)'**
  String get showInFileExplorerOrDrag;

  /// No description provided for @showInFinderOrDragThe.
  ///
  /// In zh, this message translates to:
  /// **'在访达中显示 (也可直接按住卡片拖出)'**
  String get showInFinderOrDragThe;

  /// No description provided for @shareOpenInAnotherApp.
  ///
  /// In zh, this message translates to:
  /// **'系统分享 / 其他应用打开'**
  String get shareOpenInAnotherApp;

  /// No description provided for @couldnTOpenTheShareSheet.
  ///
  /// In zh, this message translates to:
  /// **'打开系统分享失败'**
  String get couldnTOpenTheShareSheet;

  /// No description provided for @downloadP2pFirst.
  ///
  /// In zh, this message translates to:
  /// **'P2P 优先下载'**
  String get downloadP2pFirst;

  /// No description provided for @downloadFromCloud.
  ///
  /// In zh, this message translates to:
  /// **'从云端下载'**
  String get downloadFromCloud;

  /// No description provided for @removeFromDrawer.
  ///
  /// In zh, this message translates to:
  /// **'移出抽屉'**
  String get removeFromDrawer;

  /// No description provided for @removeFailedError.
  ///
  /// In zh, this message translates to:
  /// **'移出失败：{e}'**
  String removeFailedError(Object e);

  /// No description provided for @preparingDownload.
  ///
  /// In zh, this message translates to:
  /// **'正在准备下载'**
  String get preparingDownload;

  /// No description provided for @connectingOverP2p.
  ///
  /// In zh, this message translates to:
  /// **'正在建立 P2P 连接'**
  String get connectingOverP2p;

  /// No description provided for @p2pLanCopy.
  ///
  /// In zh, this message translates to:
  /// **'P2P 局域网副本'**
  String get p2pLanCopy;

  /// No description provided for @p2pDirectConnection.
  ///
  /// In zh, this message translates to:
  /// **'P2P 端到端直连'**
  String get p2pDirectConnection;

  /// No description provided for @p2pEncryptedRelay.
  ///
  /// In zh, this message translates to:
  /// **'P2P 加密中继'**
  String get p2pEncryptedRelay;

  /// No description provided for @cloudDownload.
  ///
  /// In zh, this message translates to:
  /// **'云端高速下载'**
  String get cloudDownload;

  /// No description provided for @canceling.
  ///
  /// In zh, this message translates to:
  /// **'正在取消'**
  String get canceling;

  /// No description provided for @cancelUpload.
  ///
  /// In zh, this message translates to:
  /// **'取消上传'**
  String get cancelUpload;

  /// No description provided for @cancelDownload.
  ///
  /// In zh, this message translates to:
  /// **'取消下载'**
  String get cancelDownload;

  /// No description provided for @sendingToProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在发送给 {value} · {value2}%'**
  String sendingToProgress(Object value, Object value2);

  /// No description provided for @cancelSending.
  ///
  /// In zh, this message translates to:
  /// **'取消发送'**
  String get cancelSending;

  /// No description provided for @transferFailedError.
  ///
  /// In zh, this message translates to:
  /// **'传输失败：{error}'**
  String transferFailedError(Object error);

  /// No description provided for @fromDeviceName.
  ///
  /// In zh, this message translates to:
  /// **'来自 {device}'**
  String fromDeviceName(Object device);

  /// No description provided for @yourSessionHasExpiredAnAdministrator.
  ///
  /// In zh, this message translates to:
  /// **'登录状态已失效（可能被管理员强制下线或账号已停用），请重新登录'**
  String get yourSessionHasExpiredAnAdministrator;

  /// No description provided for @defaultCloudStorage.
  ///
  /// In zh, this message translates to:
  /// **'默认云盘'**
  String get defaultCloudStorage;

  /// No description provided for @thisVersionIsTooOldUpdate.
  ///
  /// In zh, this message translates to:
  /// **'当前版本过低，请更新 DropDrawer 后再使用'**
  String get thisVersionIsTooOldUpdate;

  /// No description provided for @yourSessionHasExpiredSignIn.
  ///
  /// In zh, this message translates to:
  /// **'登录状态已失效，请重新登录'**
  String get yourSessionHasExpiredSignIn;

  /// No description provided for @canTReachTheServerRight.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法连接服务器，请下拉刷新重试'**
  String get canTReachTheServerRight;

  /// No description provided for @couldnTOpenTheBrowser.
  ///
  /// In zh, this message translates to:
  /// **'无法打开系统浏览器。'**
  String get couldnTOpenTheBrowser;

  /// No description provided for @googleSignInTimedOutTry.
  ///
  /// In zh, this message translates to:
  /// **'Google 登录已超时，请重试。'**
  String get googleSignInTimedOutTry;

  /// No description provided for @sharedContentReceivedItWillSync.
  ///
  /// In zh, this message translates to:
  /// **'已接收外部分享内容，登录后将自动同步到抽屉'**
  String get sharedContentReceivedItWillSync;

  /// No description provided for @sent.
  ///
  /// In zh, this message translates to:
  /// **'发送已完成'**
  String get sent;

  /// No description provided for @sendingCanceled.
  ///
  /// In zh, this message translates to:
  /// **'已取消发送'**
  String get sendingCanceled;

  /// No description provided for @p2pSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'P2P 发送失败：{err}'**
  String p2pSendFailed(Object err);

  /// No description provided for @downloadCanceled.
  ///
  /// In zh, this message translates to:
  /// **'已取消下载'**
  String get downloadCanceled;

  /// No description provided for @lanCopy.
  ///
  /// In zh, this message translates to:
  /// **'局域网副本'**
  String get lanCopy;

  /// No description provided for @packingFolder.
  ///
  /// In zh, this message translates to:
  /// **'正在打包文件夹「{folderName}」...'**
  String packingFolder(Object folderName);

  /// No description provided for @packingFolderFailed.
  ///
  /// In zh, this message translates to:
  /// **'打包文件夹「{folderName}」失败: {e}'**
  String packingFolderFailed(Object folderName, Object e);

  /// No description provided for @cloudUploadsAreTurnedOffOn.
  ///
  /// In zh, this message translates to:
  /// **'服务器已关闭云端上传，文件将只通过设备间 P2P 传输'**
  String get cloudUploadsAreTurnedOffOn;

  /// No description provided for @p2pRegisterNotice.
  ///
  /// In zh, this message translates to:
  /// **'P2P 注册提示: {e}'**
  String p2pRegisterNotice(Object e);

  /// No description provided for @addedP2pOnly.
  ///
  /// In zh, this message translates to:
  /// **'已加入「{name}」(纯 P2P 端到端直连)'**
  String addedP2pOnly(Object name);

  /// No description provided for @addItemFailed.
  ///
  /// In zh, this message translates to:
  /// **'添加「{name}」失败: {e}'**
  String addItemFailed(Object name, Object e);

  /// No description provided for @textSyncedToAllDevices.
  ///
  /// In zh, this message translates to:
  /// **'文本已同步到所有设备'**
  String get textSyncedToAllDevices;

  /// No description provided for @cancelingSend.
  ///
  /// In zh, this message translates to:
  /// **'正在取消发送'**
  String get cancelingSend;

  /// No description provided for @cancelSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'取消发送失败：{e}'**
  String cancelSendFailed(Object e);

  /// No description provided for @file.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get file;

  /// No description provided for @uploadingFilesToCloud.
  ///
  /// In zh, this message translates to:
  /// **'正在上传 {count} 个文件到云盘'**
  String uploadingFilesToCloud(int count);

  /// No description provided for @uploadingToTheCloud.
  ///
  /// In zh, this message translates to:
  /// **'正在上传到云盘'**
  String get uploadingToTheCloud;

  /// No description provided for @transferringFiles.
  ///
  /// In zh, this message translates to:
  /// **'正在传输 {count} 个文件'**
  String transferringFiles(int count);

  /// No description provided for @transferringFile.
  ///
  /// In zh, this message translates to:
  /// **'正在传输文件'**
  String get transferringFile;

  /// No description provided for @itemAwaitingCloudConfirmation.
  ///
  /// In zh, this message translates to:
  /// **'{itemName} · 等待云盘确认…'**
  String itemAwaitingCloudConfirmation(Object itemName);

  /// No description provided for @cloudUploadsAreTurnedOffOn2.
  ///
  /// In zh, this message translates to:
  /// **'服务器已关闭云端上传，请使用设备间 P2P 传输'**
  String get cloudUploadsAreTurnedOffOn2;

  /// No description provided for @savedToBackend.
  ///
  /// In zh, this message translates to:
  /// **'已转存到「{defaultStorageBackendName}」'**
  String savedToBackend(Object defaultStorageBackendName);

  /// No description provided for @uploadCanceled.
  ///
  /// In zh, this message translates to:
  /// **'已取消上传'**
  String get uploadCanceled;

  /// No description provided for @cloudUploadFailed.
  ///
  /// In zh, this message translates to:
  /// **'上传云端失败: {e}'**
  String cloudUploadFailed(Object e);

  /// No description provided for @cancelingDownload.
  ///
  /// In zh, this message translates to:
  /// **'正在取消下载'**
  String get cancelingDownload;

  /// No description provided for @cancelDownloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'取消下载失败：{e}'**
  String cancelDownloadFailed(Object e);

  /// No description provided for @theSourceDeviceIsOfflineAnd.
  ///
  /// In zh, this message translates to:
  /// **'来源设备离线，文件尚未存到云端'**
  String get theSourceDeviceIsOfflineAnd;

  /// No description provided for @downloadFailedError.
  ///
  /// In zh, this message translates to:
  /// **'下载失败：{e}'**
  String downloadFailedError(Object e);

  /// No description provided for @downloadedFromBackend.
  ///
  /// In zh, this message translates to:
  /// **'已从「{backendName}」下载完成'**
  String downloadedFromBackend(Object backendName);

  /// No description provided for @cloudDownloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'云端下载失败: {e}'**
  String cloudDownloadFailed(Object e);

  /// No description provided for @nothingToDownloadTextItemsAnd.
  ///
  /// In zh, this message translates to:
  /// **'没有可下载的文件（纯文本或离线未上云文件已跳过）'**
  String get nothingToDownloadTextItemsAnd;

  /// No description provided for @downloadingFilesBatch.
  ///
  /// In zh, this message translates to:
  /// **'正在批量下载 {filesLength} 个文件...'**
  String downloadingFilesBatch(int filesLength);

  /// No description provided for @downloadsStartedTo.
  ///
  /// In zh, this message translates to:
  /// **'已发起/完成 {okCount} 个文件下载 → {dir}'**
  String downloadsStartedTo(int okCount, Object dir);

  /// No description provided for @theSelectedItemsAreAlreadyIn.
  ///
  /// In zh, this message translates to:
  /// **'所选条目均已存云盘或不在本机'**
  String get theSelectedItemsAreAlreadyIn;

  /// No description provided for @uploadingFilesBatchTo.
  ///
  /// In zh, this message translates to:
  /// **'正在批量上传 {eligibleLength} 个文件到「{defaultStorageBackendName}」...'**
  String uploadingFilesBatchTo(
    int eligibleLength,
    Object defaultStorageBackendName,
  );

  /// No description provided for @savedFilesToCloud.
  ///
  /// In zh, this message translates to:
  /// **'已完成 {eligibleLength} 个文件的云端转存'**
  String savedFilesToCloud(int eligibleLength);

  /// No description provided for @clearedWithFailures.
  ///
  /// In zh, this message translates to:
  /// **'已清理 {deleted} 项，{failed} 项资源删除失败，条目已保留，可重试。'**
  String clearedWithFailures(Object deleted, Object failed);

  /// No description provided for @drawerCleared.
  ///
  /// In zh, this message translates to:
  /// **'已清空抽屉（共清理 {deleted} 项）'**
  String drawerCleared(int deleted);

  /// No description provided for @removedItems.
  ///
  /// In zh, this message translates to:
  /// **'已移出 {deleted} 个条目'**
  String removedItems(int deleted);

  /// No description provided for @couldnTConfirmTheCleanupTry.
  ///
  /// In zh, this message translates to:
  /// **'清理结果未确认，请稍后重试。'**
  String get couldnTConfirmTheCleanupTry;

  /// No description provided for @newFilesP2pOnlyNothingIs.
  ///
  /// In zh, this message translates to:
  /// **'新文件策略：纯 P2P 直连（不上传服务器/云盘）'**
  String get newFilesP2pOnlyNothingIs;

  /// No description provided for @policyAlwaysUpload.
  ///
  /// In zh, this message translates to:
  /// **'新文件策略：强制上传至「{defaultStorageBackendName}」'**
  String policyAlwaysUpload(Object defaultStorageBackendName);

  /// No description provided for @policySmart.
  ///
  /// In zh, this message translates to:
  /// **'新文件策略：智能分流（<{mb}MB 自动云存，大文件纯 P2P）'**
  String policySmart(Object mb);

  /// No description provided for @downloadFolderResetToTheDefault.
  ///
  /// In zh, this message translates to:
  /// **'已恢复默认下载目录'**
  String get downloadFolderResetToTheDefault;

  /// No description provided for @downloadFolderChanged.
  ///
  /// In zh, this message translates to:
  /// **'下载目录已改为 {customDownloadDir}'**
  String downloadFolderChanged(Object customDownloadDir);

  /// No description provided for @notConnectedToTheServer.
  ///
  /// In zh, this message translates to:
  /// **'未连接到服务器'**
  String get notConnectedToTheServer;

  /// No description provided for @shareLinksAreTurnedOffOn.
  ///
  /// In zh, this message translates to:
  /// **'服务器已关闭外链分享'**
  String get shareLinksAreTurnedOffOn;

  /// No description provided for @selectAtLeastOneItem.
  ///
  /// In zh, this message translates to:
  /// **'请至少选择一个条目'**
  String get selectAtLeastOneItem;

  /// No description provided for @fileOnlyOnSourceDevice.
  ///
  /// In zh, this message translates to:
  /// **'文件「{itemName}」仅存在于来源设备且尚未上云，请在原设备先点“存云盘”后再分享'**
  String fileOnlyOnSourceDevice(Object itemName);

  /// No description provided for @savingBeforeSharing.
  ///
  /// In zh, this message translates to:
  /// **'外链分享前正在自动转存「{itemName}」到云端...'**
  String savingBeforeSharing(Object itemName);

  /// No description provided for @autoUploadFailed.
  ///
  /// In zh, this message translates to:
  /// **'「{itemName}」自动上传失败：{error}'**
  String autoUploadFailed(Object itemName, Object error);

  /// No description provided for @shareLinkCreated.
  ///
  /// In zh, this message translates to:
  /// **'已生成外链分享：{value}'**
  String shareLinkCreated(Object value);

  /// No description provided for @shareLinkRevoked.
  ///
  /// In zh, this message translates to:
  /// **'已撤销外链分享'**
  String get shareLinkRevoked;

  /// No description provided for @notConnectedToServer.
  ///
  /// In zh, this message translates to:
  /// **'未连接服务器'**
  String get notConnectedToServer;

  /// No description provided for @textPreview.
  ///
  /// In zh, this message translates to:
  /// **'文本预览'**
  String get textPreview;

  /// No description provided for @imagePreview.
  ///
  /// In zh, this message translates to:
  /// **'图片预览'**
  String get imagePreview;

  /// No description provided for @fileDetails.
  ///
  /// In zh, this message translates to:
  /// **'文件详情'**
  String get fileDetails;

  /// No description provided for @backToDrawer.
  ///
  /// In zh, this message translates to:
  /// **'返回抽屉'**
  String get backToDrawer;

  /// No description provided for @fileName.
  ///
  /// In zh, this message translates to:
  /// **'文件名'**
  String get fileName;

  /// No description provided for @size.
  ///
  /// In zh, this message translates to:
  /// **'大小'**
  String get size;

  /// No description provided for @sourceDevice.
  ///
  /// In zh, this message translates to:
  /// **'来源设备'**
  String get sourceDevice;

  /// No description provided for @added.
  ///
  /// In zh, this message translates to:
  /// **'添加时间'**
  String get added;

  /// No description provided for @transferMethod.
  ///
  /// In zh, this message translates to:
  /// **'传输方式'**
  String get transferMethod;

  /// No description provided for @cloudCache.
  ///
  /// In zh, this message translates to:
  /// **'云端缓存'**
  String get cloudCache;

  /// No description provided for @p2pDirectOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅 P2P 直连'**
  String get p2pDirectOnly;

  /// No description provided for @expires.
  ///
  /// In zh, this message translates to:
  /// **'到期清理'**
  String get expires;

  /// No description provided for @neverExpires.
  ///
  /// In zh, this message translates to:
  /// **'永不过期'**
  String get neverExpires;

  /// No description provided for @localCopy.
  ///
  /// In zh, this message translates to:
  /// **'本地缓存'**
  String get localCopy;

  /// No description provided for @savedOnThisDevice.
  ///
  /// In zh, this message translates to:
  /// **'已保存到本机'**
  String get savedOnThisDevice;

  /// No description provided for @locationOnThisDevice.
  ///
  /// In zh, this message translates to:
  /// **'本机位置'**
  String get locationOnThisDevice;

  /// No description provided for @info.
  ///
  /// In zh, this message translates to:
  /// **'信息'**
  String get info;

  /// No description provided for @transfer.
  ///
  /// In zh, this message translates to:
  /// **'传输'**
  String get transfer;

  /// No description provided for @cloudDownloadShort.
  ///
  /// In zh, this message translates to:
  /// **'云端下载'**
  String get cloudDownloadShort;

  /// No description provided for @sendingToDevice.
  ///
  /// In zh, this message translates to:
  /// **'正在发送给 {value}'**
  String sendingToDevice(Object value);

  /// No description provided for @downloadItToViewTheOriginal.
  ///
  /// In zh, this message translates to:
  /// **'下载到本机后可查看原图'**
  String get downloadItToViewTheOriginal;

  /// No description provided for @downloadItToViewTheFull.
  ///
  /// In zh, this message translates to:
  /// **'下载到本地后可查看高清原图'**
  String get downloadItToViewTheFull;

  /// No description provided for @transferStatus.
  ///
  /// In zh, this message translates to:
  /// **'传输状态'**
  String get transferStatus;

  /// No description provided for @p2pEndToEndOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅 P2P 端到端直连'**
  String get p2pEndToEndOnly;

  /// No description provided for @localPath.
  ///
  /// In zh, this message translates to:
  /// **'本机路径'**
  String get localPath;

  /// No description provided for @copyAllText.
  ///
  /// In zh, this message translates to:
  /// **'复制全部文本'**
  String get copyAllText;

  /// No description provided for @copiedAllText.
  ///
  /// In zh, this message translates to:
  /// **'已复制全部文本'**
  String get copiedAllText;

  /// No description provided for @quickLook.
  ///
  /// In zh, this message translates to:
  /// **'快速查看'**
  String get quickLook;

  /// No description provided for @open.
  ///
  /// In zh, this message translates to:
  /// **'打开'**
  String get open;

  /// No description provided for @noAppCanOpenThisFile.
  ///
  /// In zh, this message translates to:
  /// **'没有可以打开这个文件的应用'**
  String get noAppCanOpenThisFile;

  /// No description provided for @share.
  ///
  /// In zh, this message translates to:
  /// **'分享…'**
  String get share;

  /// No description provided for @saveToPhotos.
  ///
  /// In zh, this message translates to:
  /// **'存到相册'**
  String get saveToPhotos;

  /// No description provided for @savedToPhotos.
  ///
  /// In zh, this message translates to:
  /// **'已保存到系统相册'**
  String get savedToPhotos;

  /// No description provided for @couldnTSaveToPhotosCheck.
  ///
  /// In zh, this message translates to:
  /// **'保存相册失败（请检查相册权限）'**
  String get couldnTSaveToPhotosCheck;

  /// No description provided for @saveToCloudDownloadableWhileThe.
  ///
  /// In zh, this message translates to:
  /// **'存到云盘（来源离线也能下载）'**
  String get saveToCloudDownloadableWhileThe;

  /// No description provided for @link.
  ///
  /// In zh, this message translates to:
  /// **'外链'**
  String get link;

  /// No description provided for @copyFile.
  ///
  /// In zh, this message translates to:
  /// **'复制文件'**
  String get copyFile;

  /// No description provided for @showInFileExplorer.
  ///
  /// In zh, this message translates to:
  /// **'在资源管理器中显示'**
  String get showInFileExplorer;

  /// No description provided for @showInFinder.
  ///
  /// In zh, this message translates to:
  /// **'访达中显示'**
  String get showInFinder;

  /// No description provided for @share2.
  ///
  /// In zh, this message translates to:
  /// **'系统分享'**
  String get share2;

  /// No description provided for @saveToCloudShort.
  ///
  /// In zh, this message translates to:
  /// **'存云盘'**
  String get saveToCloudShort;

  /// No description provided for @shareLink.
  ///
  /// In zh, this message translates to:
  /// **'外链分享'**
  String get shareLink;

  /// No description provided for @pressACombinationThatIncludesCtrl.
  ///
  /// In zh, this message translates to:
  /// **'请按下含 Ctrl、Alt 或 Win 的组合键，也可使用 F1–F24。按 Esc 取消。'**
  String get pressACombinationThatIncludesCtrl;

  /// No description provided for @pressAKeyCombinationItMust.
  ///
  /// In zh, this message translates to:
  /// **'请直接按下组合键（需含 ⌘ / ⌥ / ⌃ 或 F1-F12，Esc 取消）'**
  String get pressAKeyCombinationItMust;

  /// No description provided for @hotkeyActive.
  ///
  /// In zh, this message translates to:
  /// **'已生效：{label}'**
  String hotkeyActive(Object label);

  /// No description provided for @hotkeyTakenChooseAnother.
  ///
  /// In zh, this message translates to:
  /// **'系统可能已占用 {label}，请换一个组合键'**
  String hotkeyTakenChooseAnother(Object label);

  /// No description provided for @hotkeyUpdatedTo.
  ///
  /// In zh, this message translates to:
  /// **'全局呼出快捷键已更新为 {label}'**
  String hotkeyUpdatedTo(Object label);

  /// No description provided for @hotkeyTakenTryAnother.
  ///
  /// In zh, this message translates to:
  /// **'系统可能已占用 {label}，请尝试其他组合'**
  String hotkeyTakenTryAnother(Object label);

  /// No description provided for @hotkeySetTo.
  ///
  /// In zh, this message translates to:
  /// **'全局呼出快捷键已设为 {label}'**
  String hotkeySetTo(Object label);

  /// No description provided for @smart.
  ///
  /// In zh, this message translates to:
  /// **'智能'**
  String get smart;

  /// No description provided for @p2pOnly.
  ///
  /// In zh, this message translates to:
  /// **'纯 P2P'**
  String get p2pOnly;

  /// No description provided for @serverDefault.
  ///
  /// In zh, this message translates to:
  /// **'跟随服务器'**
  String get serverDefault;

  /// No description provided for @n24Hours.
  ///
  /// In zh, this message translates to:
  /// **'24 小时'**
  String get n24Hours;

  /// No description provided for @n7Days.
  ///
  /// In zh, this message translates to:
  /// **'7 天'**
  String get n7Days;

  /// No description provided for @n30Days.
  ///
  /// In zh, this message translates to:
  /// **'30 天'**
  String get n30Days;

  /// No description provided for @daysCount.
  ///
  /// In zh, this message translates to:
  /// **'{value} 天'**
  String daysCount(int value);

  /// No description provided for @hoursCount.
  ///
  /// In zh, this message translates to:
  /// **'{cap} 小时'**
  String hoursCount(int cap);

  /// No description provided for @preferences.
  ///
  /// In zh, this message translates to:
  /// **'偏好设置'**
  String get preferences;

  /// No description provided for @smartSendsSmallFilesToThe.
  ///
  /// In zh, this message translates to:
  /// **'智能模式下小文件同步存云盘、大文件直连 P2P；纯 P2P 不经服务器；存云盘支持离线下载。'**
  String get smartSendsSmallFilesToThe;

  /// No description provided for @transferPolicyForNewFiles.
  ///
  /// In zh, this message translates to:
  /// **'新文件传输策略'**
  String get transferPolicyForNewFiles;

  /// No description provided for @transferPolicy.
  ///
  /// In zh, this message translates to:
  /// **'传输策略'**
  String get transferPolicy;

  /// No description provided for @smartModeCloudThreshold.
  ///
  /// In zh, this message translates to:
  /// **'智能模式上云阈值'**
  String get smartModeCloudThreshold;

  /// No description provided for @cloudThreshold.
  ///
  /// In zh, this message translates to:
  /// **'上云阈值'**
  String get cloudThreshold;

  /// No description provided for @inSmartModeFilesSmallerThan.
  ///
  /// In zh, this message translates to:
  /// **'智能模式下，小于该体积的文件同时缓存到云盘，更大的只走 P2P 直连。'**
  String get inSmartModeFilesSmallerThan;

  /// No description provided for @autoCleanup.
  ///
  /// In zh, this message translates to:
  /// **'自动清理'**
  String get autoCleanup;

  /// No description provided for @expiredItemsAreRemovedFromThe.
  ///
  /// In zh, this message translates to:
  /// **'到期后自动清理云端缓存与列表记录。'**
  String get expiredItemsAreRemovedFromThe;

  /// No description provided for @defaultExpiration.
  ///
  /// In zh, this message translates to:
  /// **'默认过期时间'**
  String get defaultExpiration;

  /// No description provided for @expiration.
  ///
  /// In zh, this message translates to:
  /// **'过期时间'**
  String get expiration;

  /// No description provided for @downloads.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get downloads;

  /// No description provided for @saveLocation.
  ///
  /// In zh, this message translates to:
  /// **'保存位置'**
  String get saveLocation;

  /// No description provided for @filesDropdrawer.
  ///
  /// In zh, this message translates to:
  /// **'「文件」App › DropDrawer'**
  String get filesDropdrawer;

  /// No description provided for @loading.
  ///
  /// In zh, this message translates to:
  /// **'加载中…'**
  String get loading;

  /// No description provided for @restoreDefaultLocation.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认位置'**
  String get restoreDefaultLocation;

  /// No description provided for @transfersAutoCleanup.
  ///
  /// In zh, this message translates to:
  /// **'传输与自动清理'**
  String get transfersAutoCleanup;

  /// No description provided for @smartSmallFilesAlsoGoTo.
  ///
  /// In zh, this message translates to:
  /// **'智能：小文件同时存云盘、大文件只走 P2P；纯 P2P：不经过服务器；强制存云盘：来源离线也能下载'**
  String get smartSmallFilesAlsoGoTo;

  /// No description provided for @defaultExpirationCleanup.
  ///
  /// In zh, this message translates to:
  /// **'默认过期自动清理'**
  String get defaultExpirationCleanup;

  /// No description provided for @newFilesAndTextAreRemoved.
  ///
  /// In zh, this message translates to:
  /// **'新拖入的文件/文本到期后自动清理云端缓存与抽屉记录'**
  String get newFilesAndTextAreRemoved;

  /// No description provided for @smartModeAutoUploadThreshold.
  ///
  /// In zh, this message translates to:
  /// **'智能模式自动上云阈值'**
  String get smartModeAutoUploadThreshold;

  /// No description provided for @filesSmallerThanThisAreCached.
  ///
  /// In zh, this message translates to:
  /// **'小于该体积自动缓存至云盘，超过则纯 P2P 端到端直连'**
  String get filesSmallerThanThisAreCached;

  /// No description provided for @defaultDownloadFolder.
  ///
  /// In zh, this message translates to:
  /// **'默认下载目录'**
  String get defaultDownloadFolder;

  /// No description provided for @restoreDefault.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认'**
  String get restoreDefault;

  /// No description provided for @loadingDots.
  ///
  /// In zh, this message translates to:
  /// **'加载中...'**
  String get loadingDots;

  /// No description provided for @changeFolder.
  ///
  /// In zh, this message translates to:
  /// **'更改目录'**
  String get changeFolder;

  /// No description provided for @windowWindowsIntegration.
  ///
  /// In zh, this message translates to:
  /// **'窗口与 Windows 集成'**
  String get windowWindowsIntegration;

  /// No description provided for @windowMacosIntegration.
  ///
  /// In zh, this message translates to:
  /// **'窗口与 macOS 集成'**
  String get windowMacosIntegration;

  /// No description provided for @drawerEdge.
  ///
  /// In zh, this message translates to:
  /// **'边缘抽屉停靠侧'**
  String get drawerEdge;

  /// No description provided for @youCanAlsoDragTheEdge.
  ///
  /// In zh, this message translates to:
  /// **'也可直接按住边缘悬浮手柄上下或跨屏拖动调整'**
  String get youCanAlsoDragTheEdge;

  /// No description provided for @leftSideOfTheScreen.
  ///
  /// In zh, this message translates to:
  /// **'屏幕左侧'**
  String get leftSideOfTheScreen;

  /// No description provided for @rightSideOfTheScreen.
  ///
  /// In zh, this message translates to:
  /// **'屏幕右侧'**
  String get rightSideOfTheScreen;

  /// No description provided for @globalShortcutToOpenTheDrawer.
  ///
  /// In zh, this message translates to:
  /// **'全局快捷键呼出抽屉'**
  String get globalShortcutToOpenTheDrawer;

  /// No description provided for @opensOrClosesTheDrawerFrom.
  ///
  /// In zh, this message translates to:
  /// **'任意应用下快速展开或收起抽屉，可自定义避免冲突'**
  String get opensOrClosesTheDrawerFrom;

  /// No description provided for @currentShortcut.
  ///
  /// In zh, this message translates to:
  /// **'当前快捷键'**
  String get currentShortcut;

  /// No description provided for @pressAKeyCombination.
  ///
  /// In zh, this message translates to:
  /// **'按下组合键...'**
  String get pressAKeyCombination;

  /// No description provided for @clickToChange.
  ///
  /// In zh, this message translates to:
  /// **'点击修改'**
  String get clickToChange;

  /// No description provided for @hotkeyReady.
  ///
  /// In zh, this message translates to:
  /// **'全局监听已就绪 · 任意应用按 {hotkeyLabel} 即可呼出'**
  String hotkeyReady(Object hotkeyLabel);

  /// No description provided for @theGlobalShortcutMayAlreadyBe.
  ///
  /// In zh, this message translates to:
  /// **'全局快捷键可能已被占用，请换一个组合键'**
  String get theGlobalShortcutMayAlreadyBe;

  /// No description provided for @dropdrawerNeedsMacosAccessibilityPermissionTo.
  ///
  /// In zh, this message translates to:
  /// **'需要开启 macOS「辅助功能」权限才能在其他应用下响应全局快捷键'**
  String get dropdrawerNeedsMacosAccessibilityPermissionTo;

  /// No description provided for @openAccessibilitySettings.
  ///
  /// In zh, this message translates to:
  /// **'前往开启辅助功能'**
  String get openAccessibilitySettings;

  /// No description provided for @permissionGrantedTheGlobalShortcutWorks.
  ///
  /// In zh, this message translates to:
  /// **'已检测到权限，全局快捷键立即生效'**
  String get permissionGrantedTheGlobalShortcutWorks;

  /// No description provided for @permissionNotDetectedYetEnableDropdrawer.
  ///
  /// In zh, this message translates to:
  /// **'尚未检测到权限，请在系统设置中勾选 dropdrawer_app'**
  String get permissionNotDetectedYetEnableDropdrawer;

  /// No description provided for @checkAgain.
  ///
  /// In zh, this message translates to:
  /// **'重新检测'**
  String get checkAgain;

  /// No description provided for @showTheDrawerInTheTaskbar.
  ///
  /// In zh, this message translates to:
  /// **'在任务栏显示抽屉'**
  String get showTheDrawerInTheTaskbar;

  /// No description provided for @showIconInTheDock.
  ///
  /// In zh, this message translates to:
  /// **'在程序坞 (Dock) 显示图标'**
  String get showIconInTheDock;

  /// No description provided for @whenOffOpenTheDrawerFrom.
  ///
  /// In zh, this message translates to:
  /// **'关闭时可通过系统托盘打开抽屉'**
  String get whenOffOpenTheDrawerFrom;

  /// No description provided for @whenOffDropdrawerStaysInThe.
  ///
  /// In zh, this message translates to:
  /// **'关闭时仅常驻顶部菜单栏，开启后同时在 Dock 显示'**
  String get whenOffDropdrawerStaysInThe;

  /// No description provided for @translucentBackground.
  ///
  /// In zh, this message translates to:
  /// **'毛玻璃背景'**
  String get translucentBackground;

  /// No description provided for @notSupportedOnThisSystemRequires.
  ///
  /// In zh, this message translates to:
  /// **'当前系统不支持（需 Windows 11 22H2 及以上），已使用不透明背景'**
  String get notSupportedOnThisSystemRequires;

  /// No description provided for @usesTheWindows11MicaAcrylic.
  ///
  /// In zh, this message translates to:
  /// **'使用 Windows 11 的 Mica / 亚克力效果；如背景显示异常可关闭'**
  String get usesTheWindows11MicaAcrylic;

  /// No description provided for @launchAtLogin.
  ///
  /// In zh, this message translates to:
  /// **'开机自动启动'**
  String get launchAtLogin;

  /// No description provided for @staysInTheSystemTrayWhen.
  ///
  /// In zh, this message translates to:
  /// **'登录 Windows 时自动驻留系统托盘'**
  String get staysInTheSystemTrayWhen;

  /// No description provided for @runsQuietlyInTheMenuBar.
  ///
  /// In zh, this message translates to:
  /// **'登录 macOS 时自动静默驻留状态栏与屏幕边缘'**
  String get runsQuietlyInTheMenuBar;

  /// No description provided for @launchAtLoginTurnedOn.
  ///
  /// In zh, this message translates to:
  /// **'已开启开机自启动'**
  String get launchAtLoginTurnedOn;

  /// No description provided for @launchAtLoginTurnedOff.
  ///
  /// In zh, this message translates to:
  /// **'已关闭开机自启动'**
  String get launchAtLoginTurnedOff;

  /// No description provided for @couldnTChangeLaunchAtLogin.
  ///
  /// In zh, this message translates to:
  /// **'修改开机自启动失败'**
  String get couldnTChangeLaunchAtLogin;

  /// No description provided for @shareClipboardText.
  ///
  /// In zh, this message translates to:
  /// **'链接：{url}\n提取码：{plainPasscode}'**
  String shareClipboardText(Object url, Object plainPasscode);

  /// No description provided for @thisServerRequiresAPasscodeFor.
  ///
  /// In zh, this message translates to:
  /// **'服务器要求外链必须设置提取码'**
  String get thisServerRequiresAPasscodeFor;

  /// No description provided for @shareLinkCreatedAndCopiedTo.
  ///
  /// In zh, this message translates to:
  /// **'外链已生成并自动复制到剪贴板'**
  String get shareLinkCreatedAndCopiedTo;

  /// No description provided for @manageShareLinks.
  ///
  /// In zh, this message translates to:
  /// **'外链分享管理'**
  String get manageShareLinks;

  /// No description provided for @createBundleLinkItems.
  ///
  /// In zh, this message translates to:
  /// **'打包创建外链 ({targetItemsLength} 项)'**
  String createBundleLinkItems(int targetItemsLength);

  /// No description provided for @bundleLinkCount.
  ///
  /// In zh, this message translates to:
  /// **'打包外链 ({targetItemsLength})'**
  String bundleLinkCount(Object targetItemsLength);

  /// No description provided for @createShareLink2.
  ///
  /// In zh, this message translates to:
  /// **'创建外链'**
  String get createShareLink2;

  /// No description provided for @shareLinksTitle.
  ///
  /// In zh, this message translates to:
  /// **'外链管理'**
  String get shareLinksTitle;

  /// No description provided for @refreshShareLinks.
  ///
  /// In zh, this message translates to:
  /// **'刷新外链列表'**
  String get refreshShareLinks;

  /// No description provided for @shareLinksAreTurnedOffOn2.
  ///
  /// In zh, this message translates to:
  /// **'服务器已关闭外链分享，暂时无法创建新的外链。'**
  String get shareLinksAreTurnedOffOn2;

  /// No description provided for @createdLinksCount.
  ///
  /// In zh, this message translates to:
  /// **'已创建的外链 ({shareLinksLength})'**
  String createdLinksCount(Object shareLinksLength);

  /// No description provided for @noShareLinksYetNclickAn.
  ///
  /// In zh, this message translates to:
  /// **'暂无外链分享\n点击单条链接图标，或进入「多选」打包创建合集外链'**
  String get noShareLinksYetNclickAn;

  /// No description provided for @n1Hour.
  ///
  /// In zh, this message translates to:
  /// **'1 小时'**
  String get n1Hour;

  /// No description provided for @forever.
  ///
  /// In zh, this message translates to:
  /// **'永久'**
  String get forever;

  /// No description provided for @unlimited.
  ///
  /// In zh, this message translates to:
  /// **'不限'**
  String get unlimited;

  /// No description provided for @n1TimeBurnAfterReading.
  ///
  /// In zh, this message translates to:
  /// **'1 次（阅后即焚）'**
  String get n1TimeBurnAfterReading;

  /// No description provided for @n5Times.
  ///
  /// In zh, this message translates to:
  /// **'5 次'**
  String get n5Times;

  /// No description provided for @n20Times.
  ///
  /// In zh, this message translates to:
  /// **'20 次'**
  String get n20Times;

  /// No description provided for @hoursCountH.
  ///
  /// In zh, this message translates to:
  /// **'{h} 小时'**
  String hoursCountH(int h);

  /// No description provided for @valueAtCap.
  ///
  /// In zh, this message translates to:
  /// **'{value}（上限）'**
  String valueAtCap(Object value);

  /// No description provided for @timesAtCap.
  ///
  /// In zh, this message translates to:
  /// **'{n} 次（上限）'**
  String timesAtCap(int n);

  /// No description provided for @bundleItemsSize.
  ///
  /// In zh, this message translates to:
  /// **'打包 {itemsLength} 项 · {value}'**
  String bundleItemsSize(int itemsLength, Object value);

  /// No description provided for @sharedContent.
  ///
  /// In zh, this message translates to:
  /// **'分享内容'**
  String get sharedContent;

  /// No description provided for @uploadBeforeShareNote.
  ///
  /// In zh, this message translates to:
  /// **'生成前会先把 {pendingUploadCount} 个文件上传到「{defaultStorageBackendName}」，拿到链接的人用浏览器即可下载，无需登录。'**
  String uploadBeforeShareNote(
    int pendingUploadCount,
    Object defaultStorageBackendName,
  );

  /// No description provided for @anyoneWithTheLinkCanDownload.
  ///
  /// In zh, this message translates to:
  /// **'拿到链接的人用浏览器即可下载，无需登录。'**
  String get anyoneWithTheLinkCanDownload;

  /// No description provided for @andMoreItems.
  ///
  /// In zh, this message translates to:
  /// **'以及另外 {value} 项'**
  String andMoreItems(int value);

  /// No description provided for @bundleTitle.
  ///
  /// In zh, this message translates to:
  /// **'合集标题'**
  String get bundleTitle;

  /// No description provided for @firstNameAndMore.
  ///
  /// In zh, this message translates to:
  /// **'{firstName} 等 {itemsLength} 项'**
  String firstNameAndMore(Object firstName, int itemsLength);

  /// No description provided for @access.
  ///
  /// In zh, this message translates to:
  /// **'访问设置'**
  String get access;

  /// No description provided for @thisServerRequiresAPasscodeFor2.
  ///
  /// In zh, this message translates to:
  /// **'服务器要求外链必须设置提取码。'**
  String get thisServerRequiresAPasscodeFor2;

  /// No description provided for @ifYouLeaveThePasscodeEmpty.
  ///
  /// In zh, this message translates to:
  /// **'提取码留空时，任何拿到链接的人都能下载。'**
  String get ifYouLeaveThePasscodeEmpty;

  /// No description provided for @expiresAfter.
  ///
  /// In zh, this message translates to:
  /// **'有效期'**
  String get expiresAfter;

  /// No description provided for @downloads2.
  ///
  /// In zh, this message translates to:
  /// **'下载次数'**
  String get downloads2;

  /// No description provided for @passcodeRequired.
  ///
  /// In zh, this message translates to:
  /// **'提取码（必填）'**
  String get passcodeRequired;

  /// No description provided for @passcode.
  ///
  /// In zh, this message translates to:
  /// **'提取码'**
  String get passcode;

  /// No description provided for @leaveEmptyForPublic.
  ///
  /// In zh, this message translates to:
  /// **'留空为公开'**
  String get leaveEmptyForPublic;

  /// No description provided for @generateA4CharacterPasscode.
  ///
  /// In zh, this message translates to:
  /// **'随机生成 4 位提取码'**
  String get generateA4CharacterPasscode;

  /// No description provided for @creating.
  ///
  /// In zh, this message translates to:
  /// **'正在生成…'**
  String get creating;

  /// No description provided for @uploadAndCreateLink.
  ///
  /// In zh, this message translates to:
  /// **'上传并生成外链'**
  String get uploadAndCreateLink;

  /// No description provided for @createBundleLinkAndCopy.
  ///
  /// In zh, this message translates to:
  /// **'生成合集外链并复制'**
  String get createBundleLinkAndCopy;

  /// No description provided for @createLinkAndCopy.
  ///
  /// In zh, this message translates to:
  /// **'生成外链并复制'**
  String get createLinkAndCopy;

  /// No description provided for @createdAndCopiedToTheClipboard.
  ///
  /// In zh, this message translates to:
  /// **'已生成并复制到剪贴板'**
  String get createdAndCopiedToTheClipboard;

  /// No description provided for @linkLabel.
  ///
  /// In zh, this message translates to:
  /// **'链接'**
  String get linkLabel;

  /// No description provided for @copyAgain.
  ///
  /// In zh, this message translates to:
  /// **'再次复制'**
  String get copyAgain;

  /// No description provided for @copiedLinkDetails.
  ///
  /// In zh, this message translates to:
  /// **'已复制外链信息'**
  String get copiedLinkDetails;

  /// No description provided for @openInBrowser.
  ///
  /// In zh, this message translates to:
  /// **'在浏览器中打开'**
  String get openInBrowser;

  /// No description provided for @createdLinksCountFull.
  ///
  /// In zh, this message translates to:
  /// **'已创建的外链（{shareLinksLength}）'**
  String createdLinksCountFull(Object shareLinksLength);

  /// No description provided for @longPressOrOpenAnyItem.
  ///
  /// In zh, this message translates to:
  /// **'在首页长按或打开任意一项即可创建外链；多选后可打包成合集。'**
  String get longPressOrOpenAnyItem;

  /// No description provided for @tapALinkToCopyOpen.
  ///
  /// In zh, this message translates to:
  /// **'点按一条外链可以复制、打开或撤销。'**
  String get tapALinkToCopyOpen;

  /// No description provided for @loadingEllipsis.
  ///
  /// In zh, this message translates to:
  /// **'正在加载…'**
  String get loadingEllipsis;

  /// No description provided for @noShareLinksYet.
  ///
  /// In zh, this message translates to:
  /// **'还没有外链'**
  String get noShareLinksYet;

  /// No description provided for @bundleOfItems.
  ///
  /// In zh, this message translates to:
  /// **'{itemCount} 项合集'**
  String bundleOfItems(int itemCount);

  /// No description provided for @passcodeRequired2.
  ///
  /// In zh, this message translates to:
  /// **'需提取码'**
  String get passcodeRequired2;

  /// No description provided for @downloadedOfMax.
  ///
  /// In zh, this message translates to:
  /// **'已下 {downloadCount}/{maxDownloads} 次'**
  String downloadedOfMax(Object downloadCount, Object maxDownloads);

  /// No description provided for @downloadedCount.
  ///
  /// In zh, this message translates to:
  /// **'已下 {downloadCount} 次'**
  String downloadedCount(int downloadCount);

  /// No description provided for @expired.
  ///
  /// In zh, this message translates to:
  /// **'已过期'**
  String get expired;

  /// No description provided for @downloadLimitReached.
  ///
  /// In zh, this message translates to:
  /// **'次数用尽'**
  String get downloadLimitReached;

  /// No description provided for @neverExpires2.
  ///
  /// In zh, this message translates to:
  /// **'永久有效'**
  String get neverExpires2;

  /// No description provided for @copyLink.
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get copyLink;

  /// No description provided for @linkCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制外链'**
  String get linkCopied;

  /// No description provided for @revokeLink.
  ///
  /// In zh, this message translates to:
  /// **'撤销外链'**
  String get revokeLink;

  /// No description provided for @primaryNameAndMore.
  ///
  /// In zh, this message translates to:
  /// **'{primaryName} 等 {itemsLength} 项'**
  String primaryNameAndMore(Object primaryName, int itemsLength);

  /// No description provided for @sizeUploadBeforeShare.
  ///
  /// In zh, this message translates to:
  /// **'{value} · 生成前自动上云 {pendingUploadCount} 个文件至「{defaultStorageBackendName}」'**
  String sizeUploadBeforeShare(
    Object value,
    int pendingUploadCount,
    Object defaultStorageBackendName,
  );

  /// No description provided for @sizeReadyNoSignIn.
  ///
  /// In zh, this message translates to:
  /// **'{value} · 已就绪，外部浏览器免登录提取'**
  String sizeReadyNoSignIn(Object value);

  /// No description provided for @optionalDefaultTitle.
  ///
  /// In zh, this message translates to:
  /// **'可选，默认「{primaryName} 等 {itemsLength} 项」'**
  String optionalDefaultTitle(Object primaryName, Object itemsLength);

  /// No description provided for @downloadLimit.
  ///
  /// In zh, this message translates to:
  /// **'下载次数限制'**
  String get downloadLimit;

  /// No description provided for @oneTimeBurn.
  ///
  /// In zh, this message translates to:
  /// **'1次(阅后即焚)'**
  String get oneTimeBurn;

  /// No description provided for @leaveEmptyForPublicAccess.
  ///
  /// In zh, this message translates to:
  /// **'留空为公开免密'**
  String get leaveEmptyForPublicAccess;

  /// No description provided for @uploadToCloudAndCreateLink.
  ///
  /// In zh, this message translates to:
  /// **'自动上云并生成外链'**
  String get uploadToCloudAndCreateLink;

  /// No description provided for @copyLinkAgain.
  ///
  /// In zh, this message translates to:
  /// **'再次复制链接'**
  String get copyLinkAgain;

  /// No description provided for @previewInBrowser.
  ///
  /// In zh, this message translates to:
  /// **'在浏览器中打开预览'**
  String get previewInBrowser;

  /// No description provided for @copyLinkUrl.
  ///
  /// In zh, this message translates to:
  /// **'复制外链 ({fullUrl})'**
  String copyLinkUrl(Object fullUrl);

  /// No description provided for @linkCopiedUrl.
  ///
  /// In zh, this message translates to:
  /// **'已复制外链：{fullUrl}'**
  String linkCopiedUrl(Object fullUrl);

  /// No description provided for @openInBrowserShort.
  ///
  /// In zh, this message translates to:
  /// **'浏览器打开'**
  String get openInBrowserShort;

  /// No description provided for @daysLeft.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {diffInDays} 天'**
  String daysLeft(int diffInDays);

  /// No description provided for @hoursLeft.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {diffInHours} 小时'**
  String hoursLeft(int diffInHours);

  /// No description provided for @minutesLeft.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {value} 分钟'**
  String minutesLeft(int value);

  /// No description provided for @quarkDrive.
  ///
  /// In zh, this message translates to:
  /// **'夸克网盘'**
  String get quarkDrive;

  /// No description provided for @baiduNetdisk.
  ///
  /// In zh, this message translates to:
  /// **'百度网盘'**
  String get baiduNetdisk;

  /// No description provided for @webdavStorage.
  ///
  /// In zh, this message translates to:
  /// **'WebDAV 网盘'**
  String get webdavStorage;

  /// No description provided for @serverLocalStorage.
  ///
  /// In zh, this message translates to:
  /// **'服务器本地盘'**
  String get serverLocalStorage;

  /// No description provided for @enterTheGoogleOauthClientId.
  ///
  /// In zh, this message translates to:
  /// **'请先填写 Google OAuth Client ID 和 Client Secret'**
  String get enterTheGoogleOauthClientId;

  /// No description provided for @googleDriveAuthorizationOpenedInYour.
  ///
  /// In zh, this message translates to:
  /// **'已打开浏览器授权 Google Drive，同意后点下方「刷新列表」即可'**
  String get googleDriveAuthorizationOpenedInYour;

  /// No description provided for @authorizationFailedToStart.
  ///
  /// In zh, this message translates to:
  /// **'发起授权失败: {e}'**
  String authorizationFailedToStart(Object e);

  /// No description provided for @enterARefreshTokenOrUse.
  ///
  /// In zh, this message translates to:
  /// **'请填写 Refresh Token，或点击上方「浏览器一键授权 Google」'**
  String get enterARefreshTokenOrUse;

  /// No description provided for @pasteTheCookieFromPanQuark.
  ///
  /// In zh, this message translates to:
  /// **'请粘贴 pan.quark.cn 的 Cookie'**
  String get pasteTheCookieFromPanQuark;

  /// No description provided for @storageSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存原生云盘策略'**
  String get storageSaved;

  /// No description provided for @saveFailedColon.
  ///
  /// In zh, this message translates to:
  /// **'保存失败: {e}'**
  String saveFailedColon(Object e);

  /// No description provided for @cloudStorage.
  ///
  /// In zh, this message translates to:
  /// **'云盘与存储'**
  String get cloudStorage;

  /// No description provided for @refreshStorageList.
  ///
  /// In zh, this message translates to:
  /// **'刷新存储列表'**
  String get refreshStorageList;

  /// No description provided for @cloudStorage2.
  ///
  /// In zh, this message translates to:
  /// **'原生云盘与存储'**
  String get cloudStorage2;

  /// No description provided for @editStorage.
  ///
  /// In zh, this message translates to:
  /// **'编辑存储'**
  String get editStorage;

  /// No description provided for @configured.
  ///
  /// In zh, this message translates to:
  /// **'已配置云盘'**
  String get configured;

  /// No description provided for @addStorage.
  ///
  /// In zh, this message translates to:
  /// **'添加原生云盘'**
  String get addStorage;

  /// No description provided for @theServerAdministratorHasDisabledEvery.
  ///
  /// In zh, this message translates to:
  /// **'服务器管理员已停用所有可添加的存储类型，暂时无法添加新的云盘。'**
  String get theServerAdministratorHasDisabledEvery;

  /// No description provided for @localDisk.
  ///
  /// In zh, this message translates to:
  /// **'本地盘'**
  String get localDisk;

  /// No description provided for @name.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get name;

  /// No description provided for @optionalUseOneClickAuthorizationBelow.
  ///
  /// In zh, this message translates to:
  /// **'可留空，点下方一键授权自动获取'**
  String get optionalUseOneClickAuthorizationBelow;

  /// No description provided for @folderId.
  ///
  /// In zh, this message translates to:
  /// **'目录 ID'**
  String get folderId;

  /// No description provided for @rootOrAFolderId.
  ///
  /// In zh, this message translates to:
  /// **'root (或指定文件夹 ID)'**
  String get rootOrAFolderId;

  /// No description provided for @fullCookieFromPanQuarkCn.
  ///
  /// In zh, this message translates to:
  /// **'pan.quark.cn 完整 Cookie'**
  String get fullCookieFromPanQuarkCn;

  /// No description provided for @folderFid.
  ///
  /// In zh, this message translates to:
  /// **'目录 fid'**
  String get folderFid;

  /// No description provided for @n0IsTheRootFolder.
  ///
  /// In zh, this message translates to:
  /// **'0 表示根目录'**
  String get n0IsTheRootFolder;

  /// No description provided for @accessTokenOrFillInRefresh.
  ///
  /// In zh, this message translates to:
  /// **'Access Token (或填下方 Refresh)'**
  String get accessTokenOrFillInRefresh;

  /// No description provided for @optionalUsedForAutomaticRefresh.
  ///
  /// In zh, this message translates to:
  /// **'可选，用于自动刷新'**
  String get optionalUsedForAutomaticRefresh;

  /// No description provided for @optionalLongLivedRefreshToken10.
  ///
  /// In zh, this message translates to:
  /// **'可选，10年长效刷新令牌'**
  String get optionalLongLivedRefreshToken10;

  /// No description provided for @path.
  ///
  /// In zh, this message translates to:
  /// **'路径'**
  String get path;

  /// No description provided for @url.
  ///
  /// In zh, this message translates to:
  /// **'地址'**
  String get url;

  /// No description provided for @username.
  ///
  /// In zh, this message translates to:
  /// **'用户名'**
  String get username;

  /// No description provided for @filesAreSavedInThisAccount.
  ///
  /// In zh, this message translates to:
  /// **'文件保存在服务器数据目录中属于当前账号的文件夹（由服务端 DROPDRAWER_LOCAL_STORAGE 决定）。'**
  String get filesAreSavedInThisAccount;

  /// No description provided for @newCloudUploadsUseTheDefault.
  ///
  /// In zh, this message translates to:
  /// **'新上传至云端的文件会使用默认存储。'**
  String get newCloudUploadsUseTheDefault;

  /// No description provided for @connectionOk.
  ///
  /// In zh, this message translates to:
  /// **'连通正常: {msg}'**
  String connectionOk(Object msg);

  /// No description provided for @connectionFailed.
  ///
  /// In zh, this message translates to:
  /// **'连通失败: {msg}'**
  String connectionFailed(Object msg);

  /// No description provided for @defaultStorageUpdated.
  ///
  /// In zh, this message translates to:
  /// **'已更新默认存储'**
  String get defaultStorageUpdated;

  /// No description provided for @switchDefaultStorageFailed.
  ///
  /// In zh, this message translates to:
  /// **'切换默认存储失败：{e}'**
  String switchDefaultStorageFailed(Object e);

  /// No description provided for @configuredShort.
  ///
  /// In zh, this message translates to:
  /// **'已配置'**
  String get configuredShort;

  /// No description provided for @addStorageShort.
  ///
  /// In zh, this message translates to:
  /// **'添加云盘'**
  String get addStorageShort;

  /// No description provided for @noStorageYetSwitchToAdd.
  ///
  /// In zh, this message translates to:
  /// **'还没有存储策略，切换到「添加云盘」直连配置。'**
  String get noStorageYetSwitchToAdd;

  /// No description provided for @tapToEditNote.
  ///
  /// In zh, this message translates to:
  /// **'点按存储项可编辑。{defaultNote}'**
  String tapToEditNote(Object defaultNote);

  /// No description provided for @noStorage.
  ///
  /// In zh, this message translates to:
  /// **'暂无云盘'**
  String get noStorage;

  /// No description provided for @defaultLabel.
  ///
  /// In zh, this message translates to:
  /// **'默认'**
  String get defaultLabel;

  /// No description provided for @setAsDefault.
  ///
  /// In zh, this message translates to:
  /// **'设为默认'**
  String get setAsDefault;

  /// No description provided for @edit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get edit;

  /// No description provided for @testConnection.
  ///
  /// In zh, this message translates to:
  /// **'测试连通性'**
  String get testConnection;

  /// No description provided for @delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get delete;

  /// No description provided for @typeLabel.
  ///
  /// In zh, this message translates to:
  /// **'类型'**
  String get typeLabel;

  /// No description provided for @storageType.
  ///
  /// In zh, this message translates to:
  /// **'云盘类型'**
  String get storageType;

  /// No description provided for @storageBack.
  ///
  /// In zh, this message translates to:
  /// **'云盘'**
  String get storageBack;

  /// No description provided for @connection.
  ///
  /// In zh, this message translates to:
  /// **'连接信息'**
  String get connection;

  /// No description provided for @callbackUrlHint.
  ///
  /// In zh, this message translates to:
  /// **'回调地址请填：{serverUrl}/api/oauth/google/callback'**
  String callbackUrlHint(Object serverUrl);

  /// No description provided for @useAsDefaultTransferStorage.
  ///
  /// In zh, this message translates to:
  /// **'设为默认中转存储'**
  String get useAsDefaultTransferStorage;

  /// No description provided for @authorizeGoogleDriveInBrowser.
  ///
  /// In zh, this message translates to:
  /// **'在浏览器中授权 Google Drive'**
  String get authorizeGoogleDriveInBrowser;

  /// No description provided for @iAlreadyHaveARefreshToken.
  ///
  /// In zh, this message translates to:
  /// **'已有 Refresh Token，直接保存'**
  String get iAlreadyHaveARefreshToken;

  /// No description provided for @saving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存…'**
  String get saving;

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @noStorageYetUseAddStorage.
  ///
  /// In zh, this message translates to:
  /// **'暂无存储策略，点击上方「添加原生云盘」直连配置'**
  String get noStorageYetUseAddStorage;

  /// No description provided for @cantReadStorage.
  ///
  /// In zh, this message translates to:
  /// **'无法读取存储配置：{e}'**
  String cantReadStorage(Object e);

  /// No description provided for @storageNameCanTBeEmpty.
  ///
  /// In zh, this message translates to:
  /// **'存储名称不能为空'**
  String get storageNameCanTBeEmpty;

  /// No description provided for @theCapacityLimitMustBeA.
  ///
  /// In zh, this message translates to:
  /// **'容量上限必须为正整数'**
  String get theCapacityLimitMustBeA;

  /// No description provided for @storageSettingsSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存存储配置'**
  String get storageSettingsSaved;

  /// No description provided for @saveFailedFull.
  ///
  /// In zh, this message translates to:
  /// **'保存失败：{e}'**
  String saveFailedFull(Object e);

  /// No description provided for @leaveTheCapacityLimitEmptyFor.
  ///
  /// In zh, this message translates to:
  /// **'容量上限留空表示不限。'**
  String get leaveTheCapacityLimitEmptyFor;

  /// No description provided for @leaveFieldsEmptyToKeepThe.
  ///
  /// In zh, this message translates to:
  /// **'留空保留现有凭据。更换存储位置可使用「添加云盘」。'**
  String get leaveFieldsEmptyToKeepThe;

  /// No description provided for @limitBytes.
  ///
  /// In zh, this message translates to:
  /// **'上限（字节）'**
  String get limitBytes;

  /// No description provided for @saveChanges.
  ///
  /// In zh, this message translates to:
  /// **'保存修改'**
  String get saveChanges;

  /// No description provided for @storageLocation.
  ///
  /// In zh, this message translates to:
  /// **'存储位置'**
  String get storageLocation;

  /// No description provided for @authorizeGoogleDriveInBrowserOne.
  ///
  /// In zh, this message translates to:
  /// **'浏览器一键授权 Google Drive'**
  String get authorizeGoogleDriveInBrowserOne;

  /// No description provided for @alreadyHaveARefreshTokenSave.
  ///
  /// In zh, this message translates to:
  /// **'已有 Refresh Token？直接保存'**
  String get alreadyHaveARefreshTokenSave;

  /// No description provided for @saveStorage.
  ///
  /// In zh, this message translates to:
  /// **'保存原生云盘配置'**
  String get saveStorage;

  /// No description provided for @localDiskFull.
  ///
  /// In zh, this message translates to:
  /// **'本地磁盘'**
  String get localDiskFull;

  /// No description provided for @p2pEndToEndOnThis.
  ///
  /// In zh, this message translates to:
  /// **'仅本机 P2P 端到端直连 · 不占服务器与云盘'**
  String get p2pEndToEndOnThis;

  /// No description provided for @policyAlwaysUploadShort.
  ///
  /// In zh, this message translates to:
  /// **'直接上传至「{defaultStorageBackendName}」· 离线可下'**
  String policyAlwaysUploadShort(Object defaultStorageBackendName);

  /// No description provided for @policySmartShort.
  ///
  /// In zh, this message translates to:
  /// **'小于 {value}MB 自动云存 · 大文件纯 P2P 直连'**
  String policySmartShort(Object value);

  /// No description provided for @dockedToTheLeftSideOf.
  ///
  /// In zh, this message translates to:
  /// **'已停靠到屏幕左侧'**
  String get dockedToTheLeftSideOf;

  /// No description provided for @dockedToTheRightSideOf.
  ///
  /// In zh, this message translates to:
  /// **'已停靠到屏幕右侧'**
  String get dockedToTheRightSideOf;

  /// No description provided for @transfersInProgress.
  ///
  /// In zh, this message translates to:
  /// **'还有 {active} 项传输正在进行'**
  String transfersInProgress(int active);

  /// No description provided for @quittingInterruptsTheCurrentTransfersUnfinished.
  ///
  /// In zh, this message translates to:
  /// **'退出软件会中断当前传输（下次打开时未完成的云盘上传会自动续传）。是否仍要退出？'**
  String get quittingInterruptsTheCurrentTransfersUnfinished;

  /// No description provided for @quitAnyway.
  ///
  /// In zh, this message translates to:
  /// **'仍要退出'**
  String get quitAnyway;

  /// No description provided for @keepRunningInBackground.
  ///
  /// In zh, this message translates to:
  /// **'后台继续'**
  String get keepRunningInBackground;

  /// No description provided for @clearAll.
  ///
  /// In zh, this message translates to:
  /// **'清空全部'**
  String get clearAll;

  /// No description provided for @clearAllMessage.
  ///
  /// In zh, this message translates to:
  /// **'将清理列表中的 {itemsLength} 项内容及其在服务器或网盘的副本。本机原文件会保留。'**
  String clearAllMessage(int itemsLength);

  /// No description provided for @clear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get clear;

  /// No description provided for @filePickerFailed.
  ///
  /// In zh, this message translates to:
  /// **'打开文件选择器失败: {e}'**
  String filePickerFailed(Object e);

  /// No description provided for @photoPickerFailed.
  ///
  /// In zh, this message translates to:
  /// **'打开相册失败: {e}'**
  String photoPickerFailed(Object e);

  /// No description provided for @screenshotPastedAndSyncedToThe.
  ///
  /// In zh, this message translates to:
  /// **'已粘贴截图并同步到抽屉'**
  String get screenshotPastedAndSyncedToThe;

  /// No description provided for @pastedFiles.
  ///
  /// In zh, this message translates to:
  /// **'已粘贴 {pathsLength} 个文件到抽屉'**
  String pastedFiles(int pathsLength);

  /// No description provided for @foldersCanTBePastedDirectly.
  ///
  /// In zh, this message translates to:
  /// **'暂不支持直接粘贴文件夹，请先压缩或选择具体文件'**
  String get foldersCanTBePastedDirectly;

  /// No description provided for @theClipboardIsEmptyYouCan.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板为空（支持粘贴文件、截图或文本）'**
  String get theClipboardIsEmptyYouCan;

  /// No description provided for @clipboardReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取剪贴板失败: {e}'**
  String clipboardReadFailed(Object e);

  /// No description provided for @add.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get add;

  /// No description provided for @releaseToDropIntoTheDrawer.
  ///
  /// In zh, this message translates to:
  /// **'松手放入跨端抽屉'**
  String get releaseToDropIntoTheDrawer;

  /// No description provided for @moveDrawer.
  ///
  /// In zh, this message translates to:
  /// **'拖动抽屉'**
  String get moveDrawer;

  /// No description provided for @dragHereToDropIntoThe.
  ///
  /// In zh, this message translates to:
  /// **'拖到这儿，放入跨端抽屉'**
  String get dragHereToDropIntoThe;

  /// No description provided for @chooseFiles.
  ///
  /// In zh, this message translates to:
  /// **'选取文件'**
  String get chooseFiles;

  /// No description provided for @photoLibrary.
  ///
  /// In zh, this message translates to:
  /// **'照片图库'**
  String get photoLibrary;

  /// No description provided for @paste.
  ///
  /// In zh, this message translates to:
  /// **'粘贴'**
  String get paste;

  /// No description provided for @select.
  ///
  /// In zh, this message translates to:
  /// **'选择'**
  String get select;

  /// No description provided for @downloadAll.
  ///
  /// In zh, this message translates to:
  /// **'全部下载'**
  String get downloadAll;

  /// No description provided for @devicesP2p.
  ///
  /// In zh, this message translates to:
  /// **'设备与 P2P'**
  String get devicesP2p;

  /// No description provided for @signOut.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get signOut;

  /// No description provided for @selectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {selectedIdsLength} 项'**
  String selectedCount(Object selectedIdsLength);

  /// No description provided for @more.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get more;

  /// No description provided for @deselectAll.
  ///
  /// In zh, this message translates to:
  /// **'取消全选'**
  String get deselectAll;

  /// No description provided for @selectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get selectAll;

  /// No description provided for @done.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get done;

  /// No description provided for @searchDropdrawer.
  ///
  /// In zh, this message translates to:
  /// **'在 DropDrawer 中搜索'**
  String get searchDropdrawer;

  /// No description provided for @closeSearch.
  ///
  /// In zh, this message translates to:
  /// **'关闭搜索'**
  String get closeSearch;

  /// No description provided for @clearSearch.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get clearSearch;

  /// No description provided for @connecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接…'**
  String get connecting;

  /// No description provided for @devicesOnline.
  ///
  /// In zh, this message translates to:
  /// **'{onlineDeviceCount} 台设备在线'**
  String devicesOnline(int onlineDeviceCount);

  /// No description provided for @itemsCount.
  ///
  /// In zh, this message translates to:
  /// **'{itemsLength} 项'**
  String itemsCount(int itemsLength);

  /// No description provided for @all.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get all;

  /// No description provided for @text.
  ///
  /// In zh, this message translates to:
  /// **'文本'**
  String get text;

  /// No description provided for @search.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get search;

  /// No description provided for @statusFiltered.
  ///
  /// In zh, this message translates to:
  /// **'{status} · 筛选 {visibleItemsLength}/{itemsLength}'**
  String statusFiltered(
    Object status,
    Object visibleItemsLength,
    Object itemsLength,
  );

  /// No description provided for @statusItems.
  ///
  /// In zh, this message translates to:
  /// **'{status} · {itemsLength} 项'**
  String statusItems(Object status, int itemsLength);

  /// No description provided for @saveToCloudAction.
  ///
  /// In zh, this message translates to:
  /// **'存到云盘'**
  String get saveToCloudAction;

  /// No description provided for @devicesOnlineShort.
  ///
  /// In zh, this message translates to:
  /// **'{onlineDeviceCount} 设备在线'**
  String devicesOnlineShort(Object onlineDeviceCount);

  /// No description provided for @pinnedOpenClickToHideAutomatically.
  ///
  /// In zh, this message translates to:
  /// **'已固定展开（点击开启离开自动隐藏）'**
  String get pinnedOpenClickToHideAutomatically;

  /// No description provided for @hidesAutomaticallyWhenYouLeaveClick.
  ///
  /// In zh, this message translates to:
  /// **'离开自动隐藏（点击固定展开）'**
  String get hidesAutomaticallyWhenYouLeaveClick;

  /// No description provided for @collapseToEdgeEsc.
  ///
  /// In zh, this message translates to:
  /// **'收起到边缘 (Esc)'**
  String get collapseToEdgeEsc;

  /// No description provided for @switchToARegularWindow.
  ///
  /// In zh, this message translates to:
  /// **'切换为常规窗口'**
  String get switchToARegularWindow;

  /// No description provided for @switchToTheEdgeDrawer.
  ///
  /// In zh, this message translates to:
  /// **'切换为边缘抽屉'**
  String get switchToTheEdgeDrawer;

  /// No description provided for @cloudStorageTransferStorage.
  ///
  /// In zh, this message translates to:
  /// **'多云盘与中转存储'**
  String get cloudStorageTransferStorage;

  /// No description provided for @deviceStatus.
  ///
  /// In zh, this message translates to:
  /// **'设备状态'**
  String get deviceStatus;

  /// No description provided for @clearDrawer.
  ///
  /// In zh, this message translates to:
  /// **'清空抽屉'**
  String get clearDrawer;

  /// No description provided for @dockRight.
  ///
  /// In zh, this message translates to:
  /// **'停靠右侧'**
  String get dockRight;

  /// No description provided for @dockLeft.
  ///
  /// In zh, this message translates to:
  /// **'停靠左侧'**
  String get dockLeft;

  /// No description provided for @quit.
  ///
  /// In zh, this message translates to:
  /// **'退出应用'**
  String get quit;

  /// No description provided for @releaseToDropIntoTheDrawer2.
  ///
  /// In zh, this message translates to:
  /// **'松开即可放入抽屉'**
  String get releaseToDropIntoTheDrawer2;

  /// No description provided for @dropPickOrPaste.
  ///
  /// In zh, this message translates to:
  /// **'拖入、选取或 {pasteShortcutLabel} 粘贴'**
  String dropPickOrPaste(Object pasteShortcutLabel);

  /// No description provided for @smartPasteTooltip.
  ///
  /// In zh, this message translates to:
  /// **'智能粘贴文件 / 截图 / 文本 ({pasteShortcutLabel})'**
  String smartPasteTooltip(Object pasteShortcutLabel);

  /// No description provided for @smartPolicyShort.
  ///
  /// In zh, this message translates to:
  /// **'智能(<{value}M上云)'**
  String smartPolicyShort(Object value);

  /// No description provided for @policyP2pOnly.
  ///
  /// In zh, this message translates to:
  /// **'纯 P2P 直连'**
  String get policyP2pOnly;

  /// No description provided for @alwaysSaveToCloud.
  ///
  /// In zh, this message translates to:
  /// **'强制存云盘'**
  String get alwaysSaveToCloud;

  /// No description provided for @selectAllCount.
  ///
  /// In zh, this message translates to:
  /// **'全选 ({visibleItemsLength})'**
  String selectAllCount(Object visibleItemsLength);

  /// No description provided for @filteredResults.
  ///
  /// In zh, this message translates to:
  /// **'筛选结果 · {visibleItemsLength}/{itemsLength}'**
  String filteredResults(Object visibleItemsLength, Object itemsLength);

  /// No description provided for @drawerItemsCount.
  ///
  /// In zh, this message translates to:
  /// **'抽屉内容 · {itemsLength} 项'**
  String drawerItemsCount(int itemsLength);

  /// No description provided for @multiSelect.
  ///
  /// In zh, this message translates to:
  /// **'多选'**
  String get multiSelect;

  /// No description provided for @confirmClear.
  ///
  /// In zh, this message translates to:
  /// **'确认清空'**
  String get confirmClear;

  /// No description provided for @searchFileNamesOrText.
  ///
  /// In zh, this message translates to:
  /// **'搜索文件名或文本...'**
  String get searchFileNamesOrText;

  /// No description provided for @removedItem.
  ///
  /// In zh, this message translates to:
  /// **'已移出「{itemName}」'**
  String removedItem(Object itemName);

  /// No description provided for @undo.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get undo;

  /// No description provided for @shareAction.
  ///
  /// In zh, this message translates to:
  /// **'分享'**
  String get shareAction;

  /// No description provided for @copy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get copy;

  /// No description provided for @copiedFiles.
  ///
  /// In zh, this message translates to:
  /// **'已复制 {localSelectedPathsLength} 个文件，可直接 {pasteShortcutLabel} 粘贴'**
  String copiedFiles(int localSelectedPathsLength, Object pasteShortcutLabel);

  /// No description provided for @deleteCount.
  ///
  /// In zh, this message translates to:
  /// **'删除({selectedItemsLength})'**
  String deleteCount(Object selectedItemsLength);

  /// No description provided for @nothingHereYet.
  ///
  /// In zh, this message translates to:
  /// **'暂无内容'**
  String get nothingHereYet;

  /// No description provided for @theDrawerIsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'抽屉是空的'**
  String get theDrawerIsEmpty;

  /// No description provided for @tapAddAtTheBottomRight.
  ///
  /// In zh, this message translates to:
  /// **'点右下角「添加」选取文件、照片或粘贴内容\n也可在其他 App 中「分享 → DropDrawer」发送'**
  String get tapAddAtTheBottomRight;

  /// No description provided for @tapAtTheBottomRightTo.
  ///
  /// In zh, this message translates to:
  /// **'点右下角「+」选取文件、照片或粘贴内容\n也可在其他 App 中「分享 → DropDrawer」发送'**
  String get tapAtTheBottomRightTo;

  /// No description provided for @dragAFileOrTextNear.
  ///
  /// In zh, this message translates to:
  /// **'拖起文件或文本靠近悬浮引导条\n点击边缘手柄展开 · 拖动可调整上下或左右停靠'**
  String get dragAFileOrTextNear;

  /// No description provided for @noMatches.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配的内容'**
  String get noMatches;

  /// No description provided for @thisDeviceSuffix.
  ///
  /// In zh, this message translates to:
  /// **'（本机）'**
  String get thisDeviceSuffix;

  /// No description provided for @online.
  ///
  /// In zh, this message translates to:
  /// **'在线'**
  String get online;

  /// No description provided for @offline.
  ///
  /// In zh, this message translates to:
  /// **'离线'**
  String get offline;

  /// No description provided for @thisDeviceSP2pNode.
  ///
  /// In zh, this message translates to:
  /// **'本机 P2P 节点'**
  String get thisDeviceSP2pNode;

  /// No description provided for @irohQuicNodeRunningDirectLan.
  ///
  /// In zh, this message translates to:
  /// **'iroh QUIC 节点运行中：局域网与公网直连优先，必要时经加密中继。'**
  String get irohQuicNodeRunningDirectLan;

  /// No description provided for @theP2pEngineIsnTLoaded.
  ///
  /// In zh, this message translates to:
  /// **'P2P 引擎未加载，传输只能经过服务器和云盘。'**
  String get theP2pEngineIsnTLoaded;

  /// No description provided for @nodeStatus.
  ///
  /// In zh, this message translates to:
  /// **'节点状态'**
  String get nodeStatus;

  /// No description provided for @running.
  ///
  /// In zh, this message translates to:
  /// **'运行中'**
  String get running;

  /// No description provided for @notLoaded.
  ///
  /// In zh, this message translates to:
  /// **'未加载'**
  String get notLoaded;

  /// No description provided for @nodeIdCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制 Node ID'**
  String get nodeIdCopied;

  /// No description provided for @devicesOnThisAccount.
  ///
  /// In zh, this message translates to:
  /// **'同账号设备'**
  String get devicesOnThisAccount;

  /// No description provided for @sameNameOffline.
  ///
  /// In zh, this message translates to:
  /// **'同名离线设备（{sameNameOfflineLength}）'**
  String sameNameOffline(Object sameNameOfflineLength);

  /// No description provided for @oldRecordsLeftWhenTheSame.
  ///
  /// In zh, this message translates to:
  /// **'同一台设备重装或重新登录后留下的旧记录。'**
  String get oldRecordsLeftWhenTheSame;

  /// No description provided for @signedInDevicesP2pNodes.
  ///
  /// In zh, this message translates to:
  /// **'已登录设备与 P2P 节点'**
  String get signedInDevicesP2pNodes;

  /// No description provided for @irohQuicP2pNodeRunningOn.
  ///
  /// In zh, this message translates to:
  /// **'本机 iroh QUIC P2P 节点运行中'**
  String get irohQuicP2pNodeRunningOn;

  /// No description provided for @p2pEngineNotLoaded.
  ///
  /// In zh, this message translates to:
  /// **'P2P 引擎未加载'**
  String get p2pEngineNotLoaded;

  /// No description provided for @thisDeviceSuffixShort.
  ///
  /// In zh, this message translates to:
  /// **' (本机)'**
  String get thisDeviceSuffixShort;

  /// No description provided for @irohP2pReadyDirectLanAnd.
  ///
  /// In zh, this message translates to:
  /// **'iroh P2P 就绪 · 局域网与公网直连优先'**
  String get irohP2pReadyDirectLanAnd;

  /// No description provided for @runningInCloudRelayMode.
  ///
  /// In zh, this message translates to:
  /// **'当前运行在云端中转模式'**
  String get runningInCloudRelayMode;

  /// No description provided for @addingToTheDrawer.
  ///
  /// In zh, this message translates to:
  /// **'正在加入抽屉…'**
  String get addingToTheDrawer;

  /// No description provided for @justNow.
  ///
  /// In zh, this message translates to:
  /// **'刚刚'**
  String get justNow;

  /// No description provided for @minutesAgo.
  ///
  /// In zh, this message translates to:
  /// **'{diffInMinutes} 分钟前'**
  String minutesAgo(int diffInMinutes);

  /// No description provided for @hoursAgo.
  ///
  /// In zh, this message translates to:
  /// **'{diffInHours} 小时前'**
  String hoursAgo(int diffInHours);

  /// No description provided for @yesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天'**
  String get yesterday;

  /// No description provided for @p2pDirectPlus.
  ///
  /// In zh, this message translates to:
  /// **'P2P 直连 + {value}'**
  String p2pDirectPlus(Object value);

  /// No description provided for @general.
  ///
  /// In zh, this message translates to:
  /// **'通用'**
  String get general;

  /// No description provided for @language.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get languageSystem;

  /// No description provided for @languageFooter.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统时，系统语言为中文则显示中文，其他语言显示英文。'**
  String get languageFooter;

  /// No description provided for @nativeTrayToggle.
  ///
  /// In zh, this message translates to:
  /// **'展开 / 收起'**
  String get nativeTrayToggle;

  /// No description provided for @nativeRegularWindow.
  ///
  /// In zh, this message translates to:
  /// **'常规窗口'**
  String get nativeRegularWindow;

  /// No description provided for @nativeEdgeDrawer.
  ///
  /// In zh, this message translates to:
  /// **'边缘抽屉'**
  String get nativeEdgeDrawer;

  /// No description provided for @nativeQuitActiveTitle.
  ///
  /// In zh, this message translates to:
  /// **'还有 {count} 项传输正在进行'**
  String nativeQuitActiveTitle(Object count);

  /// No description provided for @nativeQuitActiveMessage.
  ///
  /// In zh, this message translates to:
  /// **'退出软件会中断当前传输，下次打开软件时未完成的云盘上传会自动续传。是否仍要退出？'**
  String get nativeQuitActiveMessage;

  /// No description provided for @nativePickFilesTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择要放入抽屉的文件或文件夹'**
  String get nativePickFilesTitle;

  /// No description provided for @nativePickFilesPrompt.
  ///
  /// In zh, this message translates to:
  /// **'放入抽屉'**
  String get nativePickFilesPrompt;

  /// No description provided for @nativePickFolderTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择默认下载保存目录'**
  String get nativePickFolderTitle;

  /// No description provided for @nativePickFolderPrompt.
  ///
  /// In zh, this message translates to:
  /// **'选择此目录'**
  String get nativePickFolderPrompt;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
