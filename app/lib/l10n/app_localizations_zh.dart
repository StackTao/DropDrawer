// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get serverAnnouncement => '服务器公告';

  @override
  String get dismissAnnouncement => '关闭公告';

  @override
  String get cancel => '取消';

  @override
  String get waitingForStorageConfirmation => '等待存储确认…';

  @override
  String get sendingFile => '正在发送文件';

  @override
  String get transferCanceled => '传输已取消';

  @override
  String get googleSignInRequiresAnHttps => 'Google 登录需要 HTTPS 服务器地址。';

  @override
  String get googleSignInIsNotEnabled => '此服务器尚未启用 Google 登录。';

  @override
  String get theServerReturnedAnInvalidGoogle => '服务器返回了无效的 Google 授权地址。';

  @override
  String get back => '返回';

  @override
  String get closeMenu => '关闭菜单';

  @override
  String get remove => '移出';

  @override
  String get settings => '设置';

  @override
  String downloadingUpdateProgress(Object version, Object value) {
    return '正在下载 $version · $value%';
  }

  @override
  String installingDropdrawerWillRestartAutomatically(Object version) {
    return '正在安装 $version，DropDrawer 将自动重启';
  }

  @override
  String get openingTheSystemInstaller => '正在打开系统安装界面';

  @override
  String get updateFailed => '更新失败';

  @override
  String versionIsAvailable(Object version) {
    return '新版本 $version 可用';
  }

  @override
  String get openInstaller => '打开安装包';

  @override
  String get retry => '重试';

  @override
  String get update => '更新';

  @override
  String get later => '稍后';

  @override
  String get couldnTCheckForUpdatesTry => '检查更新失败，请稍后重试。';

  @override
  String get couldnTSaveTheInstallerCheck => '无法保存安装包，请检查磁盘空间后重试。';

  @override
  String get couldnTStartTheInstallerTry => '无法启动安装程序，请稍后重试。';

  @override
  String get confirmTheUpdateInTheSystem => '请在系统安装界面中确认更新。';

  @override
  String get theUpdateDidnTFinishYou => '更新没有完成，可以再试一次。';

  @override
  String get ifTheInstallationDidnTFinish => '如果没有完成安装，可以再点一次「更新」。';

  @override
  String get allowDropdrawerToInstallAppsThen =>
      '请允许 DropDrawer 安装应用，返回后再点一次「更新」。';

  @override
  String get theNewVersionIsSignedDifferently =>
      '新版本的签名与当前应用不同，无法自动替换。可以打开安装包手动安装。';

  @override
  String get theNewVersionUsesTheRelease =>
      '新版本使用了正式签名，与当前安装的测试版不同。请先卸载 DropDrawer 再安装新版本；抽屉内容保存在服务端，不会丢失。';

  @override
  String get dropdrawerDoesnTHavePermissionTo =>
      '没有权限替换当前的 DropDrawer，可以打开安装包手动安装。';

  @override
  String get thisInstallerSBuildNumberIsn => '这个安装包的构建号不比当前版本新，请从发布页选择对应的安装包。';

  @override
  String get couldnTOpenTheInstallerDownload => '无法打开安装包，请从发布页下载。';

  @override
  String get canTReachGithubCheckYour => '连不上 GitHub，请检查网络后重试。';

  @override
  String get githubIsTemporarilyLimitingUpdateChecks =>
      'GitHub 暂时限制了检查次数，请稍后再试。';

  @override
  String githubRateLimitedUntil(Object value) {
    return 'GitHub 暂时限制了检查次数，请在 $value 之后再试。';
  }

  @override
  String get githubCanTProvideVersionInformation => 'GitHub 暂时无法提供版本信息，请稍后重试。';

  @override
  String get theDownloadedInstallerIsIncompleteOr => '下载的安装包不完整或已损坏，请重新下载。';

  @override
  String get checkAutomatically => '自动检查';

  @override
  String get checkForUpdates => '检查更新';

  @override
  String get releases => '发布页';

  @override
  String get releaseNotes => '更新说明';

  @override
  String get aboutUpdates => '关于与更新';

  @override
  String get checkForUpdatesAutomatically => '自动检查更新';

  @override
  String updateToMbAndRestart(Object version, Object mb) {
    return '更新到 $version（$mb MB）并重启';
  }

  @override
  String updateToMb(Object version, Object mb) {
    return '更新到 $version（$mb MB）';
  }

  @override
  String get readingVersion => '正在读取版本…';

  @override
  String get getNewVersionsForThisPlatform => '这个平台的新版本请从发布页获取。';

  @override
  String get developmentBuildNoReleaseTagAt => '开发版本（构建时未指定发布标签），不检查更新。';

  @override
  String get checksForANewVersionOnce => '每天自动检查一次新版本。';

  @override
  String get automaticChecksAreOff => '已关闭自动检查。';

  @override
  String get checkingForUpdates => '正在检查更新…';

  @override
  String get aNewVersionWasReleasedBut => '已有新版本发布，但还没有这个平台的安装包。';

  @override
  String get youReUpToDate => '已是最新版本。';

  @override
  String versionIsReadyToInstall(Object version) {
    return '新版本 $version 可以更新。';
  }

  @override
  String downloadingAndVerifyingProgress(Object value) {
    return '正在下载并校验 $value%…';
  }

  @override
  String get installingDropdrawerWillRestartAutomatically2 =>
      '正在安装，DropDrawer 将自动重启。';

  @override
  String get openingTheSystemInstaller2 => '正在打开系统安装界面…';

  @override
  String get updateFailedTryAgain => '更新失败，请重试。';

  @override
  String get enterAValidEmailAddressFirst => '请先填写有效的邮箱地址';

  @override
  String get verificationCodeSentCheckYourEmail => '验证码已发送，请查收邮件（10 分钟内有效）';

  @override
  String get passwordResetSignInWithYour => '密码已重置，请使用新密码登录';

  @override
  String get thisServerRequiresAnInvitationCode =>
      '当前服务器需要邀请码，请先填写邀请码再使用 Google 注册';

  @override
  String get enterAValidServerAddressFirst => '请先填写有效的服务器地址。';

  @override
  String get continueLabel => '继续';

  @override
  String get createAccountAndConnect => '创建账号并连接';

  @override
  String get resetPassword => '确认重置密码';

  @override
  String get resetYourPasswordWithAnEmail => '通过邮箱验证码重置密码';

  @override
  String get aDrawerForFilesAcrossYour => '跨端文件暂存抽屉';

  @override
  String get server => '服务器';

  @override
  String get account => '账号';

  @override
  String get usernameOrVerifiedEmail => '用户名或已验证邮箱';

  @override
  String get enterYourUsername => '输入用户名';

  @override
  String get email => '邮箱';

  @override
  String get verificationCode => '验证码';

  @override
  String get n6Digits => '6 位数字';

  @override
  String get sending => '发送中…';

  @override
  String get sendCode => '获取验证码';

  @override
  String get invitationCode => '邀请码';

  @override
  String get enterTheInvitationCodeFromYour => '输入管理员发放的邀请码';

  @override
  String get newPassword => '新密码';

  @override
  String get password => '密码';

  @override
  String get atLeast6Characters => '至少 6 位';

  @override
  String get finishGoogleAuthorizationInYourBrowser =>
      '请在系统浏览器完成 Google 授权，然后返回 DropDrawer。';

  @override
  String get stopWaiting => '取消等待';

  @override
  String get signUpWithGoogle => '使用 Google 注册';

  @override
  String get signInWithGoogle => '使用 Google 登录';

  @override
  String get forgotPassword => '忘记密码？';

  @override
  String get privacy => '隐私说明';

  @override
  String get noAccountCreateOne => '还没有账号？创建一个';

  @override
  String get haveAnAccountSignIn => '已有账号，返回登录';

  @override
  String fromDevice(Object cleanDeviceName) {
    return '来自 $cleanDeviceName';
  }

  @override
  String get sourceOffline => '来源离线';

  @override
  String get p2pCloud => 'P2P · 云端';

  @override
  String get p2pDirect => 'P2P 直连';

  @override
  String get savedToCloud => '已存云盘';

  @override
  String get createShareLink => '创建外链分享';

  @override
  String get copyText => '复制文本';

  @override
  String get copiedToClipboard => '已复制到剪贴板';

  @override
  String get saveToCloudAvailableOffline => '转存到云盘 (离线可下)';

  @override
  String get copyFilePasteIntoFileExplorer => '复制文件 (可直接 Ctrl+V 粘贴到资源管理器)';

  @override
  String get copyFilePasteIntoFinderOr => '复制文件 (可直接 ⌘V 粘贴到微信/访达)';

  @override
  String fileCopiedPasteItWith(Object pasteShortcutLabel) {
    return '已复制文件，可直接 $pasteShortcutLabel 粘贴';
  }

  @override
  String get couldnTCopyTheFile => '复制文件失败';

  @override
  String get showInFileExplorerOrDrag => '在资源管理器中显示 (也可直接按住卡片拖出)';

  @override
  String get showInFinderOrDragThe => '在访达中显示 (也可直接按住卡片拖出)';

  @override
  String get shareOpenInAnotherApp => '系统分享 / 其他应用打开';

  @override
  String get couldnTOpenTheShareSheet => '打开系统分享失败';

  @override
  String get downloadP2pFirst => 'P2P 优先下载';

  @override
  String get downloadFromCloud => '从云端下载';

  @override
  String get removeFromDrawer => '移出抽屉';

  @override
  String removeFailedError(Object e) {
    return '移出失败：$e';
  }

  @override
  String get preparingDownload => '正在准备下载';

  @override
  String get connectingOverP2p => '正在建立 P2P 连接';

  @override
  String get p2pLanCopy => 'P2P 局域网副本';

  @override
  String get p2pDirectConnection => 'P2P 端到端直连';

  @override
  String get p2pEncryptedRelay => 'P2P 加密中继';

  @override
  String get cloudDownload => '云端高速下载';

  @override
  String get canceling => '正在取消';

  @override
  String get cancelUpload => '取消上传';

  @override
  String get cancelDownload => '取消下载';

  @override
  String sendingToProgress(Object value, Object value2) {
    return '正在发送给 $value · $value2%';
  }

  @override
  String get cancelSending => '取消发送';

  @override
  String transferFailedError(Object error) {
    return '传输失败：$error';
  }

  @override
  String fromDeviceName(Object device) {
    return '来自 $device';
  }

  @override
  String get yourSessionHasExpiredAnAdministrator =>
      '登录状态已失效（可能被管理员强制下线或账号已停用），请重新登录';

  @override
  String get defaultCloudStorage => '默认云盘';

  @override
  String get thisVersionIsTooOldUpdate => '当前版本过低，请更新 DropDrawer 后再使用';

  @override
  String get yourSessionHasExpiredSignIn => '登录状态已失效，请重新登录';

  @override
  String get canTReachTheServerRight => '暂时无法连接服务器，请下拉刷新重试';

  @override
  String get couldnTOpenTheBrowser => '无法打开系统浏览器。';

  @override
  String get googleSignInTimedOutTry => 'Google 登录已超时，请重试。';

  @override
  String get sharedContentReceivedItWillSync => '已接收外部分享内容，登录后将自动同步到抽屉';

  @override
  String get sent => '发送已完成';

  @override
  String get sendingCanceled => '已取消发送';

  @override
  String p2pSendFailed(Object err) {
    return 'P2P 发送失败：$err';
  }

  @override
  String get downloadCanceled => '已取消下载';

  @override
  String get lanCopy => '局域网副本';

  @override
  String packingFolder(Object folderName) {
    return '正在打包文件夹「$folderName」...';
  }

  @override
  String packingFolderFailed(Object folderName, Object e) {
    return '打包文件夹「$folderName」失败: $e';
  }

  @override
  String get cloudUploadsAreTurnedOffOn => '服务器已关闭云端上传，文件将只通过设备间 P2P 传输';

  @override
  String p2pRegisterNotice(Object e) {
    return 'P2P 注册提示: $e';
  }

  @override
  String addedP2pOnly(Object name) {
    return '已加入「$name」(纯 P2P 端到端直连)';
  }

  @override
  String addItemFailed(Object name, Object e) {
    return '添加「$name」失败: $e';
  }

  @override
  String get textSyncedToAllDevices => '文本已同步到所有设备';

  @override
  String get cancelingSend => '正在取消发送';

  @override
  String cancelSendFailed(Object e) {
    return '取消发送失败：$e';
  }

  @override
  String get file => '文件';

  @override
  String uploadingFilesToCloud(int count) {
    return '正在上传 $count 个文件到云盘';
  }

  @override
  String get uploadingToTheCloud => '正在上传到云盘';

  @override
  String transferringFiles(int count) {
    return '正在传输 $count 个文件';
  }

  @override
  String get transferringFile => '正在传输文件';

  @override
  String itemAwaitingCloudConfirmation(Object itemName) {
    return '$itemName · 等待云盘确认…';
  }

  @override
  String get cloudUploadsAreTurnedOffOn2 => '服务器已关闭云端上传，请使用设备间 P2P 传输';

  @override
  String savedToBackend(Object defaultStorageBackendName) {
    return '已转存到「$defaultStorageBackendName」';
  }

  @override
  String get uploadCanceled => '已取消上传';

  @override
  String cloudUploadFailed(Object e) {
    return '上传云端失败: $e';
  }

  @override
  String get cancelingDownload => '正在取消下载';

  @override
  String cancelDownloadFailed(Object e) {
    return '取消下载失败：$e';
  }

  @override
  String get theSourceDeviceIsOfflineAnd => '来源设备离线，文件尚未存到云端';

  @override
  String downloadFailedError(Object e) {
    return '下载失败：$e';
  }

  @override
  String downloadedFromBackend(Object backendName) {
    return '已从「$backendName」下载完成';
  }

  @override
  String cloudDownloadFailed(Object e) {
    return '云端下载失败: $e';
  }

  @override
  String get nothingToDownloadTextItemsAnd => '没有可下载的文件（纯文本或离线未上云文件已跳过）';

  @override
  String downloadingFilesBatch(int filesLength) {
    return '正在批量下载 $filesLength 个文件...';
  }

  @override
  String downloadsStartedTo(int okCount, Object dir) {
    return '已发起/完成 $okCount 个文件下载 → $dir';
  }

  @override
  String get theSelectedItemsAreAlreadyIn => '所选条目均已存云盘或不在本机';

  @override
  String uploadingFilesBatchTo(
    int eligibleLength,
    Object defaultStorageBackendName,
  ) {
    return '正在批量上传 $eligibleLength 个文件到「$defaultStorageBackendName」...';
  }

  @override
  String savedFilesToCloud(int eligibleLength) {
    return '已完成 $eligibleLength 个文件的云端转存';
  }

  @override
  String clearedWithFailures(Object deleted, Object failed) {
    return '已清理 $deleted 项，$failed 项资源删除失败，条目已保留，可重试。';
  }

  @override
  String drawerCleared(int deleted) {
    return '已清空抽屉（共清理 $deleted 项）';
  }

  @override
  String removedItems(int deleted) {
    return '已移出 $deleted 个条目';
  }

  @override
  String get couldnTConfirmTheCleanupTry => '清理结果未确认，请稍后重试。';

  @override
  String get newFilesP2pOnlyNothingIs => '新文件策略：纯 P2P 直连（不上传服务器/云盘）';

  @override
  String policyAlwaysUpload(Object defaultStorageBackendName) {
    return '新文件策略：强制上传至「$defaultStorageBackendName」';
  }

  @override
  String policySmart(Object mb) {
    return '新文件策略：智能分流（<${mb}MB 自动云存，大文件纯 P2P）';
  }

  @override
  String get downloadFolderResetToTheDefault => '已恢复默认下载目录';

  @override
  String downloadFolderChanged(Object customDownloadDir) {
    return '下载目录已改为 $customDownloadDir';
  }

  @override
  String get notConnectedToTheServer => '未连接到服务器';

  @override
  String get shareLinksAreTurnedOffOn => '服务器已关闭外链分享';

  @override
  String get selectAtLeastOneItem => '请至少选择一个条目';

  @override
  String fileOnlyOnSourceDevice(Object itemName) {
    return '文件「$itemName」仅存在于来源设备且尚未上云，请在原设备先点“存云盘”后再分享';
  }

  @override
  String savingBeforeSharing(Object itemName) {
    return '外链分享前正在自动转存「$itemName」到云端...';
  }

  @override
  String autoUploadFailed(Object itemName, Object error) {
    return '「$itemName」自动上传失败：$error';
  }

  @override
  String shareLinkCreated(Object value) {
    return '已生成外链分享：$value';
  }

  @override
  String get shareLinkRevoked => '已撤销外链分享';

  @override
  String get notConnectedToServer => '未连接服务器';

  @override
  String get textPreview => '文本预览';

  @override
  String get imagePreview => '图片预览';

  @override
  String get fileDetails => '文件详情';

  @override
  String get backToDrawer => '返回抽屉';

  @override
  String get fileName => '文件名';

  @override
  String get size => '大小';

  @override
  String get sourceDevice => '来源设备';

  @override
  String get added => '添加时间';

  @override
  String get transferMethod => '传输方式';

  @override
  String get cloudCache => '云端缓存';

  @override
  String get p2pDirectOnly => '仅 P2P 直连';

  @override
  String get expires => '到期清理';

  @override
  String get neverExpires => '永不过期';

  @override
  String get localCopy => '本地缓存';

  @override
  String get savedOnThisDevice => '已保存到本机';

  @override
  String get locationOnThisDevice => '本机位置';

  @override
  String get info => '信息';

  @override
  String get transfer => '传输';

  @override
  String get cloudDownloadShort => '云端下载';

  @override
  String sendingToDevice(Object value) {
    return '正在发送给 $value';
  }

  @override
  String get downloadItToViewTheOriginal => '下载到本机后可查看原图';

  @override
  String get downloadItToViewTheFull => '下载到本地后可查看高清原图';

  @override
  String get transferStatus => '传输状态';

  @override
  String get p2pEndToEndOnly => '仅 P2P 端到端直连';

  @override
  String get localPath => '本机路径';

  @override
  String get copyAllText => '复制全部文本';

  @override
  String get copiedAllText => '已复制全部文本';

  @override
  String get quickLook => '快速查看';

  @override
  String get open => '打开';

  @override
  String get noAppCanOpenThisFile => '没有可以打开这个文件的应用';

  @override
  String get share => '分享…';

  @override
  String get saveToPhotos => '存到相册';

  @override
  String get savedToPhotos => '已保存到系统相册';

  @override
  String get couldnTSaveToPhotosCheck => '保存相册失败（请检查相册权限）';

  @override
  String get saveToCloudDownloadableWhileThe => '存到云盘（来源离线也能下载）';

  @override
  String get link => '外链';

  @override
  String get copyFile => '复制文件';

  @override
  String get showInFileExplorer => '在资源管理器中显示';

  @override
  String get showInFinder => '访达中显示';

  @override
  String get share2 => '系统分享';

  @override
  String get saveToCloudShort => '存云盘';

  @override
  String get shareLink => '外链分享';

  @override
  String get pressACombinationThatIncludesCtrl =>
      '请按下含 Ctrl、Alt 或 Win 的组合键，也可使用 F1–F24。按 Esc 取消。';

  @override
  String get pressAKeyCombinationItMust =>
      '请直接按下组合键（需含 ⌘ / ⌥ / ⌃ 或 F1-F12，Esc 取消）';

  @override
  String hotkeyActive(Object label) {
    return '已生效：$label';
  }

  @override
  String hotkeyTakenChooseAnother(Object label) {
    return '系统可能已占用 $label，请换一个组合键';
  }

  @override
  String hotkeyUpdatedTo(Object label) {
    return '全局呼出快捷键已更新为 $label';
  }

  @override
  String hotkeyTakenTryAnother(Object label) {
    return '系统可能已占用 $label，请尝试其他组合';
  }

  @override
  String hotkeySetTo(Object label) {
    return '全局呼出快捷键已设为 $label';
  }

  @override
  String get smart => '智能';

  @override
  String get p2pOnly => '纯 P2P';

  @override
  String get serverDefault => '跟随服务器';

  @override
  String get n24Hours => '24 小时';

  @override
  String get n7Days => '7 天';

  @override
  String get n30Days => '30 天';

  @override
  String daysCount(int value) {
    return '$value 天';
  }

  @override
  String hoursCount(int cap) {
    return '$cap 小时';
  }

  @override
  String get preferences => '偏好设置';

  @override
  String get smartSendsSmallFilesToThe =>
      '智能模式下小文件同步存云盘、大文件直连 P2P；纯 P2P 不经服务器；存云盘支持离线下载。';

  @override
  String get transferPolicyForNewFiles => '新文件传输策略';

  @override
  String get transferPolicy => '传输策略';

  @override
  String get smartModeCloudThreshold => '智能模式上云阈值';

  @override
  String get cloudThreshold => '上云阈值';

  @override
  String get inSmartModeFilesSmallerThan =>
      '智能模式下，小于该体积的文件同时缓存到云盘，更大的只走 P2P 直连。';

  @override
  String get autoCleanup => '自动清理';

  @override
  String get expiredItemsAreRemovedFromThe => '到期后自动清理云端缓存与列表记录。';

  @override
  String get defaultExpiration => '默认过期时间';

  @override
  String get expiration => '过期时间';

  @override
  String get downloads => '下载';

  @override
  String get saveLocation => '保存位置';

  @override
  String get filesDropdrawer => '「文件」App › DropDrawer';

  @override
  String get loading => '加载中…';

  @override
  String get restoreDefaultLocation => '恢复默认位置';

  @override
  String get transfersAutoCleanup => '传输与自动清理';

  @override
  String get smartSmallFilesAlsoGoTo =>
      '智能：小文件同时存云盘、大文件只走 P2P；纯 P2P：不经过服务器；强制存云盘：来源离线也能下载';

  @override
  String get defaultExpirationCleanup => '默认过期自动清理';

  @override
  String get newFilesAndTextAreRemoved => '新拖入的文件/文本到期后自动清理云端缓存与抽屉记录';

  @override
  String get smartModeAutoUploadThreshold => '智能模式自动上云阈值';

  @override
  String get filesSmallerThanThisAreCached => '小于该体积自动缓存至云盘，超过则纯 P2P 端到端直连';

  @override
  String get defaultDownloadFolder => '默认下载目录';

  @override
  String get restoreDefault => '恢复默认';

  @override
  String get loadingDots => '加载中...';

  @override
  String get changeFolder => '更改目录';

  @override
  String get windowWindowsIntegration => '窗口与 Windows 集成';

  @override
  String get windowMacosIntegration => '窗口与 macOS 集成';

  @override
  String get drawerEdge => '边缘抽屉停靠侧';

  @override
  String get youCanAlsoDragTheEdge => '也可直接按住边缘悬浮手柄上下或跨屏拖动调整';

  @override
  String get leftSideOfTheScreen => '屏幕左侧';

  @override
  String get rightSideOfTheScreen => '屏幕右侧';

  @override
  String get globalShortcutToOpenTheDrawer => '全局快捷键呼出抽屉';

  @override
  String get opensOrClosesTheDrawerFrom => '任意应用下快速展开或收起抽屉，可自定义避免冲突';

  @override
  String get currentShortcut => '当前快捷键';

  @override
  String get pressAKeyCombination => '按下组合键...';

  @override
  String get clickToChange => '点击修改';

  @override
  String hotkeyReady(Object hotkeyLabel) {
    return '全局监听已就绪 · 任意应用按 $hotkeyLabel 即可呼出';
  }

  @override
  String get theGlobalShortcutMayAlreadyBe => '全局快捷键可能已被占用，请换一个组合键';

  @override
  String get dropdrawerNeedsMacosAccessibilityPermissionTo =>
      '需要开启 macOS「辅助功能」权限才能在其他应用下响应全局快捷键';

  @override
  String get openAccessibilitySettings => '前往开启辅助功能';

  @override
  String get permissionGrantedTheGlobalShortcutWorks => '已检测到权限，全局快捷键立即生效';

  @override
  String get permissionNotDetectedYetEnableDropdrawer =>
      '尚未检测到权限，请在系统设置中勾选 dropdrawer_app';

  @override
  String get checkAgain => '重新检测';

  @override
  String get showTheDrawerInTheTaskbar => '在任务栏显示抽屉';

  @override
  String get showIconInTheDock => '在程序坞 (Dock) 显示图标';

  @override
  String get whenOffOpenTheDrawerFrom => '关闭时可通过系统托盘打开抽屉';

  @override
  String get whenOffDropdrawerStaysInThe => '关闭时仅常驻顶部菜单栏，开启后同时在 Dock 显示';

  @override
  String get translucentBackground => '毛玻璃背景';

  @override
  String get notSupportedOnThisSystemRequires =>
      '当前系统不支持（需 Windows 11 22H2 及以上），已使用不透明背景';

  @override
  String get usesTheWindows11MicaAcrylic =>
      '使用 Windows 11 的 Mica / 亚克力效果；如背景显示异常可关闭';

  @override
  String get launchAtLogin => '开机自动启动';

  @override
  String get staysInTheSystemTrayWhen => '登录 Windows 时自动驻留系统托盘';

  @override
  String get runsQuietlyInTheMenuBar => '登录 macOS 时自动静默驻留状态栏与屏幕边缘';

  @override
  String get launchAtLoginTurnedOn => '已开启开机自启动';

  @override
  String get launchAtLoginTurnedOff => '已关闭开机自启动';

  @override
  String get couldnTChangeLaunchAtLogin => '修改开机自启动失败';

  @override
  String shareClipboardText(Object url, Object plainPasscode) {
    return '链接：$url\n提取码：$plainPasscode';
  }

  @override
  String get thisServerRequiresAPasscodeFor => '服务器要求外链必须设置提取码';

  @override
  String get shareLinkCreatedAndCopiedTo => '外链已生成并自动复制到剪贴板';

  @override
  String get manageShareLinks => '外链分享管理';

  @override
  String createBundleLinkItems(int targetItemsLength) {
    return '打包创建外链 ($targetItemsLength 项)';
  }

  @override
  String bundleLinkCount(Object targetItemsLength) {
    return '打包外链 ($targetItemsLength)';
  }

  @override
  String get createShareLink2 => '创建外链';

  @override
  String get shareLinksTitle => '外链管理';

  @override
  String get refreshShareLinks => '刷新外链列表';

  @override
  String get shareLinksAreTurnedOffOn2 => '服务器已关闭外链分享，暂时无法创建新的外链。';

  @override
  String createdLinksCount(Object shareLinksLength) {
    return '已创建的外链 ($shareLinksLength)';
  }

  @override
  String get noShareLinksYetNclickAn => '暂无外链分享\n点击单条链接图标，或进入「多选」打包创建合集外链';

  @override
  String get n1Hour => '1 小时';

  @override
  String get forever => '永久';

  @override
  String get unlimited => '不限';

  @override
  String get n1TimeBurnAfterReading => '1 次（阅后即焚）';

  @override
  String get n5Times => '5 次';

  @override
  String get n20Times => '20 次';

  @override
  String hoursCountH(int h) {
    return '$h 小时';
  }

  @override
  String valueAtCap(Object value) {
    return '$value（上限）';
  }

  @override
  String timesAtCap(int n) {
    return '$n 次（上限）';
  }

  @override
  String bundleItemsSize(int itemsLength, Object value) {
    return '打包 $itemsLength 项 · $value';
  }

  @override
  String get sharedContent => '分享内容';

  @override
  String uploadBeforeShareNote(
    int pendingUploadCount,
    Object defaultStorageBackendName,
  ) {
    return '生成前会先把 $pendingUploadCount 个文件上传到「$defaultStorageBackendName」，拿到链接的人用浏览器即可下载，无需登录。';
  }

  @override
  String get anyoneWithTheLinkCanDownload => '拿到链接的人用浏览器即可下载，无需登录。';

  @override
  String andMoreItems(int value) {
    return '以及另外 $value 项';
  }

  @override
  String get bundleTitle => '合集标题';

  @override
  String firstNameAndMore(Object firstName, int itemsLength) {
    return '$firstName 等 $itemsLength 项';
  }

  @override
  String get access => '访问设置';

  @override
  String get thisServerRequiresAPasscodeFor2 => '服务器要求外链必须设置提取码。';

  @override
  String get ifYouLeaveThePasscodeEmpty => '提取码留空时，任何拿到链接的人都能下载。';

  @override
  String get expiresAfter => '有效期';

  @override
  String get downloads2 => '下载次数';

  @override
  String get passcodeRequired => '提取码（必填）';

  @override
  String get passcode => '提取码';

  @override
  String get leaveEmptyForPublic => '留空为公开';

  @override
  String get generateA4CharacterPasscode => '随机生成 4 位提取码';

  @override
  String get creating => '正在生成…';

  @override
  String get uploadAndCreateLink => '上传并生成外链';

  @override
  String get createBundleLinkAndCopy => '生成合集外链并复制';

  @override
  String get createLinkAndCopy => '生成外链并复制';

  @override
  String get createdAndCopiedToTheClipboard => '已生成并复制到剪贴板';

  @override
  String get linkLabel => '链接';

  @override
  String get copyAgain => '再次复制';

  @override
  String get copiedLinkDetails => '已复制外链信息';

  @override
  String get openInBrowser => '在浏览器中打开';

  @override
  String createdLinksCountFull(Object shareLinksLength) {
    return '已创建的外链（$shareLinksLength）';
  }

  @override
  String get longPressOrOpenAnyItem => '在首页长按或打开任意一项即可创建外链；多选后可打包成合集。';

  @override
  String get tapALinkToCopyOpen => '点按一条外链可以复制、打开或撤销。';

  @override
  String get loadingEllipsis => '正在加载…';

  @override
  String get noShareLinksYet => '还没有外链';

  @override
  String bundleOfItems(int itemCount) {
    return '$itemCount 项合集';
  }

  @override
  String get passcodeRequired2 => '需提取码';

  @override
  String downloadedOfMax(Object downloadCount, Object maxDownloads) {
    return '已下 $downloadCount/$maxDownloads 次';
  }

  @override
  String downloadedCount(int downloadCount) {
    return '已下 $downloadCount 次';
  }

  @override
  String get expired => '已过期';

  @override
  String get downloadLimitReached => '次数用尽';

  @override
  String get neverExpires2 => '永久有效';

  @override
  String get copyLink => '复制链接';

  @override
  String get linkCopied => '已复制外链';

  @override
  String get revokeLink => '撤销外链';

  @override
  String primaryNameAndMore(Object primaryName, int itemsLength) {
    return '$primaryName 等 $itemsLength 项';
  }

  @override
  String sizeUploadBeforeShare(
    Object value,
    int pendingUploadCount,
    Object defaultStorageBackendName,
  ) {
    return '$value · 生成前自动上云 $pendingUploadCount 个文件至「$defaultStorageBackendName」';
  }

  @override
  String sizeReadyNoSignIn(Object value) {
    return '$value · 已就绪，外部浏览器免登录提取';
  }

  @override
  String optionalDefaultTitle(Object primaryName, Object itemsLength) {
    return '可选，默认「$primaryName 等 $itemsLength 项」';
  }

  @override
  String get downloadLimit => '下载次数限制';

  @override
  String get oneTimeBurn => '1次(阅后即焚)';

  @override
  String get leaveEmptyForPublicAccess => '留空为公开免密';

  @override
  String get uploadToCloudAndCreateLink => '自动上云并生成外链';

  @override
  String get copyLinkAgain => '再次复制链接';

  @override
  String get previewInBrowser => '在浏览器中打开预览';

  @override
  String copyLinkUrl(Object fullUrl) {
    return '复制外链 ($fullUrl)';
  }

  @override
  String linkCopiedUrl(Object fullUrl) {
    return '已复制外链：$fullUrl';
  }

  @override
  String get openInBrowserShort => '浏览器打开';

  @override
  String daysLeft(int diffInDays) {
    return '剩余 $diffInDays 天';
  }

  @override
  String hoursLeft(int diffInHours) {
    return '剩余 $diffInHours 小时';
  }

  @override
  String minutesLeft(int value) {
    return '剩余 $value 分钟';
  }

  @override
  String get quarkDrive => '夸克网盘';

  @override
  String get baiduNetdisk => '百度网盘';

  @override
  String get webdavStorage => 'WebDAV 网盘';

  @override
  String get serverLocalStorage => '服务器本地盘';

  @override
  String get enterTheGoogleOauthClientId =>
      '请先填写 Google OAuth Client ID 和 Client Secret';

  @override
  String get googleDriveAuthorizationOpenedInYour =>
      '已打开浏览器授权 Google Drive，同意后点下方「刷新列表」即可';

  @override
  String authorizationFailedToStart(Object e) {
    return '发起授权失败: $e';
  }

  @override
  String get enterARefreshTokenOrUse =>
      '请填写 Refresh Token，或点击上方「浏览器一键授权 Google」';

  @override
  String get pasteTheCookieFromPanQuark => '请粘贴 pan.quark.cn 的 Cookie';

  @override
  String get storageSaved => '已保存原生云盘策略';

  @override
  String saveFailedColon(Object e) {
    return '保存失败: $e';
  }

  @override
  String get cloudStorage => '云盘与存储';

  @override
  String get refreshStorageList => '刷新存储列表';

  @override
  String get cloudStorage2 => '原生云盘与存储';

  @override
  String get editStorage => '编辑存储';

  @override
  String get configured => '已配置云盘';

  @override
  String get addStorage => '添加原生云盘';

  @override
  String get theServerAdministratorHasDisabledEvery =>
      '服务器管理员已停用所有可添加的存储类型，暂时无法添加新的云盘。';

  @override
  String get localDisk => '本地盘';

  @override
  String get name => '名称';

  @override
  String get optionalUseOneClickAuthorizationBelow => '可留空，点下方一键授权自动获取';

  @override
  String get folderId => '目录 ID';

  @override
  String get rootOrAFolderId => 'root (或指定文件夹 ID)';

  @override
  String get fullCookieFromPanQuarkCn => 'pan.quark.cn 完整 Cookie';

  @override
  String get folderFid => '目录 fid';

  @override
  String get n0IsTheRootFolder => '0 表示根目录';

  @override
  String get accessTokenOrFillInRefresh => 'Access Token (或填下方 Refresh)';

  @override
  String get optionalUsedForAutomaticRefresh => '可选，用于自动刷新';

  @override
  String get optionalLongLivedRefreshToken10 => '可选，10年长效刷新令牌';

  @override
  String get path => '路径';

  @override
  String get url => '地址';

  @override
  String get username => '用户名';

  @override
  String get filesAreSavedInThisAccount =>
      '文件保存在服务器数据目录中属于当前账号的文件夹（由服务端 DROPDRAWER_LOCAL_STORAGE 决定）。';

  @override
  String get newCloudUploadsUseTheDefault => '新上传至云端的文件会使用默认存储。';

  @override
  String connectionOk(Object msg) {
    return '连通正常: $msg';
  }

  @override
  String connectionFailed(Object msg) {
    return '连通失败: $msg';
  }

  @override
  String get defaultStorageUpdated => '已更新默认存储';

  @override
  String switchDefaultStorageFailed(Object e) {
    return '切换默认存储失败：$e';
  }

  @override
  String get configuredShort => '已配置';

  @override
  String get addStorageShort => '添加云盘';

  @override
  String get noStorageYetSwitchToAdd => '还没有存储策略，切换到「添加云盘」直连配置。';

  @override
  String tapToEditNote(Object defaultNote) {
    return '点按存储项可编辑。$defaultNote';
  }

  @override
  String get noStorage => '暂无云盘';

  @override
  String get defaultLabel => '默认';

  @override
  String get setAsDefault => '设为默认';

  @override
  String get edit => '编辑';

  @override
  String get testConnection => '测试连通性';

  @override
  String get delete => '删除';

  @override
  String get typeLabel => '类型';

  @override
  String get storageType => '云盘类型';

  @override
  String get storageBack => '云盘';

  @override
  String get connection => '连接信息';

  @override
  String callbackUrlHint(Object serverUrl) {
    return '回调地址请填：$serverUrl/api/oauth/google/callback';
  }

  @override
  String get useAsDefaultTransferStorage => '设为默认中转存储';

  @override
  String get authorizeGoogleDriveInBrowser => '在浏览器中授权 Google Drive';

  @override
  String get iAlreadyHaveARefreshToken => '已有 Refresh Token，直接保存';

  @override
  String get saving => '正在保存…';

  @override
  String get save => '保存';

  @override
  String get noStorageYetUseAddStorage => '暂无存储策略，点击上方「添加原生云盘」直连配置';

  @override
  String cantReadStorage(Object e) {
    return '无法读取存储配置：$e';
  }

  @override
  String get storageNameCanTBeEmpty => '存储名称不能为空';

  @override
  String get theCapacityLimitMustBeA => '容量上限必须为正整数';

  @override
  String get storageSettingsSaved => '已保存存储配置';

  @override
  String saveFailedFull(Object e) {
    return '保存失败：$e';
  }

  @override
  String get leaveTheCapacityLimitEmptyFor => '容量上限留空表示不限。';

  @override
  String get leaveFieldsEmptyToKeepThe => '留空保留现有凭据。更换存储位置可使用「添加云盘」。';

  @override
  String get limitBytes => '上限（字节）';

  @override
  String get saveChanges => '保存修改';

  @override
  String get storageLocation => '存储位置';

  @override
  String get authorizeGoogleDriveInBrowserOne => '浏览器一键授权 Google Drive';

  @override
  String get alreadyHaveARefreshTokenSave => '已有 Refresh Token？直接保存';

  @override
  String get saveStorage => '保存原生云盘配置';

  @override
  String get localDiskFull => '本地磁盘';

  @override
  String get p2pEndToEndOnThis => '仅本机 P2P 端到端直连 · 不占服务器与云盘';

  @override
  String policyAlwaysUploadShort(Object defaultStorageBackendName) {
    return '直接上传至「$defaultStorageBackendName」· 离线可下';
  }

  @override
  String policySmartShort(Object value) {
    return '小于 ${value}MB 自动云存 · 大文件纯 P2P 直连';
  }

  @override
  String get dockedToTheLeftSideOf => '已停靠到屏幕左侧';

  @override
  String get dockedToTheRightSideOf => '已停靠到屏幕右侧';

  @override
  String transfersInProgress(int active) {
    return '还有 $active 项传输正在进行';
  }

  @override
  String get quittingInterruptsTheCurrentTransfersUnfinished =>
      '退出软件会中断当前传输（下次打开时未完成的云盘上传会自动续传）。是否仍要退出？';

  @override
  String get quitAnyway => '仍要退出';

  @override
  String get keepRunningInBackground => '后台继续';

  @override
  String get clearAll => '清空全部';

  @override
  String clearAllMessage(int itemsLength) {
    return '将清理列表中的 $itemsLength 项内容及其在服务器或网盘的副本。本机原文件会保留。';
  }

  @override
  String get clear => '清空';

  @override
  String filePickerFailed(Object e) {
    return '打开文件选择器失败: $e';
  }

  @override
  String photoPickerFailed(Object e) {
    return '打开相册失败: $e';
  }

  @override
  String get screenshotPastedAndSyncedToThe => '已粘贴截图并同步到抽屉';

  @override
  String pastedFiles(int pathsLength) {
    return '已粘贴 $pathsLength 个文件到抽屉';
  }

  @override
  String get foldersCanTBePastedDirectly => '暂不支持直接粘贴文件夹，请先压缩或选择具体文件';

  @override
  String get theClipboardIsEmptyYouCan => '剪贴板为空（支持粘贴文件、截图或文本）';

  @override
  String clipboardReadFailed(Object e) {
    return '读取剪贴板失败: $e';
  }

  @override
  String get add => '添加';

  @override
  String get releaseToDropIntoTheDrawer => '松手放入跨端抽屉';

  @override
  String get moveDrawer => '拖动抽屉';

  @override
  String get dragHereToDropIntoThe => '拖到这儿，放入跨端抽屉';

  @override
  String get chooseFiles => '选取文件';

  @override
  String get photoLibrary => '照片图库';

  @override
  String get paste => '粘贴';

  @override
  String get select => '选择';

  @override
  String get downloadAll => '全部下载';

  @override
  String get devicesP2p => '设备与 P2P';

  @override
  String get signOut => '退出登录';

  @override
  String selectedCount(Object selectedIdsLength) {
    return '已选 $selectedIdsLength 项';
  }

  @override
  String get more => '更多';

  @override
  String get deselectAll => '取消全选';

  @override
  String get selectAll => '全选';

  @override
  String get done => '完成';

  @override
  String get searchDropdrawer => '在 DropDrawer 中搜索';

  @override
  String get closeSearch => '关闭搜索';

  @override
  String get clearSearch => '清除';

  @override
  String get connecting => '正在连接…';

  @override
  String devicesOnline(int onlineDeviceCount) {
    return '$onlineDeviceCount 台设备在线';
  }

  @override
  String itemsCount(int itemsLength) {
    return '$itemsLength 项';
  }

  @override
  String get all => '全部';

  @override
  String get text => '文本';

  @override
  String get search => '搜索';

  @override
  String statusFiltered(
    Object status,
    Object visibleItemsLength,
    Object itemsLength,
  ) {
    return '$status · 筛选 $visibleItemsLength/$itemsLength';
  }

  @override
  String statusItems(Object status, int itemsLength) {
    return '$status · $itemsLength 项';
  }

  @override
  String get saveToCloudAction => '存到云盘';

  @override
  String devicesOnlineShort(Object onlineDeviceCount) {
    return '$onlineDeviceCount 设备在线';
  }

  @override
  String get pinnedOpenClickToHideAutomatically => '已固定展开（点击开启离开自动隐藏）';

  @override
  String get hidesAutomaticallyWhenYouLeaveClick => '离开自动隐藏（点击固定展开）';

  @override
  String get collapseToEdgeEsc => '收起到边缘 (Esc)';

  @override
  String get switchToARegularWindow => '切换为常规窗口';

  @override
  String get switchToTheEdgeDrawer => '切换为边缘抽屉';

  @override
  String get cloudStorageTransferStorage => '多云盘与中转存储';

  @override
  String get deviceStatus => '设备状态';

  @override
  String get clearDrawer => '清空抽屉';

  @override
  String get dockRight => '停靠右侧';

  @override
  String get dockLeft => '停靠左侧';

  @override
  String get quit => '退出应用';

  @override
  String get releaseToDropIntoTheDrawer2 => '松开即可放入抽屉';

  @override
  String dropPickOrPaste(Object pasteShortcutLabel) {
    return '拖入、选取或 $pasteShortcutLabel 粘贴';
  }

  @override
  String smartPasteTooltip(Object pasteShortcutLabel) {
    return '智能粘贴文件 / 截图 / 文本 ($pasteShortcutLabel)';
  }

  @override
  String smartPolicyShort(Object value) {
    return '智能(<${value}M上云)';
  }

  @override
  String get policyP2pOnly => '纯 P2P 直连';

  @override
  String get alwaysSaveToCloud => '强制存云盘';

  @override
  String selectAllCount(Object visibleItemsLength) {
    return '全选 ($visibleItemsLength)';
  }

  @override
  String filteredResults(Object visibleItemsLength, Object itemsLength) {
    return '筛选结果 · $visibleItemsLength/$itemsLength';
  }

  @override
  String drawerItemsCount(int itemsLength) {
    return '抽屉内容 · $itemsLength 项';
  }

  @override
  String get multiSelect => '多选';

  @override
  String get confirmClear => '确认清空';

  @override
  String get searchFileNamesOrText => '搜索文件名或文本...';

  @override
  String removedItem(Object itemName) {
    return '已移出「$itemName」';
  }

  @override
  String get undo => '撤销';

  @override
  String get shareAction => '分享';

  @override
  String get copy => '复制';

  @override
  String copiedFiles(int localSelectedPathsLength, Object pasteShortcutLabel) {
    return '已复制 $localSelectedPathsLength 个文件，可直接 $pasteShortcutLabel 粘贴';
  }

  @override
  String deleteCount(Object selectedItemsLength) {
    return '删除($selectedItemsLength)';
  }

  @override
  String get nothingHereYet => '暂无内容';

  @override
  String get theDrawerIsEmpty => '抽屉是空的';

  @override
  String get tapAddAtTheBottomRight =>
      '点右下角「添加」选取文件、照片或粘贴内容\n也可在其他 App 中「分享 → DropDrawer」发送';

  @override
  String get tapAtTheBottomRightTo =>
      '点右下角「+」选取文件、照片或粘贴内容\n也可在其他 App 中「分享 → DropDrawer」发送';

  @override
  String get dragAFileOrTextNear => '拖起文件或文本靠近悬浮引导条\n点击边缘手柄展开 · 拖动可调整上下或左右停靠';

  @override
  String get noMatches => '没有匹配的内容';

  @override
  String get thisDeviceSuffix => '（本机）';

  @override
  String get online => '在线';

  @override
  String get offline => '离线';

  @override
  String get thisDeviceSP2pNode => '本机 P2P 节点';

  @override
  String get irohQuicNodeRunningDirectLan =>
      'iroh QUIC 节点运行中：局域网与公网直连优先，必要时经加密中继。';

  @override
  String get theP2pEngineIsnTLoaded => 'P2P 引擎未加载，传输只能经过服务器和云盘。';

  @override
  String get nodeStatus => '节点状态';

  @override
  String get running => '运行中';

  @override
  String get notLoaded => '未加载';

  @override
  String get nodeIdCopied => '已复制 Node ID';

  @override
  String get devicesOnThisAccount => '同账号设备';

  @override
  String sameNameOffline(Object sameNameOfflineLength) {
    return '同名离线设备（$sameNameOfflineLength）';
  }

  @override
  String get oldRecordsLeftWhenTheSame => '同一台设备重装或重新登录后留下的旧记录。';

  @override
  String get signedInDevicesP2pNodes => '已登录设备与 P2P 节点';

  @override
  String get irohQuicP2pNodeRunningOn => '本机 iroh QUIC P2P 节点运行中';

  @override
  String get p2pEngineNotLoaded => 'P2P 引擎未加载';

  @override
  String get thisDeviceSuffixShort => ' (本机)';

  @override
  String get irohP2pReadyDirectLanAnd => 'iroh P2P 就绪 · 局域网与公网直连优先';

  @override
  String get runningInCloudRelayMode => '当前运行在云端中转模式';

  @override
  String get addingToTheDrawer => '正在加入抽屉…';

  @override
  String get justNow => '刚刚';

  @override
  String minutesAgo(int diffInMinutes) {
    return '$diffInMinutes 分钟前';
  }

  @override
  String hoursAgo(int diffInHours) {
    return '$diffInHours 小时前';
  }

  @override
  String get yesterday => '昨天';

  @override
  String p2pDirectPlus(Object value) {
    return 'P2P 直连 + $value';
  }

  @override
  String get general => '通用';

  @override
  String get language => '语言';

  @override
  String get languageSystem => '跟随系统';

  @override
  String get languageFooter => '跟随系统时，系统语言为中文则显示中文，其他语言显示英文。';

  @override
  String get nativeTrayToggle => '展开 / 收起';

  @override
  String get nativeRegularWindow => '常规窗口';

  @override
  String get nativeEdgeDrawer => '边缘抽屉';

  @override
  String nativeQuitActiveTitle(Object count) {
    return '还有 $count 项传输正在进行';
  }

  @override
  String get nativeQuitActiveMessage =>
      '退出软件会中断当前传输，下次打开软件时未完成的云盘上传会自动续传。是否仍要退出？';

  @override
  String get nativePickFilesTitle => '选择要放入抽屉的文件或文件夹';

  @override
  String get nativePickFilesPrompt => '放入抽屉';

  @override
  String get nativePickFolderTitle => '选择默认下载保存目录';

  @override
  String get nativePickFolderPrompt => '选择此目录';
}
