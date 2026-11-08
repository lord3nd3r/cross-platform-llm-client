package com.write4me.llama_flutter_android

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.Process
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import android.util.Base64
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Runs this phone as a cluster worker. llama.cpp RPC listens on loopback
 * only. A pairing gate on the public port forwards traffic after the
 * 32-byte token from this device's QR code matches.
 *
 * Lives in its own process (":cluster") because ggml's server loop can't be
 * stopped; stopping the worker ends the process. It reports its state to the
 * app through [statusFile] (JSON), and by whether the process is alive.
 */
class ClusterWorkerService : Service() {
    private var nsdManager: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    @Volatile private var running = false
    @Volatile private var gatePeer: String? = null
    private var gate: ClusterAuthGate? = null
    private var ramMb = 0L
    private var bandwidth = 0.0
    private var pairingToken = ""

    companion object {
        private const val TAG = "ClusterWorker"
        const val ACTION_STOP = "com.write4me.llama_flutter_android.STOP_CLUSTER_WORKER"
        const val EXTRA_PORT = "port"
        const val EXTRA_THREADS = "threads"
        const val DEFAULT_PORT = 50052
        const val SERVICE_TYPE = "_privatelm._tcp."
        const val PROCESS_SUFFIX = ":cluster"
        private const val CHANNEL_ID = "ClusterWorkerChannel"
        private const val NOTIFICATION_ID = 2

        fun statusFile(context: Context) = File(context.filesDir, "cluster_worker_status.json")

        /** Stable pairing secret. Not advertised on mDNS. */
        @Synchronized
        fun pairingToken(context: Context): String {
            val file = File(context.filesDir, "cluster_worker_token")
            file.takeIf { it.exists() }?.readText()?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
            val raw = ClusterAuthGate.newToken()
            val encoded = Base64.encodeToString(raw, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            file.writeText(encoded)
            file.setReadable(false, false)
            file.setReadable(true, true)
            return encoded
        }

        /**
         * This device's lasting worker ID, so a master can find it again when
         * its IP address changes (another Wi-Fi network, a hotspot, DHCP).
         */
        @Synchronized
        fun workerId(context: Context): String {
            // A file, not SharedPreferences: the app and the worker run in two
            // processes and must agree on one ID.
            val file = File(context.filesDir, "cluster_worker_id")
            file.takeIf { it.exists() }?.readText()?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
            val id = java.util.UUID.randomUUID().toString()
            file.writeText(id)
            return id
        }

        fun readStatus(context: Context): JSONObject =
            statusFile(context).takeIf { it.exists() }
                ?.let { runCatching { JSONObject(it.readText()) }.getOrNull() }
                ?: JSONObject().put("state", "stopped")

        fun availableRamMb(context: Context): Long {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val info = ActivityManager.MemoryInfo()
            am.getMemoryInfo(info)
            return info.availMem / (1024 * 1024)
        }
    }

    /** Bound by the app (see ClusterChannel) only to share its priority. */
    override fun onBind(intent: Intent?): IBinder = android.os.Binder()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            shutdown()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, buildNotification("Starting…"))
        if (running) return START_NOT_STICKY

        running = true
        val port = intent?.getIntExtra(EXTRA_PORT, DEFAULT_PORT) ?: DEFAULT_PORT
        val threads = intent?.getIntExtra(EXTRA_THREADS, 0)?.takeIf { it > 0 }
            ?: ClusterNative.fastCoreCount()
        acquireLocks()
        writeStatus("starting")

        val cacheDir = File(filesDir, "cluster_cache").apply { mkdirs() }
        Thread({
            // Measure before serving: free RAM and memory speed tell the
            // master how much to give this phone and how fast it runs.
            ramMb = availableRamMb(this)
            bandwidth = ClusterNative.nativeMemBandwidth(threads)
            Log.i(TAG, "Worker: $threads threads, ${ramMb} MB free, %.1f GB/s".format(bandwidth))
            val tokenText = pairingToken(this)
            pairingToken = tokenText
            val token = Base64.decode(tokenText, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            val internalPort = port + 1
            if (token.size != 32) {
                writeStatus("error", error = "Pairing secret is invalid")
                shutdown()
                return@Thread
            }
            gate = ClusterAuthGate(port, internalPort, token) { peer ->
                gatePeer = peer
                ClusterNative.nativeSetWorkerPeer(peer)
            }.also { it.start() }
            Thread({
                val error = ClusterNative.nativeServe(
                    applicationInfo.nativeLibraryDir,
                    "127.0.0.1:$internalPort",
                    cacheDir.absolutePath,
                    threads.toLong()
                )
                Log.e(TAG, "Worker exited: $error")
                writeStatus("error", error = error ?: "Worker stopped")
                shutdown()
            }, "cluster-rpc").start()
            if (!waitForLoopback(internalPort)) {
                writeStatus("error", error = "Local RPC server did not start")
                shutdown()
                return@Thread
            }
            advertise(port)
            writeStatus("running")
            startStatusLoop()
        }, "cluster-worker").start()
        return START_NOT_STICKY
    }

