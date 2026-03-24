package com.drop.messaging.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.util.Log

/**
 * Handles BLE scanning for nearby Drop peers.
 *
 * Filters for the Drop service UUID and checks advertised Bloom filter data
 * to determine if the peer has messages for our device.
 */
@SuppressLint("MissingPermission")
class BleScanner(
    private val context: Context,
    private val bleManager: BleManager
) {
    companion object {
        private const val TAG = "BleScanner"
    }

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val scanner: BluetoothLeScanner?
        get() = bluetoothManager.adapter?.bluetoothLeScanner

    private var isScanning = false

    private val scanFilters = listOf(
        ScanFilter.Builder()
            .setServiceUuid(BleManager.SERVICE_PARCEL_UUID)
            .build()
    )

    private val scanSettings = ScanSettings.Builder()
        .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
        .setReportDelay(0)
        .build()

    fun startScanning() {
        if (isScanning) return

        val leScanner = scanner
        if (leScanner == null) {
            Log.w(TAG, "BluetoothLeScanner not available")
            return
        }

        Log.i(TAG, "Starting BLE scan for Drop peers")
        leScanner.startScan(scanFilters, scanSettings, scanCallback)
        isScanning = true
    }

    fun stopScanning() {
        if (!isScanning) return

        Log.i(TAG, "Stopping BLE scan")
        scanner?.stopScan(scanCallback)
        isScanning = false
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            handleScanResult(result)
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            results.forEach { handleScanResult(it) }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "BLE scan failed with error code: $errorCode")
            isScanning = false
        }
    }

    private fun handleScanResult(result: ScanResult) {
        val serviceData = result.scanRecord
            ?.getServiceData(BleManager.SERVICE_PARCEL_UUID)

        if (serviceData == null || serviceData.size < 10) {
            // Still a Drop peer, but no valid service data — connect anyway for handshake
            Log.d(TAG, "Discovered Drop peer ${result.device.address} (no service data)")
            bleManager.onPeerDiscovered(result.device)
            return
        }

        // Service data layout: [8 bytes Bloom filter][1 byte version][1 byte flags]
        val bloomFilter = serviceData.copyOfRange(0, 8)
        val version = serviceData[8]
        val flags = serviceData[9]

        Log.d(TAG, "Discovered Drop peer ${result.device.address} " +
                "(version=$version, flags=$flags, rssi=${result.rssi})")

        // TODO: Wire UniFFI bindings — check Bloom filter against our device ID via Rust core
        if (checkBloomFilterMatch(bloomFilter)) {
            Log.i(TAG, "Bloom filter match for ${result.device.address} — may have messages for us")
            bleManager.onPeerDiscovered(result.device)
        }
    }

    /**
     * Check if the advertised Bloom filter indicates the peer has messages for us.
     * This is a placeholder — the actual check will be done by the Rust core.
     */
    private fun checkBloomFilterMatch(bloomFilter: ByteArray): Boolean {
        // TODO: Wire UniFFI bindings — delegate to Rust core's Bloom filter check
        // For now, always return true to connect to any discovered peer
        return true
    }
}
