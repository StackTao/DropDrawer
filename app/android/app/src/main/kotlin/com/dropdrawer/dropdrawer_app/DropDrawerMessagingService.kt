package com.dropdrawer.dropdrawer_app

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives drawer notifications. While the app is in the background Android
 * shows them on its own; this service only handles messages that arrive while
 * the app is open (the server rarely sends those, since the app is connected).
 */
class DropDrawerMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        // The app sends the current token with its next config refresh.
    }

    // The permission is checked right below for the Android versions that need it.
    @SuppressLint("MissingPermission")
    override fun onMessageReceived(message: RemoteMessage) {
        val notification = message.notification ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        PushRegistrar.ensureChannel(this)
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val built = NotificationCompat.Builder(this, PushRegistrar.CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(notification.title)
            .setContentText(notification.body)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        val tag = message.data["item_id"] ?: message.messageId
        NotificationManagerCompat.from(this).notify(tag, 0, built)
    }
}
