package com.drop.messaging.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.util.Log
import com.drop.messaging.data.DropRepository

/**
 * Handles BLE advertising to make this device discoverable to nearby Drop peers.
 *
 * Advertises the Drop service UUID with service data containing a Bloom filter
 * of recipient IDs we hold messages for.
 */
@SuppressLint("MissingPermission")
class BleAdvertiser(
    private val context: Context,
    private val bleManager: BleManager
) {
    companion object {
        private const val TAG = "BleAdvertiser"
        private const val BLOOM_FILTER_SIZE = 8
        private const val PROTOCOL_VERSION: Byte = 0x01
        private const val FLAGS_DEFAULT: Byte = 0x00
    }

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val advertiser: BluetoothLeAdvertiser?
        get() = bluetoothManager.adapter?.bluetoothLeAdvertiser

    private var isAdvertising = false

    fun startAdvertising() {
        if (isAdvertising) return

        val leAdvertiser = advertiser
        if (leAdvertiser == null) {
            Log.w(TAG, "BluetoothLeAdvertiser not available")
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_LOW)
            .setConnectable(true)
            .setTimeout(0) // Advertise indefinitely
            .build()

        val serviceData = buildServiceData()

        val data = AdvertiseData.Builder()
            .addServiceUuid(BleManager.SERVICE_PARCEL_UUID)
            .addServiceData(BleManager.SERVICE_PARCEL_UUID, serviceData)
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .build()

        Log.i(TAG, "Starting BLE advertising for Drop service")
        leAdvertiser.startAdvertising(settings, data, advertiseCallback)
    }

    fun stopAdvertising() {
        if (!isAdvertising) return

        Log.i(TAG, "Stopping BLE advertising")
        advertiser?.stopAdvertising(advertiseCallback)
        isAdvertising = false
    }

    /**
     * Rebuilds and restarts advertising with an updated Bloom filter.
     * Call this when the set of pending messages changes.
     */
    fun refreshAdvertisingData() {
        if (!isAdvertising) return
        stopAdvertising()
        startAdvertising()
    }

    /**
     * Builds the service data payload:
     *   [8 bytes Bloom filter][1 byte version][1 byte flags]
     */
    private fun buildServiceData(): ByteArray {
        // TODO: Wire UniFFI bindings — get Bloom filter from Rust core
        val bloomFilter = ByteArray(BLOOM_FILTER_SIZE) // Placeholder: empty Bloom filter
        return bloomFilter + byteArrayOf(PROTOCOL_VERSION, FLAGS_DEFAULT)
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            Log.i(TAG, "BLE advertising started successfully")
            isAdvertising = true
        }

        override fun onStartFailure(errorCode: Int) {
            Log.e(TAG, "BLE advertising failed to start: error $errorCode")
            isAdvertising = false
        }
    }
}
