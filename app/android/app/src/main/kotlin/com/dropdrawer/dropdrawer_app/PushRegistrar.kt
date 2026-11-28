package com.dropdrawer.dropdrawer_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging

/**
 * Firebase Cloud Messaging without a built-in Firebase project: the server sends
 * its project's options in `/api/client/config`, so each deployment can use its
 * own. The options are kept so Firebase can start again when a notification
 * wakes the process before Flutter runs.
 */
object PushRegistrar {
    /** Must match `push::ANDROID_CHANNEL_ID` on the server. */
    const val CHANNEL_ID = "drawer_items"
    private const val PREFS = "dropdrawer_push"
    private const val TAG = "DropDrawerPush"
    private val KEYS = listOf("project_id", "application_id", "api_key", "sender_id")

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.push_channel_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = context.getString(R.string.push_channel_description)
        }
        manager.createNotificationChannel(channel)
    }

    /** Called from `Application.onCreate`; does nothing until the server enabled push. */
    fun initializeStored(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = KEYS.associateWith { prefs.getString(it, null).orEmpty() }
        if (stored.values.any { it.isEmpty() }) return
        initialize(context, stored)
    }

    /** Initializes Firebase with `options` and reports this device's token (or null). */
    fun configure(context: Context, options: Map<String, String>, onToken: (String?) -> Unit) {
        if (KEYS.any { options[it].isNullOrBlank() } || !initialize(context, options)) {
            onToken(null)
            return
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().apply {
            KEYS.forEach { putString(it, options[it]) }
            apply()
        }
        try {
            FirebaseMessaging.getInstance().isAutoInitEnabled = true
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                onToken(if (task.isSuccessful) task.result else null)
            }
        } catch (e: Exception) {
            // No Google Play services on this device.
            Log.w(TAG, "FCM token unavailable", e)
            onToken(null)
        }
    }

    /** Sign-out: forget the token so this account stops reaching the phone. */
    fun disable(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        try {
            if (FirebaseApp.getApps(context).isNotEmpty()) {
                FirebaseMessaging.getInstance().isAutoInitEnabled = false
                FirebaseMessaging.getInstance().deleteToken()
            }
        } catch (e: Exception) {
            Log.w(TAG, "cannot delete the FCM token", e)
        }
    }

    private fun initialize(context: Context, options: Map<String, String>): Boolean {
        return try {
            val existing = FirebaseApp.getApps(context).firstOrNull { it.name == FirebaseApp.DEFAULT_APP_NAME }
            if (existing != null) {
                val same = existing.options.projectId == options["project_id"] &&
                    existing.options.applicationId == options["application_id"]
                if (same) return true
                // Signed in to a server that uses another Firebase project.
                existing.delete()
            }
            val firebaseOptions = FirebaseOptions.Builder()
                .setProjectId(options.getValue("project_id"))
                .setApplicationId(options.getValue("application_id"))
                .setApiKey(options.getValue("api_key"))
                .setGcmSenderId(options.getValue("sender_id"))
                .build()
            FirebaseApp.initializeApp(context.applicationContext, firebaseOptions)
            true
        } catch (e: Exception) {
            Log.w(TAG, "cannot initialize Firebase", e)
            false
        }
    }
}
