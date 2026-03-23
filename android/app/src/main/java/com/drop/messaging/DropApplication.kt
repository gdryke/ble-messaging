package com.drop.messaging

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

class DropApplication : Application() {

    companion object {
        const val BLE_SERVICE_CHANNEL_ID = "drop_ble_service"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val bleChannel = NotificationChannel(
                BLE_SERVICE_CHANNEL_ID,
                getString(R.string.ble_service_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps BLE scanning and advertising active in the background"
                setShowBadge(false)
            }

            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(bleChannel)
        }
    }
}
