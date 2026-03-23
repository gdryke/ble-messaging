package com.drop.messaging.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import com.drop.messaging.data.DropRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Coordinates BLE scanning, advertising, and GATT client/server connections.
 */
@SuppressLint("MissingPermission")
class BleManager(
    private val context: Context,
    private val repository: DropRepository
) {
    companion object {
        private const val TAG = "BleManager"

        val SERVICE_UUID: UUID = UUID.fromString("D7A00001-E28C-4B8E-8C3F-4A77C4D2F5B1")
        val INBOX_WRITE_UUID: UUID = UUID.fromString("D7A00002-E28C-4B8E-8C3F-4A77C4D2F5B1")
        val OUTBOX_NOTIFY_UUID: UUID = UUID.fromString("D7A00003-E28C-4B8E-8C3F-4A77C4D2F5B1")
        val HANDSHAKE_UUID: UUID = UUID.fromString("D7A00004-E28C-4B8E-8C3F-4A77C4D2F5B1")
        val ACK_UUID: UUID = UUID.fromString("D7A00005-E28C-4B8E-8C3F-4A77C4D2F5B1")

        val SERVICE_PARCEL_UUID: ParcelUuid = ParcelUuid(SERVICE_UUID)

        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter

    private val scanner = BleScanner(context, this)
    private val advertiser = BleAdvertiser(context, this)

    private var gattServer: BluetoothGattServer? = null
    private val activeConnections = mutableMapOf<String, BluetoothGatt>()

    private val _connectedPeers = MutableStateFlow<Set<String>>(emptySet())
    val connectedPeers: StateFlow<Set<String>> = _connectedPeers.asStateFlow()

    fun start() {
        Log.i(TAG, "Starting BLE manager")
        setupGattServer()
        scanner.startScanning()
        advertiser.startAdvertising()
    }

    fun stop() {
        Log.i(TAG, "Stopping BLE manager")
        scanner.stopScanning()
        advertiser.stopAdvertising()
        teardownGattServer()
        activeConnections.values.forEach { it.close() }
        activeConnections.clear()
    }

    // region GATT Server

    private fun setupGattServer() {
        gattServer = bluetoothManager.openGattServer(context, gattServerCallback)?.also { server ->
            val service = BluetoothGattService(
                SERVICE_UUID,
                BluetoothGattService.SERVICE_TYPE_PRIMARY
            )

            val inboxChar = BluetoothGattCharacteristic(
                INBOX_WRITE_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )

            val outboxChar = BluetoothGattCharacteristic(
                OUTBOX_NOTIFY_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            ).apply {
                addDescriptor(BluetoothGattDescriptor(
                    CCCD_UUID,
                    BluetoothGattDescriptor.PERMISSION_WRITE or BluetoothGattDescriptor.PERMISSION_READ
                ))
            }

            val handshakeChar = BluetoothGattCharacteristic(
                HANDSHAKE_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE
            )

            val ackChar = BluetoothGattCharacteristic(
                ACK_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE
            ).apply {
                addDescriptor(BluetoothGattDescriptor(
                    CCCD_UUID,
                    BluetoothGattDescriptor.PERMISSION_WRITE or BluetoothGattDescriptor.PERMISSION_READ
                ))
            }

            service.addCharacteristic(inboxChar)
            service.addCharacteristic(outboxChar)
            service.addCharacteristic(handshakeChar)
            service.addCharacteristic(ackChar)

            server.addService(service)
            Log.i(TAG, "GATT server started with Drop service")
        }
    }

    private fun teardownGattServer() {
        gattServer?.close()
        gattServer = null
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            val address = device.address
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "Peer connected to GATT server: $address")
                    _connectedPeers.value = _connectedPeers.value + address
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "Peer disconnected from GATT server: $address")
                    _connectedPeers.value = _connectedPeers.value - address
                }
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            when (characteristic.uuid) {
                HANDSHAKE_UUID -> {
                    // TODO: Wire UniFFI bindings — return handshake payload from Rust core
                    val handshakeData = repository.getHandshakePayload()
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_SUCCESS, offset,
                        handshakeData.copyOfRange(offset, handshakeData.size)
                    )
                }
                else -> {
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_FAILURE, 0, null
                    )
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            val data = value ?: return

            when (characteristic.uuid) {
                INBOX_WRITE_UUID -> {
                    Log.d(TAG, "Received message data from ${device.address} (${data.size} bytes)")
                    scope.launch {
                        // TODO: Wire UniFFI bindings — pass received data to Rust core
                        repository.handleIncomingData(device.address, data)
                    }
                }
                HANDSHAKE_UUID -> {
                    Log.d(TAG, "Received handshake from ${device.address}")
                    scope.launch {
                        // TODO: Wire UniFFI bindings — process handshake via Rust core
                        repository.handleHandshake(device.address, data)
                    }
                }
                ACK_UUID -> {
                    Log.d(TAG, "Received ACK from ${device.address}")
                    scope.launch {
                        repository.handleAck(device.address, data)
                    }
                }
            }

            if (responseNeeded) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null
                )
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            // Handle CCCD subscription for Outbox Notify and ACK characteristics
            if (descriptor.uuid == CCCD_UUID) {
                Log.d(TAG, "CCCD write from ${device.address} for ${descriptor.characteristic.uuid}")
            }
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null
                )
            }
        }
    }

    // endregion

    // region GATT Client (outbound connections to discovered peers)

    fun onPeerDiscovered(device: BluetoothDevice) {
        val address = device.address
        if (activeConnections.containsKey(address)) {
            Log.d(TAG, "Already connected to $address, skipping")
            return
        }

        Log.i(TAG, "Initiating GATT connection to discovered peer: $address")
        device.connectGatt(context, false, gattClientCallback, BluetoothDevice.TRANSPORT_LE)
    }

    private val gattClientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "Connected to GATT server at $address, discovering services...")
                    activeConnections[address] = gatt
                    _connectedPeers.value = _connectedPeers.value + address
                    gatt.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "Disconnected from $address")
                    activeConnections.remove(address)
                    _connectedPeers.value = _connectedPeers.value - address
                    gatt.close()
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "Service discovery failed for ${gatt.device.address}: $status")
                gatt.disconnect()
                return
            }

            val service = gatt.getService(SERVICE_UUID)
            if (service == null) {
                Log.w(TAG, "Drop service not found on ${gatt.device.address}")
                gatt.disconnect()
                return
            }

            Log.i(TAG, "Drop service found on ${gatt.device.address}, starting handshake")
            initiateHandshake(gatt, service)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) return

            when (characteristic.uuid) {
                HANDSHAKE_UUID -> {
                    scope.launch {
                        // TODO: Wire UniFFI bindings — process peer's handshake response
                        repository.handleHandshake(gatt.device.address, value)
                        beginMessageExchange(gatt)
                    }
                }
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.d(TAG, "Write to ${characteristic.uuid} succeeded on ${gatt.device.address}")
            } else {
                Log.w(TAG, "Write to ${characteristic.uuid} failed on ${gatt.device.address}: $status")
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            when (characteristic.uuid) {
                OUTBOX_NOTIFY_UUID -> {
                    scope.launch {
                        repository.handleIncomingData(gatt.device.address, value)
                    }
                }
                ACK_UUID -> {
                    scope.launch {
                        repository.handleAck(gatt.device.address, value)
                    }
                }
            }
        }
    }

    private fun initiateHandshake(gatt: BluetoothGatt, service: BluetoothGattService) {
        val handshakeChar = service.getCharacteristic(HANDSHAKE_UUID) ?: return

        // Write our handshake payload, then read the peer's
        // TODO: Wire UniFFI bindings — get handshake payload from Rust core
        val payload = repository.getHandshakePayload()
        handshakeChar.value = payload
        gatt.writeCharacteristic(handshakeChar)
    }

    private fun beginMessageExchange(gatt: BluetoothGatt) {
        val service = gatt.getService(SERVICE_UUID) ?: return

        // Subscribe to outbox notifications from peer
        val outboxChar = service.getCharacteristic(OUTBOX_NOTIFY_UUID)
        if (outboxChar != null) {
            gatt.setCharacteristicNotification(outboxChar, true)
            val cccd = outboxChar.getDescriptor(CCCD_UUID)
            cccd?.let {
                it.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                gatt.writeDescriptor(it)
            }
        }

        // Subscribe to ACK notifications
        val ackChar = service.getCharacteristic(ACK_UUID)
        if (ackChar != null) {
            gatt.setCharacteristicNotification(ackChar, true)
            val cccd = ackChar.getDescriptor(CCCD_UUID)
            cccd?.let {
                it.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                gatt.writeDescriptor(it)
            }
        }

        // Send pending messages
        scope.launch {
            sendPendingMessages(gatt)
        }
    }

    private suspend fun sendPendingMessages(gatt: BluetoothGatt) {
        val service = gatt.getService(SERVICE_UUID) ?: return
        val inboxChar = service.getCharacteristic(INBOX_WRITE_UUID) ?: return
        val peerId = gatt.device.address

        // TODO: Wire UniFFI bindings — get pending messages from Rust core
        val messages = repository.getPendingMessages(peerId)
        for (message in messages) {
            inboxChar.value = message
            gatt.writeCharacteristic(inboxChar)
            // Note: In production, wait for onCharacteristicWrite callback before sending next
        }
    }

    // endregion
}
