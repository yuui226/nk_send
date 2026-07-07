package com.nikon.transfer.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.net.wifi.WifiManager
import androidx.core.app.NotificationCompat
import com.nikon.transfer.MainActivity
import com.nikon.transfer.R

/**
 * 前台服务：在传输期间保持进程存活并持有部分唤醒锁，避免锁屏/切后台时被系统回收，
 * 导致大文件（NEF/视频）传输中断。传输本身仍由 ViewModel 的协程驱动，本服务只负责
 * 生命周期保活与通知展示。
 *
 * 通过 [start]/[stop] 在传输开始/结束时启停，天然幂等（重复 start 只刷新通知）。
 */
class TransferService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
            acquireWakeLock()
            acquireWifiLock()
        } catch (e: Exception) {
            // 某些系统状态下 startForeground 可能被拒绝；此时放弃保活但不崩溃，
            // 传输仍会在前台继续进行。
            stopSelf()
        }
        // 被系统杀死后不自动重建：任务队列在进程内存中，重建无意义。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        releaseWifiLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG).apply {
            setReferenceCounted(false)
            acquire(MAX_WAKELOCK_MS)
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        } finally {
            wakeLock = null
        }
    }

    /**
     * 传输期间持有高性能 WifiLock，阻止 Wi-Fi 进入省电模式（省电模式下 Wi-Fi 吞吐会明显下降，
     * 大文件下载速度腰斩）。API 29+ 用低时延模式，更适合本地实时传输；以下用高性能模式。
     * PARTIAL_WAKE_LOCK 只保 CPU 不管 Wi-Fi 无线功耗，二者互补。
     */
    private fun acquireWifiLock() {
        if (wifiLock?.isHeld == true) return
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        wifiLock = wm.createWifiLock(mode, WIFILOCK_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWifiLock() {
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Exception) {
        } finally {
            wifiLock = null
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.transfer_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply { setShowBadge(false) }
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val contentIntent = android.app.PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.transfer_notification_title))
            .setContentText(getString(R.string.transfer_notification_text))
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "transfer_channel"
        private const val NOTIFICATION_ID = 1001
        private const val WAKELOCK_TAG = "NikonTransfer:transfer"
        private const val WIFILOCK_TAG = "NikonTransfer:wifi"
        private const val MAX_WAKELOCK_MS = 60L * 60L * 1000L // 兜底超时，防止异常时唤醒锁泄露

        fun start(context: Context) {
            val intent = Intent(context, TransferService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 12+ 后台启动前台服务会抛 ForegroundServiceStartNotAllowedException，
                // 吞掉以免崩溃；传输在前台时不会触发，后台场景下服务已在运行。
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, TransferService::class.java))
            } catch (_: Exception) {}
        }
    }
}
