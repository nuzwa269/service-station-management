package pk.servicestation.sms_gateway

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Sends SMS from this phone's SIM for the gateway app (TASK-005). "send" answers null when the
/// network accepted every part, or an error text.
class MainActivity : FlutterActivity() {
    private val channelName = "pk.servicestation/sms"
    private val permissionRequest = 7001
    private var pendingPermission: MethodChannel.Result? = null
    private var counter = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(hasPermission())
                "requestPermission" -> {
                    if (hasPermission()) result.success(true) else {
                        pendingPermission = result
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.SEND_SMS), permissionRequest)
                    }
                }
                "deviceName" -> result.success("${Build.MANUFACTURER} ${Build.MODEL}")
                "send" -> {
                    val phone = call.argument<String>("phone") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    if (!hasPermission()) result.success("No SMS permission") else send(phone, body, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermission() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permissionRequest) {
            pendingPermission?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingPermission = null
        }
    }

    @Suppress("DEPRECATION")
    private fun send(phone: String, body: String, result: MethodChannel.Result) {
        val sms: SmsManager = if (Build.VERSION.SDK_INT >= 31) getSystemService(SmsManager::class.java) else SmsManager.getDefault()
        val parts = sms.divideMessage(body)
        val action = "pk.servicestation.SMS_SENT_${++counter}"
        var waiting = parts.size
        var error: String? = null
        var answered = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (resultCode != Activity.RESULT_OK && error == null) error = when (resultCode) {
                    SmsManager.RESULT_ERROR_NO_SERVICE -> "No signal"
                    SmsManager.RESULT_ERROR_RADIO_OFF -> "Airplane mode"
                    SmsManager.RESULT_ERROR_NULL_PDU -> "Message error"
                    else -> "SIM refused ($resultCode) — check balance or SMS bundle"
                }
                waiting--
                if (waiting <= 0 && !answered) {
                    answered = true
                    try { unregisterReceiver(this) } catch (_: Exception) {}
                    result.success(error)
                }
            }
        }
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(receiver, filter)
        val flags = PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
        val intents = ArrayList<PendingIntent>()
        for (i in parts.indices) {
            intents.add(PendingIntent.getBroadcast(this, counter * 100 + i, Intent(action).setPackage(packageName), flags))
        }
        try {
            if (parts.size == 1) sms.sendTextMessage(phone, null, body, intents[0], null)
            else sms.sendMultipartTextMessage(phone, null, parts, intents, null)
        } catch (e: Exception) {
            try { unregisterReceiver(receiver) } catch (_: Exception) {}
            if (!answered) { answered = true; result.success(e.message ?: "Send failed") }
        }
    }
}
