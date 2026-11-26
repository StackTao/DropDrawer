package com.dropdrawer.dropdrawer_app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.ext.SdkExtensions
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    companion object {
        private const val MOBILE_CHANNEL = "com.dropdrawer/mobile"
        private const val REQUEST_PICK_MEDIA = 4102
    }

    private var mobileChannel: MethodChannel? = null
    private var pendingMediaResult: MethodChannel.Result? = null
    private val pendingFiles = mutableListOf<String>()
    private val pendingTexts = mutableListOf<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShareIntent(intent, pushLive = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent, pushLive = true)
    }

    override fun onDestroy() {
        pendingMediaResult = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mobileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MOBILE_CHANNEL)
        mobileChannel?.setMethodCallHandler { call, result ->
            handleMethodCall(call, result)
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "consumePendingShares" -> {
                val payload = mapOf(
                    "files" to pendingFiles.toList(),
                    "texts" to pendingTexts.toList(),
                )
                pendingFiles.clear()
                pendingTexts.clear()
                result.success(payload)
            }
            "pickMedia" -> pickMedia(result)
            "shareFiles" -> {
                val raw = call.argument<List<*>>("paths") ?: emptyList<Any>()
                val paths = raw.mapNotNull { it?.toString() }.filter { it.isNotEmpty() }
                result.success(shareFiles(paths))
            }
            "shareText" -> {
                val text = call.argument<String>("text") ?: ""
                result.success(shareText(text))
            }
            "openFile" -> {
                val path = call.argument<String>("path") ?: ""
                result.success(openFile(path))
            }
            "saveToGallery" -> {
                val path = call.argument<String>("path") ?: ""
                result.success(saveToGallery(path))
            }
            "openExternalUrl" -> {
                val url = call.argument<String>("url") ?: ""
                result.success(openExternalUrl(url))
            }
            "installUpdate" -> {
                val path = call.argument<String>("path") ?: ""
                result.success(installUpdate(path))
            }
            "readClipboard" -> {
                val imagePath = call.argument<String>("imagePath") ?: ""
                result.success(readClipboard(imagePath))
            }
            else -> result.notImplemented()
        }
    }

    private fun supportsAndroidPhotoPicker(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            true
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2
        } else {
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun pickMedia(result: MethodChannel.Result) {
        pendingMediaResult?.success(emptyList<String>())
        pendingMediaResult = result

        if (supportsAndroidPhotoPicker()) {
            try {
                val maxLimit = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    minOf(50, MediaStore.getPickImagesMaxLimit())
                } else {
                    50
                }
                val photoPicker = Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                    putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, maxLimit)
                }
                startActivityForResult(photoPicker, REQUEST_PICK_MEDIA)
                return
            } catch (_: ActivityNotFoundException) {
                // Fall back to system gallery picker below.
            }
        }

        try {
            val gallery = Intent(Intent.ACTION_PICK).apply {
                setDataAndType(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "image/*")
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
            startActivityForResult(gallery, REQUEST_PICK_MEDIA)
        } catch (_: Exception) {
            pendingMediaResult = null
            result.success(emptyList<String>())
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PICK_MEDIA) {
            val result = pendingMediaResult
            pendingMediaResult = null
            if (result == null) return
            if (resultCode != Activity.RESULT_OK || data == null) {
                result.success(emptyList<String>())
                return
            }

            val uris = mutableListOf<Uri>()
            val clip = data.clipData
            if (clip != null && clip.itemCount > 0) {
                for (i in 0 until clip.itemCount) {
                    clip.getItemAt(i)?.uri?.let { uris.add(it) }
                }
            } else {
                data.data?.let { uris.add(it) }
            }
            if (uris.isEmpty()) {
                result.success(emptyList<String>())
                return
            }

            Thread {
                val paths = uris.mapNotNull { copyUriToCacheDir(it, "picked_media") }
                runOnUiThread {
                    try {
                        result.success(paths)
                    } catch (_: Exception) {}
                }
            }.start()
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun handleShareIntent(intent: Intent?, pushLive: Boolean) {
        if (intent == null) return
        val action = intent.action ?: return
        val newFiles = mutableListOf<String>()
        val newTexts = mutableListOf<String>()

        when (action) {
            Intent.ACTION_SEND -> {
                val stream = getParcelableUri(intent, Intent.EXTRA_STREAM)
                if (stream != null) {
                    copyUriToIncomingCache(stream)?.let { newFiles.add(it) }
                } else {
                    val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    if (!text.isNullOrBlank()) {
                        newTexts.add(text)
                    }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val streams = getParcelableUriList(intent, Intent.EXTRA_STREAM)
                for (uri in streams) {
                    copyUriToIncomingCache(uri)?.let { newFiles.add(it) }
                }
            }
        }

        if (newFiles.isEmpty() && newTexts.isEmpty()) return

        val channel = mobileChannel
        if (pushLive && channel != null) {
            channel.invokeMethod(
                "onSharedPayload",
                mapOf("files" to newFiles, "texts" to newTexts),
            )
        } else {
            pendingFiles.addAll(newFiles)
            pendingTexts.addAll(newTexts)
        }
    }

    @Suppress("DEPRECATION")
    private fun getParcelableUri(intent: Intent, key: String): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(key, Uri::class.java)
        } else {
            intent.getParcelableExtra(key)
        }
    }

    @Suppress("DEPRECATION")
    private fun getParcelableUriList(intent: Intent, key: String): List<Uri> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(key, Uri::class.java) ?: emptyList()
        } else {
            intent.getParcelableArrayListExtra<Uri>(key) ?: emptyList()
        }
    }

    private fun copyUriToIncomingCache(uri: Uri): String? =
        copyUriToCacheDir(uri, "shared_incoming")

    private fun copyUriToCacheDir(uri: Uri, subDir: String): String? {
        return try {
            val dir = File(cacheDir, subDir).apply { mkdirs() }
            val rawName = queryDisplayName(uri) ?: "media_${System.currentTimeMillis()}"
            val withExt = ensureExtension(rawName, uri)
            val safeName = withExt.replace(Regex("[/\\\\:*?\"<>|]"), "_").ifBlank {
                "media_${System.currentTimeMillis()}"
            }
            val dest = uniqueFile(dir, safeName)
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(dest).use { output ->
                    input.copyTo(output)
                }
            } ?: return null
            dest.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun ensureExtension(name: String, uri: Uri): String {
        val dot = name.lastIndexOf('.')
        if (dot > 0 && dot < name.length - 1) return name
        val ext = contentResolver.getType(uri)?.let {
            MimeTypeMap.getSingleton().getExtensionFromMimeType(it)
        }
        return if (!ext.isNullOrBlank()) "$name.$ext" else name
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") {
            return uri.lastPathSegment
        }
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) {
                    val name = cursor.getString(idx)
                    if (!name.isNullOrBlank()) return name
                }
            }
        }
        val ext = contentResolver.getType(uri)?.let {
            MimeTypeMap.getSingleton().getExtensionFromMimeType(it)
        }
        return if (!ext.isNullOrBlank()) {
            "shared_${System.currentTimeMillis()}.$ext"
        } else {
            null
        }
    }

    private fun uniqueFile(dir: File, name: String): File {
        var candidate = File(dir, name)
        if (!candidate.exists()) return candidate
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var i = 1
        while (candidate.exists()) {
            candidate = File(dir, "${stem}_$i$ext")
            i++
        }
        return candidate
    }

    private fun toShareableUri(file: File): Uri {
        val authority = "$packageName.fileprovider"
        return try {
            FileProvider.getUriForFile(this, authority, file)
        } catch (_: IllegalArgumentException) {
            val outDir = File(cacheDir, "shared_outgoing").apply { mkdirs() }
            val staged = File(outDir, file.name)
            file.copyTo(staged, overwrite = true)
            FileProvider.getUriForFile(this, authority, staged)
        }
    }

    private fun guessMimeType(file: File): String {
        val ext = file.extension.lowercase()
        if (ext.isNotEmpty()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)?.let { return it }
        }
        return "*/*"
    }

    private fun shareFiles(paths: List<String>): Boolean {
        val uris = ArrayList<Uri>()
        var singleMime = "*/*"
        for (path in paths) {
            val file = File(path)
            if (!file.exists() || !file.isFile) continue
            uris.add(toShareableUri(file))
            singleMime = guessMimeType(file)
        }
        if (uris.isEmpty()) return false

        return try {
            val intent = if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).apply {
                    type = singleMime
                    putExtra(Intent.EXTRA_STREAM, uris[0])
                    clipData = ClipData.newRawUri("DropDrawer", uris[0])
                }
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = "*/*"
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                    val clip = ClipData.newRawUri("DropDrawer", uris[0])
                    for (i in 1 until uris.size) {
                        clip.addItem(ClipData.Item(uris[i]))
                    }
                    clipData = clip
                }
            }
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(Intent.createChooser(intent, "分享文件"))
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Opens a file in the default app for its type; false if there is none. */
    private fun openFile(path: String): Boolean {
        val file = File(path)
        if (!file.exists() || !file.isFile) return false
        val mime = guessMimeType(file)
        if (mime == "*/*") return false
        return try {
            val uri = toShareableUri(file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                clipData = ClipData.newRawUri("DropDrawer", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun shareText(text: String): Boolean {
        if (text.isBlank()) return false
        return try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
            }
            startActivity(Intent.createChooser(intent, "分享文本"))
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun saveToGallery(path: String): Boolean {
        val file = File(path)
        if (!file.exists() || !file.isFile) return false
        val mime = guessMimeType(file)
        val isVideo = mime.startsWith("video/")
        val collection = if (isVideo) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(MediaStore.MediaColumns.MIME_TYPE, if (mime == "*/*") "image/png" else mime)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val baseDir = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$baseDir/DropDrawer")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val uri = contentResolver.insert(collection, values) ?: return false
        return try {
            contentResolver.openOutputStream(uri)?.use { out ->
                FileInputStream(file).use { input ->
                    input.copyTo(out)
                }
            } ?: return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                contentResolver.update(uri, done, null, null)
            }
            true
        } catch (_: Exception) {
            try {
                contentResolver.delete(uri, null, null)
            } catch (_: Exception) {}
            false
        }
    }

    private fun openExternalUrl(url: String): Boolean {
        if (!url.startsWith("https://") && !url.startsWith("http://")) return false
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            true
        } catch (_: Exception) {
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun installUpdate(path: String): String {
        return try {
            val root = File(cacheDir, "dropdrawer-updates").canonicalFile
            val apk = File(path).canonicalFile
            if (!apk.path.startsWith(root.path + File.separator) || !apk.isFile || apk.extension != "apk") {
                return "unavailable"
            }
            val update = packageManager.getPackageArchiveInfo(apk.path, signingFlags()) ?: return "unavailable"
            if (update.packageName != packageName) return "unavailable"
            val installed = packageManager.getPackageInfo(packageName, signingFlags())
            if (PackageInfoCompat.getLongVersionCode(update) <= PackageInfoCompat.getLongVersionCode(installed)) {
                return "version_too_old"
            }
            // Android refuses an update signed by another key with a bare
            // "App not installed"; say why before opening the installer.
            val updateSigners = signerDigests(update)
            val installedSigners = signerDigests(installed)
            if (updateSigners.isNotEmpty() && installedSigners.isNotEmpty() &&
                updateSigners != installedSigners
            ) {
                return "signature_mismatch"
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                )
                return "permission_required"
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
            startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
            "installing"
        } catch (_: Exception) {
            "unavailable"
        }
    }

    @Suppress("DEPRECATION")
    private fun signingFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }

    /** SHA-256 digests of the certificates that signed [info]; empty if unknown. */
    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        } ?: return emptySet()
        val sha = MessageDigest.getInstance("SHA-256")
        return signatures.map { signature ->
            sha.digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
        }.toSet()
    }

    private fun readClipboard(imagePath: String): Map<String, Any> {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return mapOf("kind" to "empty")
        val clip = cm.primaryClip ?: return mapOf("kind" to "empty")
        if (clip.itemCount <= 0) return mapOf("kind" to "empty")

        val item = clip.getItemAt(0)
        val uri = item.uri
        if (uri != null && imagePath.isNotBlank()) {
            val mime = contentResolver.getType(uri) ?: ""
            if (mime.startsWith("image/")) {
                try {
                    val dest = File(imagePath)
                    dest.parentFile?.mkdirs()
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(dest).use { output ->
                            input.copyTo(output)
                        }
                    }
                    if (dest.exists() && dest.length() > 0) {
                        return mapOf("kind" to "image", "paths" to listOf(dest.absolutePath))
                    }
                } catch (_: Exception) {}
            }
        }
        val text = item.coerceToText(this)?.toString()
        if (!text.isNullOrBlank()) {
            return mapOf("kind" to "text", "text" to text)
        }
        return mapOf("kind" to "empty")
    }
}
