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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        acquireWakeLock()
        // 被系统杀死后不自动重建：任务队列在进程内存中，重建无意义。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
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
        private const val MAX_WAKELOCK_MS = 60L * 60L * 1000L // 兜底超时，防止异常时唤醒锁泄露

        fun start(context: Context) {
            val intent = Intent(context, TransferService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TransferService::class.java))
        }
    }
}
