// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get serverAnnouncement => 'Server announcement';

  @override
  String get dismissAnnouncement => 'Dismiss announcement';

  @override
  String get cancel => 'Cancel';

  @override
  String get waitingForStorageConfirmation =>
      'Waiting for storage confirmation…';

  @override
  String get sendingFile => 'Sending file';

  @override
  String get transferCanceled => 'Transfer canceled';

  @override
  String get googleSignInRequiresAnHttps =>
      'Google sign-in requires an HTTPS server address.';

  @override
  String get googleSignInIsNotEnabled =>
      'Google sign-in is not enabled on this server.';

  @override
  String get theServerReturnedAnInvalidGoogle =>
      'The server returned an invalid Google authorization URL.';

  @override
  String get back => 'Back';

  @override
  String get closeMenu => 'Close menu';

  @override
  String get remove => 'Remove';

  @override
  String get settings => 'Settings';

  @override
  String downloadingUpdateProgress(Object version, Object value) {
    return 'Downloading $version · $value%';
  }

  @override
  String installingDropdrawerWillRestartAutomatically(Object version) {
    return 'Installing $version. DropDrawer will restart automatically';
  }

  @override
  String get openingTheSystemInstaller => 'Opening the system installer';

  @override
  String get updateFailed => 'Update failed';

  @override
  String versionIsAvailable(Object version) {
    return 'Version $version is available';
  }

  @override
  String get openInstaller => 'Open installer';

  @override
  String get retry => 'Retry';

  @override
  String get update => 'Update';

  @override
  String get later => 'Later';

  @override
  String get couldnTCheckForUpdatesTry =>
      'Couldn\'t check for updates. Try again later.';

  @override
  String get couldnTSaveTheInstallerCheck =>
      'Couldn\'t save the installer. Check your free disk space and try again.';

  @override
  String get couldnTStartTheInstallerTry =>
      'Couldn\'t start the installer. Try again later.';

  @override
  String get confirmTheUpdateInTheSystem =>
      'Confirm the update in the system installer.';

  @override
  String get theUpdateDidnTFinishYou =>
      'The update didn\'t finish. You can try again.';

  @override
  String get ifTheInstallationDidnTFinish =>
      'If the installation didn\'t finish, click Update again.';

  @override
  String get allowDropdrawerToInstallAppsThen =>
      'Allow DropDrawer to install apps, then come back and tap Update again.';

  @override
  String get theNewVersionIsSignedDifferently =>
      'The new version is signed differently from this app, so it can\'t replace it automatically. You can open the installer and install it manually.';

  @override
  String get theNewVersionUsesTheRelease =>
      'The new version uses the release signature, which differs from the test build you have installed. Uninstall DropDrawer first, then install the new version. Your drawer items are stored on the server and won\'t be lost.';

  @override
  String get dropdrawerDoesnTHavePermissionTo =>
      'DropDrawer doesn\'t have permission to replace itself. You can open the installer and install it manually.';

  @override
  String get thisInstallerSBuildNumberIsn =>
      'This installer\'s build number isn\'t newer than the current version. Pick the matching installer from the releases page.';

  @override
  String get couldnTOpenTheInstallerDownload =>
      'Couldn\'t open the installer. Download it from the releases page.';

  @override
  String get canTReachGithubCheckYour =>
      'Can\'t reach GitHub. Check your network connection and try again.';

  @override
  String get githubIsTemporarilyLimitingUpdateChecks =>
      'GitHub is temporarily limiting update checks. Try again later.';

  @override
  String githubRateLimitedUntil(Object value) {
    return 'GitHub is temporarily limiting update checks. Try again after $value.';
  }

  @override
  String get githubCanTProvideVersionInformation =>
      'GitHub can\'t provide version information right now. Try again later.';

  @override
  String get theDownloadedInstallerIsIncompleteOr =>
      'The downloaded installer is incomplete or damaged. Download it again.';

  @override
  String get checkAutomatically => 'Check automatically';

  @override
  String get checkForUpdates => 'Check for updates';

  @override
  String get releases => 'Releases';

  @override
  String get releaseNotes => 'Release notes';

  @override
  String get aboutUpdates => 'About & updates';

  @override
  String get checkForUpdatesAutomatically => 'Check for updates automatically';

  @override
  String updateToMbAndRestart(Object version, Object mb) {
    return 'Update to $version ($mb MB) and restart';
  }

  @override
  String updateToMb(Object version, Object mb) {
    return 'Update to $version ($mb MB)';
  }

  @override
  String get readingVersion => 'Reading version…';

  @override
  String get getNewVersionsForThisPlatform =>
      'Get new versions for this platform from the releases page.';

  @override
  String get developmentBuildNoReleaseTagAt =>
      'Development build (no release tag at build time). Updates aren\'t checked.';

  @override
  String get checksForANewVersionOnce => 'Checks for a new version once a day.';

  @override
  String get automaticChecksAreOff => 'Automatic checks are off.';

  @override
  String get checkingForUpdates => 'Checking for updates…';

  @override
  String get aNewVersionWasReleasedBut =>
      'A new version was released, but there\'s no installer for this platform yet.';

  @override
  String get youReUpToDate => 'You\'re up to date.';

  @override
  String versionIsReadyToInstall(Object version) {
    return 'Version $version is ready to install.';
  }

  @override
  String downloadingAndVerifyingProgress(Object value) {
    return 'Downloading and verifying $value%…';
  }

  @override
  String get installingDropdrawerWillRestartAutomatically2 =>
      'Installing. DropDrawer will restart automatically.';

  @override
  String get openingTheSystemInstaller2 => 'Opening the system installer…';

  @override
  String get updateFailedTryAgain => 'Update failed. Try again.';

  @override
  String get enterAValidEmailAddressFirst =>
      'Enter a valid email address first';

  @override
  String get verificationCodeSentCheckYourEmail =>
      'Verification code sent. Check your email (valid for 10 minutes)';

  @override
  String get passwordResetSignInWithYour =>
      'Password reset. Sign in with your new password';

  @override
  String get thisServerRequiresAnInvitationCode =>
      'This server requires an invitation code. Enter it before signing up with Google';

  @override
  String get enterAValidServerAddressFirst =>
      'Enter a valid server address first.';

  @override
  String get continueLabel => 'Continue';

  @override
  String get createAccountAndConnect => 'Create account and connect';

  @override
  String get resetPassword => 'Reset password';

  @override
  String get resetYourPasswordWithAnEmail =>
      'Reset your password with an email code';

  @override
  String get aDrawerForFilesAcrossYour =>
      'A drawer for files across your devices';

  @override
  String get server => 'Server';

  @override
  String get account => 'Account';

  @override
  String get usernameOrVerifiedEmail => 'Username or verified email';

  @override
  String get enterYourUsername => 'Enter your username';

  @override
  String get email => 'Email';

  @override
  String get verificationCode => 'Verification code';

  @override
  String get n6Digits => '6 digits';

  @override
  String get sending => 'Sending…';

  @override
  String get sendCode => 'Send code';

  @override
  String get invitationCode => 'Invitation code';

  @override
  String get enterTheInvitationCodeFromYour =>
      'Enter the invitation code from your administrator';

  @override
  String get newPassword => 'New password';

  @override
  String get password => 'Password';

  @override
  String get atLeast6Characters => 'At least 6 characters';

  @override
  String get finishGoogleAuthorizationInYourBrowser =>
      'Finish Google authorization in your browser, then return to DropDrawer.';

  @override
  String get stopWaiting => 'Stop waiting';

  @override
  String get signUpWithGoogle => 'Sign up with Google';

  @override
  String get signInWithGoogle => 'Sign in with Google';

  @override
  String get forgotPassword => 'Forgot password?';

  @override
  String get privacy => 'Privacy';

  @override
  String get noAccountCreateOne => 'No account? Create one';

  @override
  String get haveAnAccountSignIn => 'Have an account? Sign in';

  @override
  String fromDevice(Object cleanDeviceName) {
    return 'From $cleanDeviceName';
  }

  @override
  String get sourceOffline => 'Source offline';

  @override
  String get p2pCloud => 'P2P · Cloud';

  @override
  String get p2pDirect => 'P2P direct';

  @override
  String get savedToCloud => 'Saved to cloud';

  @override
  String get createShareLink => 'Create share link';

  @override
  String get copyText => 'Copy text';

  @override
  String get copiedToClipboard => 'Copied to clipboard';

  @override
  String get saveToCloudAvailableOffline => 'Save to cloud (available offline)';

  @override
  String get copyFilePasteIntoFileExplorer =>
      'Copy file (paste into File Explorer with Ctrl+V)';

  @override
  String get copyFilePasteIntoFinderOr =>
      'Copy file (paste into Finder or other apps with ⌘V)';

  @override
  String fileCopiedPasteItWith(Object pasteShortcutLabel) {
    return 'File copied. Paste it with $pasteShortcutLabel';
  }

  @override
  String get couldnTCopyTheFile => 'Couldn\'t copy the file';

  @override
  String get showInFileExplorerOrDrag =>
      'Show in File Explorer (or drag the card out)';

  @override
  String get showInFinderOrDragThe => 'Show in Finder (or drag the card out)';

  @override
  String get shareOpenInAnotherApp => 'Share / open in another app';

  @override
  String get couldnTOpenTheShareSheet => 'Couldn\'t open the share sheet';

  @override
  String get downloadP2pFirst => 'Download (P2P first)';

  @override
  String get downloadFromCloud => 'Download from cloud';

  @override
  String get removeFromDrawer => 'Remove from drawer';

  @override
  String removeFailedError(Object e) {
    return 'Couldn\'t remove: $e';
  }

  @override
  String get preparingDownload => 'Preparing download';

  @override
  String get connectingOverP2p => 'Connecting over P2P';

  @override
  String get p2pLanCopy => 'P2P LAN copy';

  @override
  String get p2pDirectConnection => 'P2P direct connection';

  @override
  String get p2pEncryptedRelay => 'P2P encrypted relay';

  @override
  String get cloudDownload => 'Cloud download';

  @override
  String get canceling => 'Canceling';

  @override
  String get cancelUpload => 'Cancel upload';

  @override
  String get cancelDownload => 'Cancel download';

  @override
  String sendingToProgress(Object value, Object value2) {
    return 'Sending to $value · $value2%';
  }

  @override
  String get cancelSending => 'Cancel sending';

  @override
  String transferFailedError(Object error) {
    return 'Transfer failed: $error';
  }

  @override
  String fromDeviceName(Object device) {
    return 'From $device';
  }

  @override
  String get yourSessionHasExpiredAnAdministrator =>
      'Your session has expired (an administrator may have signed you out or disabled the account). Sign in again';

  @override
  String get defaultCloudStorage => 'Default cloud storage';

  @override
  String get thisVersionIsTooOldUpdate =>
      'This version is too old. Update DropDrawer to continue';

  @override
  String get yourSessionHasExpiredSignIn =>
      'Your session has expired. Sign in again';

  @override
  String get canTReachTheServerRight =>
      'Can\'t reach the server right now. Pull down to refresh and try again';

  @override
  String get couldnTOpenTheBrowser => 'Couldn\'t open the browser.';

  @override
  String get googleSignInTimedOutTry => 'Google sign-in timed out. Try again.';

  @override
  String get sharedContentReceivedItWillSync =>
      'Shared content received. It will sync to your drawer after you sign in';

  @override
  String get sent => 'Sent';

  @override
  String get sendingCanceled => 'Sending canceled';

  @override
  String p2pSendFailed(Object err) {
    return 'P2P send failed: $err';
  }

  @override
  String get downloadCanceled => 'Download canceled';

  @override
  String get lanCopy => 'LAN copy';

  @override
  String packingFolder(Object folderName) {
    return 'Packing folder “$folderName”…';
  }

  @override
  String packingFolderFailed(Object folderName, Object e) {
    return 'Couldn\'t pack folder “$folderName”: $e';
  }

  @override
  String get cloudUploadsAreTurnedOffOn =>
      'Cloud uploads are turned off on this server. Files will only be sent device-to-device over P2P';

  @override
  String p2pRegisterNotice(Object e) {
    return 'P2P registration notice: $e';
  }

  @override
  String addedP2pOnly(Object name) {
    return 'Added “$name” (P2P only, end-to-end)';
  }

  @override
  String addItemFailed(Object name, Object e) {
    return 'Couldn\'t add “$name”: $e';
  }

  @override
  String get textSyncedToAllDevices => 'Text synced to all devices';

  @override
  String get cancelingSend => 'Canceling send';

  @override
  String cancelSendFailed(Object e) {
    return 'Couldn\'t cancel sending: $e';
  }

  @override
  String get file => 'File';

  @override
  String uploadingFilesToCloud(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Uploading $count files to the cloud',
      one: 'Uploading 1 file to the cloud',
    );
    return '$_temp0';
  }

  @override
  String get uploadingToTheCloud => 'Uploading to the cloud';

  @override
  String transferringFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Transferring $count files',
      one: 'Transferring 1 file',
    );
    return '$_temp0';
  }

  @override
  String get transferringFile => 'Transferring file';

  @override
  String itemAwaitingCloudConfirmation(Object itemName) {
    return '$itemName · waiting for cloud confirmation…';
  }

  @override
  String get cloudUploadsAreTurnedOffOn2 =>
      'Cloud uploads are turned off on this server. Send files device-to-device over P2P';

  @override
  String savedToBackend(Object defaultStorageBackendName) {
    return 'Saved to “$defaultStorageBackendName”';
  }

  @override
  String get uploadCanceled => 'Upload canceled';

  @override
  String cloudUploadFailed(Object e) {
    return 'Cloud upload failed: $e';
  }

  @override
  String get cancelingDownload => 'Canceling download';

  @override
  String cancelDownloadFailed(Object e) {
    return 'Couldn\'t cancel the download: $e';
  }

  @override
  String get theSourceDeviceIsOfflineAnd =>
      'The source device is offline and the file hasn\'t been saved to the cloud';

  @override
  String downloadFailedError(Object e) {
    return 'Download failed: $e';
  }

  @override
  String downloadedFromBackend(Object backendName) {
    return 'Downloaded from “$backendName”';
  }

  @override
  String cloudDownloadFailed(Object e) {
    return 'Cloud download failed: $e';
  }

  @override
  String get nothingToDownloadTextItemsAnd =>
      'Nothing to download (text items and offline files not in the cloud were skipped)';

  @override
  String downloadingFilesBatch(int filesLength) {
    String _temp0 = intl.Intl.pluralLogic(
      filesLength,
      locale: localeName,
      other: 'Downloading $filesLength files…',
      one: 'Downloading 1 file…',
    );
    return '$_temp0';
  }

  @override
  String downloadsStartedTo(int okCount, Object dir) {
    String _temp0 = intl.Intl.pluralLogic(
      okCount,
      locale: localeName,
      other: 'Started or finished $okCount downloads → $dir',
      one: 'Started or finished 1 download → $dir',
    );
    return '$_temp0';
  }

  @override
  String get theSelectedItemsAreAlreadyIn =>
      'The selected items are already in the cloud or not on this device';

  @override
  String uploadingFilesBatchTo(
    int eligibleLength,
    Object defaultStorageBackendName,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      eligibleLength,
      locale: localeName,
      other: 'Uploading $eligibleLength files to “$defaultStorageBackendName”…',
      one: 'Uploading 1 file to “$defaultStorageBackendName”…',
    );
    return '$_temp0';
  }

  @override
  String savedFilesToCloud(int eligibleLength) {
    String _temp0 = intl.Intl.pluralLogic(
      eligibleLength,
      locale: localeName,
      other: 'Saved $eligibleLength files to the cloud',
      one: 'Saved 1 file to the cloud',
    );
    return '$_temp0';
  }

  @override
  String clearedWithFailures(Object deleted, Object failed) {
    return 'Cleared $deleted. $failed couldn\'t be deleted and were kept. Try again.';
  }

  @override
  String drawerCleared(int deleted) {
    String _temp0 = intl.Intl.pluralLogic(
      deleted,
      locale: localeName,
      other: 'Drawer cleared ($deleted items removed)',
      one: 'Drawer cleared (1 item removed)',
    );
    return '$_temp0';
  }

  @override
  String removedItems(int deleted) {
    String _temp0 = intl.Intl.pluralLogic(
      deleted,
      locale: localeName,
      other: 'Removed $deleted items',
      one: 'Removed 1 item',
    );
    return '$_temp0';
  }

  @override
  String get couldnTConfirmTheCleanupTry =>
      'Couldn\'t confirm the cleanup. Try again later.';

  @override
  String get newFilesP2pOnlyNothingIs =>
      'New files: P2P only (nothing is uploaded to the server or cloud)';

  @override
  String policyAlwaysUpload(Object defaultStorageBackendName) {
    return 'New files: always upload to “$defaultStorageBackendName”';
  }

  @override
  String policySmart(Object mb) {
    return 'New files: smart (under $mb MB go to the cloud, larger files P2P only)';
  }

  @override
  String get downloadFolderResetToTheDefault =>
      'Download folder reset to the default';

  @override
  String downloadFolderChanged(Object customDownloadDir) {
    return 'Download folder changed to $customDownloadDir';
  }

  @override
  String get notConnectedToTheServer => 'Not connected to the server';

  @override
  String get shareLinksAreTurnedOffOn =>
      'Share links are turned off on this server';

  @override
  String get selectAtLeastOneItem => 'Select at least one item';

  @override
  String fileOnlyOnSourceDevice(Object itemName) {
    return '“$itemName” is only on its source device and isn\'t in the cloud yet. On that device, tap “Save to cloud” first, then share it';
  }

  @override
  String savingBeforeSharing(Object itemName) {
    return 'Saving “$itemName” to the cloud before sharing…';
  }

  @override
  String autoUploadFailed(Object itemName, Object error) {
    return 'Couldn\'t upload “$itemName”: $error';
  }

  @override
  String shareLinkCreated(Object value) {
    return 'Share link created: $value';
  }

  @override
  String get shareLinkRevoked => 'Share link revoked';

  @override
  String get notConnectedToServer => 'Not connected to the server';

  @override
  String get textPreview => 'Text preview';

  @override
  String get imagePreview => 'Image preview';

  @override
  String get fileDetails => 'File details';

  @override
  String get backToDrawer => 'Back to drawer';

  @override
  String get fileName => 'File name';

  @override
  String get size => 'Size';

  @override
  String get sourceDevice => 'Source device';

  @override
  String get added => 'Added';

  @override
  String get transferMethod => 'Transfer method';

  @override
  String get cloudCache => 'Cloud cache';

  @override
  String get p2pDirectOnly => 'P2P direct only';

  @override
  String get expires => 'Expires';

  @override
  String get neverExpires => 'Never expires';

  @override
  String get localCopy => 'Local copy';

  @override
  String get savedOnThisDevice => 'Saved on this device';

  @override
  String get locationOnThisDevice => 'Location on this device';

  @override
  String get info => 'Info';

  @override
  String get transfer => 'Transfer';

  @override
  String get cloudDownloadShort => 'Cloud download';

  @override
  String sendingToDevice(Object value) {
    return 'Sending to $value';
  }

  @override
  String get downloadItToViewTheOriginal =>
      'Download it to view the original image';

  @override
  String get downloadItToViewTheFull =>
      'Download it to view the full-resolution image';

  @override
  String get transferStatus => 'Transfer status';

  @override
  String get p2pEndToEndOnly => 'P2P end-to-end only';

  @override
  String get localPath => 'Local path';

  @override
  String get copyAllText => 'Copy all text';

  @override
  String get copiedAllText => 'Copied all text';

  @override
  String get quickLook => 'Quick Look';

  @override
  String get open => 'Open';

  @override
  String get noAppCanOpenThisFile => 'No app can open this file';

  @override
  String get share => 'Share…';

  @override
  String get saveToPhotos => 'Save to Photos';

  @override
  String get savedToPhotos => 'Saved to Photos';

  @override
  String get couldnTSaveToPhotosCheck =>
      'Couldn\'t save to Photos (check photo library access)';

  @override
  String get saveToCloudDownloadableWhileThe =>
      'Save to cloud (downloadable while the source is offline)';

  @override
  String get link => 'Link';

  @override
  String get copyFile => 'Copy file';

  @override
  String get showInFileExplorer => 'Show in File Explorer';

  @override
  String get showInFinder => 'Show in Finder';

  @override
  String get share2 => 'Share';

  @override
  String get saveToCloudShort => 'Save to cloud';

  @override
  String get shareLink => 'Share link';

  @override
  String get pressACombinationThatIncludesCtrl =>
      'Press a combination that includes Ctrl, Alt or Win, or use F1–F24. Press Esc to cancel.';

  @override
  String get pressAKeyCombinationItMust =>
      'Press a key combination (it must include ⌘, ⌥ or ⌃, or use F1–F12; Esc cancels)';

  @override
  String hotkeyActive(Object label) {
    return 'Active: $label';
  }

  @override
  String hotkeyTakenChooseAnother(Object label) {
    return '$label may already be used by the system. Choose another combination';
  }

  @override
  String hotkeyUpdatedTo(Object label) {
    return 'Global shortcut changed to $label';
  }

  @override
  String hotkeyTakenTryAnother(Object label) {
    return '$label may already be used by the system. Try another combination';
  }

  @override
  String hotkeySetTo(Object label) {
    return 'Global shortcut set to $label';
  }

  @override
  String get smart => 'Smart';

  @override
  String get p2pOnly => 'P2P only';

  @override
  String get serverDefault => 'Server default';

  @override
  String get n24Hours => '24 hours';

  @override
  String get n7Days => '7 days';

  @override
  String get n30Days => '30 days';

  @override
  String daysCount(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String hoursCount(int cap) {
    String _temp0 = intl.Intl.pluralLogic(
      cap,
      locale: localeName,
      other: '$cap hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String get preferences => 'Preferences';

  @override
  String get smartSendsSmallFilesToThe =>
      'Smart sends small files to the cloud as well and large files over P2P. P2P only never goes through the server. Saving to the cloud lets you download while the source is offline.';

  @override
  String get transferPolicyForNewFiles => 'Transfer policy for new files';

  @override
  String get transferPolicy => 'Transfer policy';

  @override
  String get smartModeCloudThreshold => 'Smart mode cloud threshold';

  @override
  String get cloudThreshold => 'Cloud threshold';

  @override
  String get inSmartModeFilesSmallerThan =>
      'In smart mode, files smaller than this are also cached in the cloud. Larger files only go over P2P.';

  @override
  String get autoCleanup => 'Auto cleanup';

  @override
  String get expiredItemsAreRemovedFromThe =>
      'Expired items are removed from the cloud cache and the list.';

  @override
  String get defaultExpiration => 'Default expiration';

  @override
  String get expiration => 'Expiration';

  @override
  String get downloads => 'Downloads';

  @override
  String get saveLocation => 'Save location';

  @override
  String get filesDropdrawer => 'Files › DropDrawer';

  @override
  String get loading => 'Loading…';

  @override
  String get restoreDefaultLocation => 'Restore default location';

  @override
  String get transfersAutoCleanup => 'Transfers & auto cleanup';

  @override
  String get smartSmallFilesAlsoGoTo =>
      'Smart: small files also go to the cloud, large files P2P only. P2P only: never goes through the server. Always cloud: downloadable while the source is offline';

  @override
  String get defaultExpirationCleanup => 'Default expiration & cleanup';

  @override
  String get newFilesAndTextAreRemoved =>
      'New files and text are removed from the cloud cache and the drawer when they expire';

  @override
  String get smartModeAutoUploadThreshold => 'Smart mode auto-upload threshold';

  @override
  String get filesSmallerThanThisAreCached =>
      'Files smaller than this are cached in the cloud; larger ones go end-to-end over P2P only';

  @override
  String get defaultDownloadFolder => 'Default download folder';

  @override
  String get restoreDefault => 'Restore default';

  @override
  String get loadingDots => 'Loading…';

  @override
  String get changeFolder => 'Change folder';

  @override
  String get windowWindowsIntegration => 'Window & Windows integration';

  @override
  String get windowMacosIntegration => 'Window & macOS integration';

  @override
  String get drawerEdge => 'Drawer edge';

  @override
  String get youCanAlsoDragTheEdge =>
      'You can also drag the edge handle up or down, or onto another screen';

  @override
  String get leftSideOfTheScreen => 'Left side of the screen';

  @override
  String get rightSideOfTheScreen => 'Right side of the screen';

  @override
  String get globalShortcutToOpenTheDrawer =>
      'Global shortcut to open the drawer';

  @override
  String get opensOrClosesTheDrawerFrom =>
      'Opens or closes the drawer from any app. Customize it to avoid conflicts';

  @override
  String get currentShortcut => 'Current shortcut';

  @override
  String get pressAKeyCombination => 'Press a key combination…';

  @override
  String get clickToChange => 'Click to change';

  @override
  String hotkeyReady(Object hotkeyLabel) {
    return 'Global shortcut ready · press $hotkeyLabel in any app';
  }

  @override
  String get theGlobalShortcutMayAlreadyBe =>
      'The global shortcut may already be in use. Choose another combination';

  @override
  String get dropdrawerNeedsMacosAccessibilityPermissionTo =>
      'DropDrawer needs macOS Accessibility permission to respond to the global shortcut in other apps';

  @override
  String get openAccessibilitySettings => 'Open Accessibility settings';

  @override
  String get permissionGrantedTheGlobalShortcutWorks =>
      'Permission granted. The global shortcut works now';

  @override
  String get permissionNotDetectedYetEnableDropdrawer =>
      'Permission not detected yet. Enable dropdrawer_app in System Settings';

  @override
  String get checkAgain => 'Check again';

  @override
  String get showTheDrawerInTheTaskbar => 'Show the drawer in the taskbar';

  @override
  String get showIconInTheDock => 'Show icon in the Dock';

  @override
  String get whenOffOpenTheDrawerFrom =>
      'When off, open the drawer from the system tray';

  @override
  String get whenOffDropdrawerStaysInThe =>
      'When off, DropDrawer stays in the menu bar only. When on, it also appears in the Dock';

  @override
  String get translucentBackground => 'Translucent background';

  @override
  String get notSupportedOnThisSystemRequires =>
      'Not supported on this system (requires Windows 11 22H2 or later). Using an opaque background';

  @override
  String get usesTheWindows11MicaAcrylic =>
      'Uses the Windows 11 Mica / Acrylic effect. Turn it off if the background looks wrong';

  @override
  String get launchAtLogin => 'Launch at login';

  @override
  String get staysInTheSystemTrayWhen =>
      'Stays in the system tray when you sign in to Windows';

  @override
  String get runsQuietlyInTheMenuBar =>
      'Runs quietly in the menu bar and at the screen edge when you log in to macOS';

  @override
  String get launchAtLoginTurnedOn => 'Launch at login turned on';

  @override
  String get launchAtLoginTurnedOff => 'Launch at login turned off';

  @override
  String get couldnTChangeLaunchAtLogin => 'Couldn\'t change launch at login';

  @override
  String shareClipboardText(Object url, Object plainPasscode) {
    return 'Link: $url\\nPasscode: $plainPasscode';
  }

  @override
  String get thisServerRequiresAPasscodeFor =>
      'This server requires a passcode for share links';

  @override
  String get shareLinkCreatedAndCopiedTo =>
      'Share link created and copied to the clipboard';

  @override
  String get manageShareLinks => 'Share links';

  @override
  String createBundleLinkItems(int targetItemsLength) {
    String _temp0 = intl.Intl.pluralLogic(
      targetItemsLength,
      locale: localeName,
      other: 'Create bundle link ($targetItemsLength items)',
      one: 'Create bundle link (1 item)',
    );
    return '$_temp0';
  }

  @override
  String bundleLinkCount(Object targetItemsLength) {
    return 'Bundle link ($targetItemsLength)';
  }

  @override
  String get createShareLink2 => 'Create share link';

  @override
  String get shareLinksTitle => 'Share links';

  @override
  String get refreshShareLinks => 'Refresh share links';

  @override
  String get shareLinksAreTurnedOffOn2 =>
      'Share links are turned off on this server, so new links can\'t be created right now.';

  @override
  String createdLinksCount(Object shareLinksLength) {
    return 'Created links ($shareLinksLength)';
  }

  @override
  String get noShareLinksYetNclickAn =>
      'No share links yet\\nClick an item\'s link icon, or use Select to bundle several items into one link';

  @override
  String get n1Hour => '1 hour';

  @override
  String get forever => 'Forever';

  @override
  String get unlimited => 'Unlimited';

  @override
  String get n1TimeBurnAfterReading => '1 time (burn after reading)';

  @override
  String get n5Times => '5 times';

  @override
  String get n20Times => '20 times';

  @override
  String hoursCountH(int h) {
    String _temp0 = intl.Intl.pluralLogic(
      h,
      locale: localeName,
      other: '$h hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String valueAtCap(Object value) {
    return '$value (max)';
  }

  @override
  String timesAtCap(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n times (max)',
      one: '1 time (max)',
    );
    return '$_temp0';
  }

  @override
  String bundleItemsSize(int itemsLength, Object value) {
    String _temp0 = intl.Intl.pluralLogic(
      itemsLength,
      locale: localeName,
      other: 'Bundle of $itemsLength items · $value',
      one: 'Bundle of 1 item · $value',
    );
    return '$_temp0';
  }

  @override
  String get sharedContent => 'Shared content';

  @override
  String get browserShareNeedsSender =>
      'Files without a cloud copy are sent over the local network. Keep DropDrawer open on the sending device.';

  @override
  String uploadBeforeShareNote(
    int pendingUploadCount,
    Object defaultStorageBackendName,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      pendingUploadCount,
      locale: localeName,
      other:
          '$pendingUploadCount files will be uploaded to “$defaultStorageBackendName” first. Anyone with the link can download them in a browser without signing in.',
      one:
          '1 file will be uploaded to “$defaultStorageBackendName” first. Anyone with the link can download it in a browser without signing in.',
    );
    return '$_temp0';
  }

  @override
  String get anyoneWithTheLinkCanDownload =>
      'Anyone with the link can download in a browser without signing in.';

  @override
  String andMoreItems(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'and $value more items',
      one: 'and 1 more item',
    );
    return '$_temp0';
  }

  @override
  String get bundleTitle => 'Bundle title';

  @override
  String firstNameAndMore(Object firstName, int itemsLength) {
    String _temp0 = intl.Intl.pluralLogic(
      itemsLength,
      locale: localeName,
      other: '$firstName and $itemsLength items',
      one: '$firstName',
    );
    return '$_temp0';
  }

  @override
  String get access => 'Access';

  @override
  String get thisServerRequiresAPasscodeFor2 =>
      'This server requires a passcode for share links.';

  @override
  String get ifYouLeaveThePasscodeEmpty =>
      'If you leave the passcode empty, anyone with the link can download.';

  @override
  String get expiresAfter => 'Expires after';

  @override
  String get downloads2 => 'Downloads';

  @override
  String get passcodeRequired => 'Passcode (required)';

  @override
  String get passcode => 'Passcode';

  @override
  String get leaveEmptyForPublic => 'Leave empty for public';

  @override
  String get generateA4CharacterPasscode => 'Generate a 4-character passcode';

  @override
  String get creating => 'Creating…';

  @override
  String get uploadAndCreateLink => 'Upload and create link';

  @override
  String get createBundleLinkAndCopy => 'Create bundle link and copy';

  @override
  String get createLinkAndCopy => 'Create link and copy';

  @override
  String get createdAndCopiedToTheClipboard =>
      'Created and copied to the clipboard';

  @override
  String get linkLabel => 'Link';

  @override
  String get copyAgain => 'Copy again';

  @override
  String get copiedLinkDetails => 'Copied link details';

  @override
  String get openInBrowser => 'Open in browser';

  @override
  String createdLinksCountFull(Object shareLinksLength) {
    return 'Created links ($shareLinksLength)';
  }

  @override
  String get longPressOrOpenAnyItem =>
      'Long-press or open any item on the home screen to create a link. Select several items to bundle them.';

  @override
  String get tapALinkToCopyOpen => 'Tap a link to copy, open or revoke it.';

  @override
  String get loadingEllipsis => 'Loading…';

  @override
  String get noShareLinksYet => 'No share links yet';

  @override
  String bundleOfItems(int itemCount) {
    String _temp0 = intl.Intl.pluralLogic(
      itemCount,
      locale: localeName,
      other: 'Bundle of $itemCount',
      one: 'Bundle of 1',
    );
    return '$_temp0';
  }

  @override
  String get passcodeRequired2 => 'Passcode required';

  @override
  String downloadedOfMax(Object downloadCount, Object maxDownloads) {
    return '$downloadCount/$maxDownloads downloads';
  }

  @override
  String downloadedCount(int downloadCount) {
    String _temp0 = intl.Intl.pluralLogic(
      downloadCount,
      locale: localeName,
      other: '$downloadCount downloads',
      one: '1 download',
    );
    return '$_temp0';
  }

  @override
  String get expired => 'Expired';

  @override
  String get downloadLimitReached => 'Download limit reached';

  @override
  String get neverExpires2 => 'Never expires';

  @override
  String get copyLink => 'Copy link';

  @override
  String get linkCopied => 'Link copied';

  @override
  String get revokeLink => 'Revoke link';

  @override
  String primaryNameAndMore(Object primaryName, int itemsLength) {
    String _temp0 = intl.Intl.pluralLogic(
      itemsLength,
      locale: localeName,
      other: '$primaryName and $itemsLength items',
      one: '$primaryName',
    );
    return '$_temp0';
  }

  @override
  String sizeUploadBeforeShare(
    Object value,
    int pendingUploadCount,
    Object defaultStorageBackendName,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      pendingUploadCount,
      locale: localeName,
      other:
          '$value · $pendingUploadCount files will be uploaded to “$defaultStorageBackendName” first',
      one:
          '$value · 1 file will be uploaded to “$defaultStorageBackendName” first',
    );
    return '$_temp0';
  }

  @override
  String sizeReadyNoSignIn(Object value) {
    return '$value · Ready. Downloadable in a browser without signing in';
  }

  @override
  String optionalDefaultTitle(Object primaryName, Object itemsLength) {
    return 'Optional. Defaults to “$primaryName and $itemsLength items”';
  }

  @override
  String get downloadLimit => 'Download limit';

  @override
  String get oneTimeBurn => '1 time (burn after reading)';

  @override
  String get leaveEmptyForPublicAccess => 'Leave empty for public access';

  @override
  String get uploadToCloudAndCreateLink => 'Upload to cloud and create link';

  @override
  String get copyLinkAgain => 'Copy link again';

  @override
  String get previewInBrowser => 'Preview in browser';

  @override
  String copyLinkUrl(Object fullUrl) {
    return 'Copy link ($fullUrl)';
  }

  @override
  String linkCopiedUrl(Object fullUrl) {
    return 'Link copied: $fullUrl';
  }

  @override
  String get openInBrowserShort => 'Open in browser';

  @override
  String daysLeft(int diffInDays) {
    String _temp0 = intl.Intl.pluralLogic(
      diffInDays,
      locale: localeName,
      other: '$diffInDays days left',
      one: '1 day left',
    );
    return '$_temp0';
  }

  @override
  String hoursLeft(int diffInHours) {
    String _temp0 = intl.Intl.pluralLogic(
      diffInHours,
      locale: localeName,
      other: '$diffInHours hours left',
      one: '1 hour left',
    );
    return '$_temp0';
  }

  @override
  String minutesLeft(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: '$value minutes left',
      one: '1 minute left',
    );
    return '$_temp0';
  }

  @override
  String get quarkDrive => 'Quark Drive';

  @override
  String get baiduNetdisk => 'Baidu Netdisk';

  @override
  String get webdavStorage => 'WebDAV storage';

  @override
  String get serverLocalStorage => 'Server local storage';

  @override
  String get enterTheGoogleOauthClientId =>
      'Enter the Google OAuth client ID and client secret first';

  @override
  String get googleDriveAuthorizationOpenedInYour =>
      'Google Drive authorization opened in your browser. After you approve, tap “Refresh list” below';

  @override
  String authorizationFailedToStart(Object e) {
    return 'Couldn\'t start authorization: $e';
  }

  @override
  String get enterARefreshTokenOrUse =>
      'Enter a refresh token, or use “Authorize Google in browser” above';

  @override
  String get pasteTheCookieFromPanQuark => 'Paste the Cookie from pan.quark.cn';

  @override
  String get storageSaved => 'Storage saved';

  @override
  String saveFailedColon(Object e) {
    return 'Couldn\'t save: $e';
  }

  @override
  String get cloudStorage => 'Cloud & storage';

  @override
  String get refreshStorageList => 'Refresh storage list';

  @override
  String get cloudStorage2 => 'Cloud & storage';

  @override
  String get editStorage => 'Edit storage';

  @override
  String get configured => 'Configured';

  @override
  String get addStorage => 'Add storage';

  @override
  String get theServerAdministratorHasDisabledEvery =>
      'The server administrator has disabled every storage type you could add, so new storage can\'t be added right now.';

  @override
  String get localDisk => 'Local disk';

  @override
  String get name => 'Name';

  @override
  String get optionalUseOneClickAuthorizationBelow =>
      'Optional. Use one-click authorization below to fill it in';

  @override
  String get folderId => 'Folder ID';

  @override
  String get rootOrAFolderId => 'root (or a folder ID)';

  @override
  String get fullCookieFromPanQuarkCn => 'Full Cookie from pan.quark.cn';

  @override
  String get folderFid => 'Folder fid';

  @override
  String get n0IsTheRootFolder => '0 is the root folder';

  @override
  String get accessTokenOrFillInRefresh =>
      'Access token (or fill in Refresh below)';

  @override
  String get optionalUsedForAutomaticRefresh =>
      'Optional, used for automatic refresh';

  @override
  String get optionalLongLivedRefreshToken10 =>
      'Optional, long-lived refresh token (10 years)';

  @override
  String get path => 'Path';

  @override
  String get url => 'URL';

  @override
  String get username => 'Username';

  @override
  String get filesAreSavedInThisAccount =>
      'Files are saved in this account\'s folder inside the server data directory (set by DROPDRAWER_LOCAL_STORAGE on the server).';

  @override
  String get newCloudUploadsUseTheDefault =>
      'New cloud uploads use the default storage.';

  @override
  String connectionOk(Object msg) {
    return 'Connection OK: $msg';
  }

  @override
  String connectionFailed(Object msg) {
    return 'Connection failed: $msg';
  }

  @override
  String get defaultStorageUpdated => 'Default storage updated';

  @override
  String switchDefaultStorageFailed(Object e) {
    return 'Couldn\'t change the default storage: $e';
  }

  @override
  String get configuredShort => 'Configured';

  @override
  String get addStorageShort => 'Add storage';

  @override
  String get noStorageYetSwitchToAdd =>
      'No storage yet. Switch to “Add storage” to set one up.';

  @override
  String tapToEditNote(Object defaultNote) {
    return 'Tap a storage item to edit it. $defaultNote';
  }

  @override
  String get noStorage => 'No storage';

  @override
  String get defaultLabel => 'Default';

  @override
  String get setAsDefault => 'Set as default';

  @override
  String get edit => 'Edit';

  @override
  String get testConnection => 'Test connection';

  @override
  String get delete => 'Delete';

  @override
  String get typeLabel => 'Type';

  @override
  String get storageType => 'Storage type';

  @override
  String get storageBack => 'Storage';

  @override
  String get connection => 'Connection';

  @override
  String callbackUrlHint(Object serverUrl) {
    return 'Set the redirect URI to: $serverUrl/api/oauth/google/callback';
  }

  @override
  String get useAsDefaultTransferStorage => 'Use as default transfer storage';

  @override
  String get authorizeGoogleDriveInBrowser =>
      'Authorize Google Drive in browser';

  @override
  String get iAlreadyHaveARefreshToken =>
      'I already have a refresh token, save it';

  @override
  String get saving => 'Saving…';

  @override
  String get save => 'Save';

  @override
  String get noStorageYetUseAddStorage =>
      'No storage yet. Use “Add storage” above to set one up';

  @override
  String cantReadStorage(Object e) {
    return 'Couldn\'t read the storage settings: $e';
  }

  @override
  String get storageNameCanTBeEmpty => 'Storage name can\'t be empty';

  @override
  String get theCapacityLimitMustBeA =>
      'The capacity limit must be a positive whole number';

  @override
  String get storageSettingsSaved => 'Storage settings saved';

  @override
  String saveFailedFull(Object e) {
    return 'Couldn\'t save: $e';
  }

  @override
  String get leaveTheCapacityLimitEmptyFor =>
      'Leave the capacity limit empty for no limit.';

  @override
  String get leaveFieldsEmptyToKeepThe =>
      'Leave fields empty to keep the current credentials. To move to a different storage location, use “Add storage”.';

  @override
  String get limitBytes => 'Limit (bytes)';

  @override
  String get saveChanges => 'Save changes';

  @override
  String get storageLocation => 'Storage location';

  @override
  String get authorizeGoogleDriveInBrowserOne =>
      'Authorize Google Drive in browser (one click)';

  @override
  String get alreadyHaveARefreshTokenSave =>
      'Already have a refresh token? Save it';

  @override
  String get saveStorage => 'Save storage';

  @override
  String get localDiskFull => 'Local disk';

  @override
  String get p2pEndToEndOnThis =>
      'P2P end-to-end on this device only · uses no server or cloud storage';

  @override
  String policyAlwaysUploadShort(Object defaultStorageBackendName) {
    return 'Upload straight to “$defaultStorageBackendName” · downloadable offline';
  }

  @override
  String policySmartShort(Object value) {
    return 'Under $value MB go to the cloud · larger files P2P only';
  }

  @override
  String get dockedToTheLeftSideOf => 'Docked to the left side of the screen';

  @override
  String get dockedToTheRightSideOf => 'Docked to the right side of the screen';

  @override
  String transfersInProgress(int active) {
    String _temp0 = intl.Intl.pluralLogic(
      active,
      locale: localeName,
      other: '$active transfers are still in progress',
      one: '1 transfer is still in progress',
    );
    return '$_temp0';
  }

  @override
  String get quittingInterruptsTheCurrentTransfersUnfinished =>
      'Quitting interrupts the current transfers (unfinished cloud uploads resume the next time you open the app). Quit anyway?';

  @override
  String get quitAnyway => 'Quit anyway';

  @override
  String get keepRunningInBackground => 'Keep running in background';

  @override
  String get clearAll => 'Clear all';

  @override
  String clearAllMessage(int itemsLength) {
    String _temp0 = intl.Intl.pluralLogic(
      itemsLength,
      locale: localeName,
      other:
          'This removes $itemsLength items from the list along with their copies on the server or cloud storage. Original files on this device are kept.',
      one:
          'This removes 1 item from the list along with its copy on the server or cloud storage. Original files on this device are kept.',
    );
    return '$_temp0';
  }

  @override
  String get clear => 'Clear';

  @override
  String filePickerFailed(Object e) {
    return 'Couldn\'t open the file picker: $e';
  }

  @override
  String photoPickerFailed(Object e) {
    return 'Couldn\'t open the photo library: $e';
  }

  @override
  String get screenshotPastedAndSyncedToThe =>
      'Screenshot pasted and synced to the drawer';

  @override
  String pastedFiles(int pathsLength) {
    String _temp0 = intl.Intl.pluralLogic(
      pathsLength,
      locale: localeName,
      other: 'Pasted $pathsLength files into the drawer',
      one: 'Pasted 1 file into the drawer',
    );
    return '$_temp0';
  }

  @override
  String get foldersCanTBePastedDirectly =>
      'Folders can\'t be pasted directly yet. Compress the folder or choose specific files';

  @override
  String get theClipboardIsEmptyYouCan =>
      'The clipboard is empty (you can paste files, screenshots or text)';

  @override
  String clipboardReadFailed(Object e) {
    return 'Couldn\'t read the clipboard: $e';
  }

  @override
  String get add => 'Add';

  @override
  String get releaseToDropIntoTheDrawer => 'Release to drop into the drawer';

  @override
  String get moveDrawer => 'Move drawer';

  @override
  String get dragHereToDropIntoThe => 'Drag here to drop into the drawer';

  @override
  String get chooseFiles => 'Choose files';

  @override
  String get photoLibrary => 'Photo library';

  @override
  String get paste => 'Paste';

  @override
  String get select => 'Select';

  @override
  String get downloadAll => 'Download all';

  @override
  String get devicesP2p => 'Devices & P2P';

  @override
  String get signOut => 'Sign out';

  @override
  String selectedCount(Object selectedIdsLength) {
    return '$selectedIdsLength selected';
  }

  @override
  String get more => 'More';

  @override
  String get deselectAll => 'Deselect all';

  @override
  String get selectAll => 'Select all';

  @override
  String get done => 'Done';

  @override
  String get searchDropdrawer => 'Search DropDrawer';

  @override
  String get closeSearch => 'Close search';

  @override
  String get clearSearch => 'Clear';

  @override
  String get connecting => 'Connecting…';

  @override
  String devicesOnline(int onlineDeviceCount) {
    String _temp0 = intl.Intl.pluralLogic(
      onlineDeviceCount,
      locale: localeName,
      other: '$onlineDeviceCount devices online',
      one: '1 device online',
    );
    return '$_temp0';
  }

  @override
  String itemsCount(int itemsLength) {
    String _temp0 = intl.Intl.pluralLogic(
      itemsLength,
      locale: localeName,
      other: '$itemsLength items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String get all => 'All';

  @override
  String get text => 'Text';

  @override
  String get search => 'Search';

  @override
  String statusFiltered(
    Object status,
    Object visibleItemsLength,
    Object itemsLength,
  ) {
    return '$status · showing $visibleItemsLength of $itemsLength';
  }

  @override
  String statusItems(Object status, int itemsLength) {
    String _temp0 = intl.Intl.pluralLogic(
      itemsLength,
      locale: localeName,
      other: '$status · $itemsLength items',
      one: '$status · 1 item',
    );
    return '$_temp0';
  }

  @override
  String get saveToCloudAction => 'Save to cloud';

  @override
  String devicesOnlineShort(Object onlineDeviceCount) {
    return '$onlineDeviceCount online';
  }

  @override
  String get pinnedOpenClickToHideAutomatically =>
      'Pinned open (click to hide automatically when you leave)';

  @override
  String get hidesAutomaticallyWhenYouLeaveClick =>
      'Hides automatically when you leave (click to pin open)';

  @override
  String get collapseToEdgeEsc => 'Collapse to edge (Esc)';

  @override
  String get switchToARegularWindow => 'Switch to a regular window';

  @override
  String get switchToTheEdgeDrawer => 'Switch to the edge drawer';

  @override
  String get cloudStorageTransferStorage => 'Cloud & storage';

  @override
  String get deviceStatus => 'Devices & P2P';

  @override
  String get clearDrawer => 'Clear drawer';

  @override
  String get dockRight => 'Dock right';

  @override
  String get dockLeft => 'Dock left';

  @override
  String get quit => 'Quit';

  @override
  String get releaseToDropIntoTheDrawer2 => 'Release to drop into the drawer';

  @override
  String dropPickOrPaste(Object pasteShortcutLabel) {
    return 'Drop, choose or paste with $pasteShortcutLabel';
  }

  @override
  String smartPasteTooltip(Object pasteShortcutLabel) {
    return 'Paste files / screenshots / text ($pasteShortcutLabel)';
  }

  @override
  String smartPolicyShort(Object value) {
    return 'Smart (<$value MB to cloud)';
  }

  @override
  String get policyP2pOnly => 'P2P only';

  @override
  String get alwaysSaveToCloud => 'Always save to cloud';

  @override
  String selectAllCount(Object visibleItemsLength) {
    return 'Select all ($visibleItemsLength)';
  }

  @override
  String filteredResults(Object visibleItemsLength, Object itemsLength) {
    return 'Filtered · $visibleItemsLength/$itemsLength';
  }

  @override
  String drawerItemsCount(int itemsLength) {
    String _temp0 = intl.Intl.pluralLogic(
      itemsLength,
      locale: localeName,
      other: 'Drawer · $itemsLength items',
      one: 'Drawer · 1 item',
    );
    return '$_temp0';
  }

  @override
  String get multiSelect => 'Select';

  @override
  String get confirmClear => 'Confirm clear';

  @override
  String get searchFileNamesOrText => 'Search file names or text…';

  @override
  String removedItem(Object itemName) {
    return 'Removed “$itemName”';
  }

  @override
  String get undo => 'Undo';

  @override
  String get shareAction => 'Share';

  @override
  String get copy => 'Copy';

  @override
  String copiedFiles(int localSelectedPathsLength, Object pasteShortcutLabel) {
    String _temp0 = intl.Intl.pluralLogic(
      localSelectedPathsLength,
      locale: localeName,
      other:
          'Copied $localSelectedPathsLength files. Paste them with $pasteShortcutLabel',
      one: 'Copied 1 file. Paste it with $pasteShortcutLabel',
    );
    return '$_temp0';
  }

  @override
  String deleteCount(Object selectedItemsLength) {
    return 'Delete ($selectedItemsLength)';
  }

  @override
  String get nothingHereYet => 'Nothing here yet';

  @override
  String get theDrawerIsEmpty => 'The drawer is empty';

  @override
  String get tapAddAtTheBottomRight =>
      'Tap “Add” at the bottom right to choose files or photos, or paste\\nYou can also send from other apps with “Share → DropDrawer”';

  @override
  String get tapAtTheBottomRightTo =>
      'Tap “+” at the bottom right to choose files or photos, or paste\\nYou can also send from other apps with “Share → DropDrawer”';

  @override
  String get dragAFileOrTextNear =>
      'Drag a file or text near the floating guide\\nClick the edge handle to open · drag it to move it along or across edges';

  @override
  String get noMatches => 'No matches';

  @override
  String get thisDeviceSuffix => ' (this device)';

  @override
  String get online => 'Online';

  @override
  String get offline => 'Offline';

  @override
  String get thisDeviceSP2pNode => 'This device\'s P2P node';

  @override
  String get irohQuicNodeRunningDirectLan =>
      'iroh QUIC node running: direct LAN and internet connections first, encrypted relay when needed.';

  @override
  String get theP2pEngineIsnTLoaded =>
      'The P2P engine isn\'t loaded, so transfers can only go through the server and cloud storage.';

  @override
  String get nodeStatus => 'Node status';

  @override
  String get running => 'Running';

  @override
  String get notLoaded => 'Not loaded';

  @override
  String get nodeIdCopied => 'Node ID copied';

  @override
  String get devicesOnThisAccount => 'Devices on this account';

  @override
  String sameNameOffline(Object sameNameOfflineLength) {
    return 'Offline devices with the same name ($sameNameOfflineLength)';
  }

  @override
  String get oldRecordsLeftWhenTheSame =>
      'Old records left when the same device was reinstalled or signed in again.';

  @override
  String get signedInDevicesP2pNodes => 'Devices & P2P';

  @override
  String get irohQuicP2pNodeRunningOn =>
      'iroh QUIC P2P node running on this device';

  @override
  String get p2pEngineNotLoaded => 'P2P engine not loaded';

  @override
  String get thisDeviceSuffixShort => ' (this device)';

  @override
  String get irohP2pReadyDirectLanAnd =>
      'iroh P2P ready · direct LAN and internet connections first';

  @override
  String get runningInCloudRelayMode => 'Running in cloud relay mode';

  @override
  String get addingToTheDrawer => 'Adding to the drawer…';

  @override
  String get justNow => 'Just now';

  @override
  String minutesAgo(int diffInMinutes) {
    String _temp0 = intl.Intl.pluralLogic(
      diffInMinutes,
      locale: localeName,
      other: '$diffInMinutes minutes ago',
      one: '1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String hoursAgo(int diffInHours) {
    String _temp0 = intl.Intl.pluralLogic(
      diffInHours,
      locale: localeName,
      other: '$diffInHours hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String get yesterday => 'Yesterday';

  @override
  String p2pDirectPlus(Object value) {
    return 'P2P direct + $value';
  }

  @override
  String get general => 'General';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'System default';

  @override
  String get languageFooter =>
      'With System default, DropDrawer uses Chinese when your system language is Chinese and English otherwise.';

  @override
  String get nativeTrayToggle => 'Show / Hide';

  @override
  String get nativeRegularWindow => 'Regular window';

  @override
  String get nativeEdgeDrawer => 'Edge drawer';

  @override
  String nativeQuitActiveTitle(Object count) {
    return 'Transfers still in progress: $count';
  }

  @override
  String get nativeQuitActiveMessage =>
      'Quitting interrupts the current transfers. Unfinished cloud uploads resume the next time you open DropDrawer. Quit anyway?';

  @override
  String get nativePickFilesTitle =>
      'Choose files or folders to add to the drawer';

  @override
  String get nativePickFilesPrompt => 'Add to Drawer';

  @override
  String get nativePickFolderTitle => 'Choose the default download folder';

  @override
  String get nativePickFolderPrompt => 'Choose Folder';

  @override
  String get accountSecurity => 'Account & Security';

  @override
  String get accountSectionFooter =>
      'Changing your password signs out other devices. Deleting your account permanently removes all cloud files, share links, and devices.';

  @override
  String get currentAccount => 'Account';

  @override
  String get boundEmail => 'Email';

  @override
  String get emailNotBound => 'Not linked';

  @override
  String get emailVerifiedTag => 'Verified';

  @override
  String get googleAccountLinked => 'Google linked';

  @override
  String get changePassword => 'Change Password';

  @override
  String get setPassword => 'Set Password';

  @override
  String get changePasswordSubtitle => 'Signs out other devices after saving';

  @override
  String get setPasswordSubtitle => 'Add a password to your Google account';

  @override
  String get currentPassword => 'Current password';

  @override
  String get confirmNewPassword => 'Confirm new password';

  @override
  String get newPasswordHint => 'At least 6 characters';

  @override
  String get passwordsDoNotMatch => 'New passwords do not match';

  @override
  String get passwordUpdated =>
      'Password updated; other devices were signed out';

  @override
  String get passwordSetSuccess => 'Password set';

  @override
  String get bindEmail => 'Link Email';

  @override
  String get changeEmail => 'Change Email';

  @override
  String get bindEmailSubtitle => 'Used for email sign-in and password reset';

  @override
  String get emailAddressLabel => 'Email address';

  @override
  String get verificationCodeLabel => '6-digit code';

  @override
  String resendCodeCountdown(int seconds) {
    return 'Resend (${seconds}s)';
  }

  @override
  String get verificationCodeSent => 'Verification code sent';

  @override
  String get emailBoundSuccess => 'Email linked';

  @override
  String get deleteAccount => 'Delete Account';

  @override
  String get deleteAccountSubtitle =>
      'Permanently delete your account and all data';

  @override
  String get deleteAccountWarning =>
      'This permanently deletes your account, drawer items, cloud files, share links, and devices. This cannot be undone.';

  @override
  String get enterPasswordToDelete => 'Enter your password to confirm';

  @override
  String enterUsernameToDelete(String username) {
    return 'Type \"$username\" to confirm';
  }

  @override
  String get confirmDeleteAccount => 'Delete Permanently';

  @override
  String get accountDeletedBanner => 'Account permanently deleted';
}
