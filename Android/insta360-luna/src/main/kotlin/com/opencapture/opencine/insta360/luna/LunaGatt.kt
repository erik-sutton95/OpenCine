package com.opencapture.opencine.insta360.luna

import android.annotation.SuppressLint
import android.bluetooth.*
import android.content.Context
import android.os.Build
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import java.util.UUID

@SuppressLint("MissingPermission")
internal class LunaGatt(private val context: Context) {
    companion object {
        val SERVICE: UUID = UUID.fromString("0000be80-0000-1000-8000-00805f9b34fb")
        val WRITE: UUID = UUID.fromString("0000be81-0000-1000-8000-00805f9b34fb")
        val NOTIFY: UUID = UUID.fromString("0000be82-0000-1000-8000-00805f9b34fb")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
    private var gatt: BluetoothGatt? = null
    private var writer: BluetoothGattCharacteristic? = null
    private val connected = CompletableDeferred<Unit>()
    private val discovered = CompletableDeferred<Unit>()
    private val configuredMtu = CompletableDeferred<Int>()
    private val subscribed = CompletableDeferred<Unit>()
    @Volatile private var writeDone: CompletableDeferred<Unit>? = null
    private var mtu = 23
    val channel = LunaChannel(::write)
    private fun result(future: CompletableDeferred<Unit>, status: Int) { if (status == BluetoothGatt.GATT_SUCCESS) future.complete(Unit) else future.completeExceptionally(IllegalStateException("Bluetooth operation failed ($status)")) }
    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, state: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS && state == BluetoothProfile.STATE_CONNECTED) connected.complete(Unit)
            else if (state == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                val error = IllegalStateException("Camera Bluetooth disconnected ($status)")
                connected.completeExceptionally(error); discovered.completeExceptionally(error); subscribed.completeExceptionally(error); writeDone?.completeExceptionally(error); channel.fail(error)
            }
        }
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = result(discovered, status)
        override fun onMtuChanged(g: BluetoothGatt, value: Int, status: Int) { configuredMtu.complete(if (status == BluetoothGatt.GATT_SUCCESS) value else 23) }
        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) = result(subscribed, status)
        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) { writeDone?.let { result(it, status) } }
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) { if (characteristic.uuid == NOTIFY) channel.receive(value) }
        @Deprecated("Pre Android 13 callback")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) { if (Build.VERSION.SDK_INT < 33 && characteristic.uuid == NOTIFY) channel.receive(characteristic.value ?: ByteArray(0)) }
    }
    suspend fun connect(device: BluetoothDevice) {
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        withTimeout(20_000) { connected.await() }
        val current = checkNotNull(gatt)
        check(current.discoverServices()) { "Cannot discover camera Bluetooth services" }
        withTimeout(15_000) { discovered.await() }
        val service = checkNotNull(current.getService(SERVICE)) { "Camera BE80 service unavailable" }
        writer = checkNotNull(service.getCharacteristic(WRITE))
        val notify = checkNotNull(service.getCharacteristic(NOTIFY))
        check(writer!!.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0)
        check(notify.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0)
        if (current.requestMtu(515)) mtu = withTimeout(10_000) { configuredMtu.await() }
        check(current.setCharacteristicNotification(notify, true))
        val descriptor = checkNotNull(notify.getDescriptor(CCCD))
        if (Build.VERSION.SDK_INT >= 33) check(current.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS)
        else { descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; check(current.writeDescriptor(descriptor)) }
        withTimeout(10_000) { subscribed.await() }
    }
    private suspend fun write(packet: ByteArray) {
        val current = checkNotNull(gatt); val characteristic = checkNotNull(writer)
        val chunkSize = minOf(206, (mtu - 3).coerceAtLeast(20))
        for (offset in packet.indices step chunkSize) {
            val chunk = packet.copyOfRange(offset, minOf(offset + chunkSize, packet.size))
            val future = CompletableDeferred<Unit>(); writeDone = future
            try {
                if (Build.VERSION.SDK_INT >= 33) check(current.writeCharacteristic(characteristic, chunk, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS)
                else { characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT; characteristic.value = chunk; check(current.writeCharacteristic(characteristic)) }
                withTimeout(10_000) { future.await() }
            } finally { writeDone = null }
        }
    }
    fun close() { channel.close(); runCatching { gatt?.disconnect() }; gatt?.close(); gatt = null; writer = null }
}
