package com.ztransfer.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.ztransfer.MainActivity
import com.ztransfer.R

/**
 * 无线相机连接期间的前台服务。
 *
 * PTP 会话和心跳仍由 CameraViewModel 管理；本服务只把“正在连接外部相机”明确告诉系统，
 * 避免无线会话退到后台且尚未开始传输时，进程被降为 empty/cached 后过早回收。
 */
class CameraSessionService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            foregroundReady = true
            if (stopRequested) stopSelf()
        } catch (e: Exception) {
            foregroundReady = false
            if (com.ztransfer.BuildConfig.DEBUG) {
                android.util.Log.w(
                    "ZTransfer",
                    "CameraSessionService startForeground failed: " +
                        "${e.javaClass.simpleName}: ${e.message}",
                )
            }
            stopSelf()
        }
        // 相机连接和任务队列都只存在于当前进程；进程真被杀后重启空服务没有意义。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        foregroundReady = false
        super.onDestroy()
    }

    private fun createChannel() {
        val localized = com.ztransfer.AppLocale.wrap(this)
        val channel = NotificationChannel(
            CHANNEL_ID,
            localized.getString(R.string.camera_session_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply { setShowBadge(false) }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val contentIntent = android.app.PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        val localized = com.ztransfer.AppLocale.wrap(this)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(localized.getString(R.string.camera_session_notification_title))
            .setContentText(localized.getString(R.string.camera_session_notification_text))
            .setSmallIcon(R.drawable.ic_stat_transfer)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(contentIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "camera_session_channel"
        private const val NOTIFICATION_ID = 1002
        @Volatile private var foregroundReady = false
        @Volatile private var stopRequested = false

        fun start(context: Context) {
            stopRequested = false
            try {
                context.startForegroundService(Intent(context, CameraSessionService::class.java))
            } catch (e: Exception) {
                foregroundReady = false
                if (com.ztransfer.BuildConfig.DEBUG) {
                    android.util.Log.w(
                        "ZTransfer",
                        "CameraSessionService start failed: " +
                            "${e.javaClass.simpleName}: ${e.message}",
                    )
                }
            }
        }

        fun stop(context: Context) {
            stopRequested = true
            // 与 TransferService 相同：若 startForegroundService 刚发出，必须让服务先完成
            // startForeground，再由 onStartCommand 读取 stopRequested 后退出，避免系统杀进程。
            if (foregroundReady) {
                runCatching {
                    context.stopService(Intent(context, CameraSessionService::class.java))
                }
            }
        }
    }
}
