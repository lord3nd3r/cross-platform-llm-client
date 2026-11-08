package com.write4me.llama_flutter_android

import android.util.Log
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * LAN listener in front of llama.cpp RPC.
 *
 * RPC itself has no authentication and is bound to 127.0.0.1 only.
 * This gate accepts "PLM1" + 32 token bytes and answers "OK" before it
 * opens the loopback connection. A wrong token never touches RPC.
 * Must match lib/services/cluster_auth.dart.
 */
class ClusterAuthGate(
    private val publicPort: Int,
    private val internalPort: Int,
    private val token: ByteArray,
    private val onPeer: (String?) -> Unit,
) {
    @Volatile private var running = false
    private var server: ServerSocket? = null
    private val clients = AtomicInteger(0)

    fun start() {
        check(token.size == TOKEN_LEN) { "Pairing token must be $TOKEN_LEN bytes" }
        running = true
        thread(name = "cluster-gate") {
            val socket = ServerSocket()
            socket.reuseAddress = true
            socket.bind(InetSocketAddress(publicPort))
            server = socket
            Log.i(TAG, "Pairing gate listening on 0.0.0.0:$publicPort -> 127.0.0.1:$internalPort")
            while (running) {
                val client = try {
                    socket.accept()
                } catch (_: Exception) {
                    break
                }
                thread(name = "cluster-gate-client") { handle(client) }
            }
        }
    }

    fun stop() {
        running = false
        try {
            server?.close()
        } catch (_: Exception) {
        }
    }

    private fun handle(client: Socket) {
        var rpc: Socket? = null
        var counted = false
        try {
            client.soTimeout = HANDSHAKE_MS
            val hello = ByteArray(4 + TOKEN_LEN)
            if (!readFully(client.getInputStream(), hello)) {
                client.close()
                return
            }
            if (!helloMatches(hello, token)) {
                client.close()
                return
            }
            rpc = Socket()
            rpc.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), internalPort), HANDSHAKE_MS)
            client.soTimeout = 0
            rpc.soTimeout = 0
            client.tcpNoDelay = true
            rpc.tcpNoDelay = true
            client.getOutputStream().write(ACK)
            client.getOutputStream().flush()
            val peer = client.inetAddress?.hostAddress
            if (clients.incrementAndGet() == 1) onPeer(peer)
            counted = true
            val remote = rpc
            val a = thread(name = "cluster-gate-up") {
                copy(client.getInputStream(), remote.getOutputStream())
            }
            val b = thread(name = "cluster-gate-down") {
                copy(remote.getInputStream(), client.getOutputStream())
            }
            a.join()
            b.join()
        } catch (e: Exception) {
            Log.i(TAG, "Pairing connection closed: ${e.javaClass.simpleName}")
        } finally {
            if (counted && clients.decrementAndGet() == 0) onPeer(null)
            try { rpc?.close() } catch (_: Exception) {}
            try { client.close() } catch (_: Exception) {}
        }
    }

    companion object {
        private const val TAG = "ClusterAuthGate"
        private const val TOKEN_LEN = 32
        private const val HANDSHAKE_MS = 5000
        private val MAGIC = byteArrayOf(0x50, 0x4c, 0x4d, 0x31) // PLM1
        private val ACK = byteArrayOf(0x4f, 0x4b) // OK

        fun newToken(): ByteArray {
            val token = ByteArray(TOKEN_LEN)
            SecureRandom().nextBytes(token)
            return token
        }

        fun helloMatches(hello: ByteArray, token: ByteArray): Boolean {
            if (hello.size != 4 + TOKEN_LEN || token.size != TOKEN_LEN) return false
            var diff = 0
            for (i in MAGIC.indices) diff = diff or (hello[i].toInt() xor MAGIC[i].toInt())
            for (i in token.indices) diff = diff or (hello[i + 4].toInt() xor token[i].toInt())
            return diff == 0
        }

        private fun readFully(input: InputStream, buf: ByteArray): Boolean {
            var off = 0
            while (off < buf.size) {
                val n = input.read(buf, off, buf.size - off)
                if (n < 0) return false
                off += n
            }
            return true
        }

        private fun copy(input: InputStream, output: OutputStream) {
            try {
                val buf = ByteArray(16 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    output.write(buf, 0, n)
                    output.flush()
                }
            } catch (_: Exception) {
            } finally {
                try { output.close() } catch (_: Exception) {}
            }
        }

    }
}
