package com.carriez.flutter_hbb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import ffi.FFI

/**
 * DABLIU-DESK: mantem o app vivo em segundo plano (notificacao fixa) ate o
 * usuario tocar em "Encerrar". Sem isso o Android (MIUI principalmente) mata
 * o processo e a sessao cai quando o app sai da tela.
 */
class KeepAliveService : Service() {
    companion object {
        private const val TAG = "KeepAliveService"
        private const val CANAL = "dabliu_ativo"
        private const val NOTIF_ID = 7301
        private const val ACAO_ENCERRAR = "com.carriez.flutter_hbb.ENCERRAR"

        fun iniciar(ctx: Context) {
            val intent = Intent(ctx, KeepAliveService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(intent)
                } else {
                    ctx.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "nao iniciou: $e")
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACAO_ENCERRAR) {
            try {
                FFI.closeAllSessions()
            } catch (e: Exception) {
                Log.e(TAG, "closeAllSessions: $e")
            }
            stopForeground(true)
            stopSelf()
            android.os.Process.killProcess(android.os.Process.myPid())
            return START_NOT_STICKY
        }
        val notificacao = montarNotificacao()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, notificacao, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, notificacao)
        }
        return START_NOT_STICKY
    }

    private fun montarNotificacao(): Notification {
        val flagsPi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val abrir = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flagsPi
        )
        val encerrar = PendingIntent.getService(
            this, 1,
            Intent(this, KeepAliveService::class.java).setAction(ACAO_ENCERRAR),
            flagsPi
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val gerente = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            gerente.createNotificationChannel(
                NotificationChannel(CANAL, "DABLIU DESK ativo", NotificationManager.IMPORTANCE_LOW)
            )
            Notification.Builder(this, CANAL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        @Suppress("DEPRECATION")
        val acaoEncerrar = Notification.Action.Builder(0, "Encerrar", encerrar).build()
        return builder
            .setSmallIcon(R.mipmap.ic_stat_logo)
            .setContentTitle("DABLIU DESK ativo")
            .setContentText("Continua aberto em segundo plano. Toque para abrir.")
            .setContentIntent(abrir)
            .setOngoing(true)
            .addAction(acaoEncerrar)
            .build()
    }
}
