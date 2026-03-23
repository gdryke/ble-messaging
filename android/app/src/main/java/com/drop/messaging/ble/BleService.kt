package com.drop.messaging.ble

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.drop.messaging.DropApplication
import com.drop.messaging.MainActivity
import com.drop.messaging.R
import com.drop.messaging.data.DropRepository

/**
 * Foreground service that keeps BLE scanning and advertising alive in the background.
 */
class BleService : Service() {

    companion object {
        private const val TAG = "BleService"
        private const val NOTIFICATION_ID = 1
    }

    private lateinit var bleManager: BleManager

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "BleService created")

        val repository = DropRepository()
        bleManager = BleManager(this, repository)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "BleService starting")

        val notification = createNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        bleManager.start()

        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(TAG, "BleService destroyed")
        bleManager.stop()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotification(): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, DropApplication.BLE_SERVICE_CHANNEL_ID)
            .setContentTitle(getString(R.string.ble_service_notification_title))
            .setContentText(getString(R.string.ble_service_notification_text))
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }
}