    /** Every 2 s: which master is connected and what this worker holds. */
    private fun startStatusLoop() {
        Thread({
            var lastText = ""
            while (running) {
                val peer = gatePeer ?: ClusterNative.nativeWorkerPeer()?.takeUnless {
                    it == "127.0.0.1" || it == "0.0.0.0"
                }
                val held = residentMb()
                writeStatus("running", peer = peer, heldMb = held)
                val text = if (peer != null) {
                    "Sharing with master $peer · holding %.1f GB".format(held / 1024.0)
                } else {
                    "Ready · waiting for a master"
                }
                if (text != lastText) {
                    getSystemService(NotificationManager::class.java)
                        .notify(NOTIFICATION_ID, buildNotification(text))
                    lastText = text
                }
                Thread.sleep(2000)
            }
        }, "cluster-status").apply { isDaemon = true }.start()
    }

    /**
     * Whether Android is throttling this process: Samsung moves heavy
     * background work into an "abnormal" cpuset (slow cores only) and the
     * background cpu group. Measured on an S24: the worker lost its four
     * fastest cores and every token waited on it.
     */
    private fun isThrottled(): Boolean = runCatching {
        File("/proc/self/cgroup").readLines().any {
            it.endsWith("/abnormal") || it.endsWith("cpu:/background") || it.endsWith("cpuset:/background")
        }
    }.getOrDefault(false)

    private fun writeStatus(state: String, error: String? = null, peer: String? = null, heldMb: Long = 0) {
        val json = JSONObject()
            .put("state", state)
            .put("ramMb", ramMb)
            .put("bandwidth", bandwidth)
            .put("heldMb", heldMb)
            .put("throttled", isThrottled())
            .put("token", pairingToken)
        if (error != null) json.put("error", error)
        if (peer != null) json.put("peer", peer)
        statusFile(this).writeText(json.toString())
    }

    /** This process's resident memory: mostly the model layers it holds. */
    private fun residentMb(): Long = File("/proc/self/status").readLines()
        .firstOrNull { it.startsWith("VmRSS:") }
        ?.filter { it.isDigit() }?.toLongOrNull()?.div(1024) ?: 0L

    /** Advertises this worker over NSD (mDNS) with what a master needs to plan. */
    private fun advertise(port: Int) {
        val info = NsdServiceInfo().apply {
            serviceName = "PrivateLM ${Build.MODEL}"
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("ram", ramMb.toString())
            setAttribute("bw", "%.1f".format(java.util.Locale.US, bandwidth))
            setAttribute("model", Build.MODEL)
            setAttribute("v", "rpc8")
            setAttribute("id", workerId(this@ClusterWorkerService))
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "Advertised as ${info.serviceName}")
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
                Log.e(TAG, "NSD registration failed ($code); pair by QR code instead")
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager
        nsdManager?.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        registration = listener
    }

    private fun acquireLocks() {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PrivateLM:ClusterWorker")
            .apply { acquire() }
        // Keep Wi-Fi out of power save: a sleeping radio adds latency to every token.
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        wifiLock = wifi.createWifiLock(mode, "PrivateLM:ClusterWorker").apply { acquire() }
    }

    private fun waitForLoopback(port: Int): Boolean {
        val deadline = System.currentTimeMillis() + 8000
        while (System.currentTimeMillis() < deadline) {
            try {
                Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 200) }
                return true
            } catch (_: Exception) {
                Thread.sleep(50)
            }
        }
        return false
    }

    private fun shutdown() {
        running = false
        gate?.stop()
        gate = null
        try {
            registration?.let { nsdManager?.unregisterService(it) }
        } catch (e: IllegalArgumentException) {
            // Never registered.
        }
        registration = null
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock?.takeIf { it.isHeld }?.release()
        if (readStatus(this).optString("state") != "error") writeStatus("stopped")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        // The native server thread can't be stopped any other way.
        Process.killProcess(Process.myPid())
    }

    private fun buildNotification(text: String) = NotificationCompat.Builder(this, ensureChannel())
        .setSmallIcon(android.R.drawable.ic_dialog_info)
        .setContentTitle("Phone cluster: worker")
        .setContentText(text)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .addAction(
            0, "Stop",
            PendingIntent.getService(
                this, 0,
                Intent(this, ClusterWorkerService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE
            )
        )
        .build()

    private fun ensureChannel(): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Phone cluster worker", NotificationManager.IMPORTANCE_LOW
            ).apply { setSound(null, null) }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
        return CHANNEL_ID
    }
}
