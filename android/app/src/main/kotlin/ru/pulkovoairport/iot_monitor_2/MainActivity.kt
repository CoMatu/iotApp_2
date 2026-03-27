package ru.pulkovoairport.iot_monitor_2

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private val channelName = "iot_monitor_2/android_ble_bond"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureBond" -> {
                        val deviceId = call.argument<String>("deviceId")
                        val timeoutMs = call.argument<Int>("timeoutMs") ?: 20000
                        if (deviceId.isNullOrBlank()) {
                            result.error("bad_args", "deviceId is required", null)
                            return@setMethodCallHandler
                        }
                        ensureBond(deviceId, timeoutMs, result)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun ensureBond(deviceId: String, timeoutMs: Int, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.BLUETOOTH_CONNECT
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            result.error("no_permission", "BLUETOOTH_CONNECT permission is missing", null)
            return
        }

        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = manager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
        if (adapter == null || !adapter.isEnabled) {
            result.error("bt_unavailable", "Bluetooth adapter is unavailable", null)
            return
        }

        val device = try {
            adapter.getRemoteDevice(deviceId)
        } catch (_: IllegalArgumentException) {
            null
        }
        if (device == null) {
            result.error("bad_device", "Invalid bluetooth device id: $deviceId", null)
            return
        }

        if (device.bondState == BluetoothDevice.BOND_BONDED) {
            result.success(true)
            return
        }

        val appContext = applicationContext
        val mainHandler = Handler(Looper.getMainLooper())
        var completed = false

        lateinit var receiver: BroadcastReceiver
        fun completeOnce(ok: Boolean, err: String?) {
            if (completed) return
            completed = true
            try {
                appContext.unregisterReceiver(receiver)
            } catch (_: Exception) {
            }
            if (ok) {
                result.success(true)
            } else {
                result.error("bond_failed", err ?: "Failed to create bond", null)
            }
        }

        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
                val changedDevice = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                if (changedDevice?.address?.equals(device.address, ignoreCase = true) != true) return

                val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
                val prev = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR)

                if (state == BluetoothDevice.BOND_BONDED) {
                    completeOnce(true, null)
                } else if (state == BluetoothDevice.BOND_NONE && prev == BluetoothDevice.BOND_BONDING) {
                    completeOnce(false, "System pairing rejected or failed")
                }
            }
        }

        appContext.registerReceiver(receiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
        mainHandler.postDelayed({
            if (!completed) {
                completeOnce(false, "System pairing timed out")
            }
        }, timeoutMs.toLong())

        val started = try {
            device.createBond()
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
        if (!started) {
            completeOnce(false, "Unable to start Android system pairing")
        }
    }
}
