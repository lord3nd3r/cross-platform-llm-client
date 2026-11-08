import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Pairing gate in front of llama.cpp's unauthenticated RPC server.
///
/// The native worker binds RPC on 127.0.0.1 only. The public port speaks
/// this preamble and forwards bytes only after the token matches. A wrong
/// token never opens a connection to the RPC server.
///
/// Hello: ASCII "PLM1" + 32 raw token bytes.
/// Accept: ASCII "OK". Anything else, or a timeout, closes the socket.
///
/// Android (ClusterAuthGate.kt) and iOS (LlamaClusterWorker.mm) implement
/// the same bytes. This Dart type is the spec, the master's local relay,
/// and the regression test.
class ClusterAuth {
  static const magic = [0x50, 0x4c, 0x4d, 0x31]; // PLM1
  static const tokenLength = 32;
  static const helloLength = 4 + tokenLength;
  static const ack = [0x4f, 0x4b]; // OK
  static const handshakeTimeout = Duration(seconds: 5);

  static Uint8List hello(Uint8List token) {
    if (token.length != tokenLength) {
      throw ArgumentError('Pairing token must be $tokenLength bytes');
    }
    final out = Uint8List(helloLength);
    out.setRange(0, 4, magic);
    out.setRange(4, helloLength, token);
    return out;
  }

  static bool constantTimeEqual(List<int> a, List<int> b) {
    var diff = a.length ^ b.length;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static bool helloMatches(List<int> message, List<int> token) {
    if (message.length != helloLength || token.length != tokenLength) {
      return false;
    }
    return constantTimeEqual(message, hello(Uint8List.fromList(token)));
  }

  static bool isAck(List<int> bytes) =>
      bytes.length == ack.length && constantTimeEqual(bytes, ack);

  /// base64url without padding. QR codes and manual entry use this form.
  static String encodeToken(Uint8List token) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in token) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 6) {
        bits -= 6;
        out.write(alphabet[(buffer >> bits) & 63]);
      }
    }
    if (bits > 0) {
      out.write(alphabet[(buffer << (6 - bits)) & 63]);
    }
    return out.toString();
  }

  static Uint8List? decodeToken(String? text) {
    if (text == null) return null;
    final cleaned = text.trim();
    if (cleaned.isEmpty) return null;
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final bytes = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final code in cleaned.codeUnits) {
      final value = alphabet.indexOf(String.fromCharCode(code));
      if (value < 0) return null;
      buffer = (buffer << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        bytes.add((buffer >> bits) & 0xff);
      }
    }
    if (bytes.length != tokenLength) return null;
    return Uint8List.fromList(bytes);
  }

  /// TCP connect only. Used for a computer running llama.cpp's own rpc-server,
  /// which does not speak the PrivateLM pairing hello. Sends no bytes.
  static Future<bool> probeTcp({
    required String host,
    required int port,
    Duration timeout = handshakeTimeout,
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// Connects, sends the pairing hello, and returns true only after "OK".
  /// Closes the socket either way. Does not speak llama.cpp RPC.
  static Future<bool> probe({
    required String host,
    required int port,
    required Uint8List token,
    Duration timeout = handshakeTimeout,
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      socket.add(hello(token));
      await socket.flush();
      final reply = await _readExact(socket, ack.length, timeout);
      return isAck(reply);
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  static Future<Uint8List> _readExact(
      Socket socket, int count, Duration timeout) {
    final done = Completer<Uint8List>();
    final buf = BytesBuilder(copy: false);
    late final StreamSubscription<Uint8List> sub;
    sub = socket.listen((chunk) {
      buf.add(chunk);
      if (buf.length >= count && !done.isCompleted) {
        final bytes = buf.takeBytes();
        done.complete(Uint8List.sublistView(bytes, 0, count));
        unawaited(sub.cancel());
      }
    }, onError: (Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
    }, onDone: () {
      if (!done.isCompleted) {
        done.completeError(StateError('connection closed'));
      }
    }, cancelOnError: true);
    return done.future.timeout(timeout, onTimeout: () {
      unawaited(sub.cancel());
      throw TimeoutException('pairing handshake timed out');
    });
  }
}

/// Public listener. Forwards to [internalPort] on loopback only after the
/// pairing hello matches. Used by tests as the behavior the native gates copy.
class ClusterGate {
  ClusterGate._(this._server, this._token, this.internalPort);

  final ServerSocket _server;
  final Uint8List _token;
  final int internalPort;
  int rpcAccepts = 0;

  int get port => _server.port;

  static Future<ClusterGate> bind({
    required Uint8List token,
    required int internalPort,
    InternetAddress? address,
  }) async {
    if (token.length != ClusterAuth.tokenLength) {
      throw ArgumentError('Pairing token must be ${ClusterAuth.tokenLength} bytes');
    }
    final server = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      0,
    );
    final gate = ClusterGate._(server, token, internalPort);
    server.listen(gate._handle);
    return gate;
  }

  Future<void> close() => _server.close();

  Future<void> _handle(Socket client) async {
    final incoming = StreamIterator<Uint8List>(client);
    final buf = BytesBuilder(copy: false);
    Socket? rpc;
    try {
      while (buf.length < ClusterAuth.helloLength) {
        final more = await incoming
            .moveNext()
            .timeout(ClusterAuth.handshakeTimeout);
        if (!more) {
          client.destroy();
          return;
        }
        buf.add(incoming.current);
      }
      final message = buf.takeBytes();
      final hello = message.sublist(0, ClusterAuth.helloLength);
      final extra = message.sublist(ClusterAuth.helloLength);
      if (!ClusterAuth.helloMatches(hello, _token)) {
        await incoming.cancel();
        client.destroy();
        return;
      }
      rpc = await Socket.connect(
        InternetAddress.loopbackIPv4,
        internalPort,
        timeout: ClusterAuth.handshakeTimeout,
      );
      rpcAccepts++;
      client.add(ClusterAuth.ack);
      if (extra.isNotEmpty) rpc.add(extra);
      unawaited(_copyRemaining(incoming, rpc));
      rpc.listen((chunk) {
        client.add(chunk);
      }, onDone: () {
        client.destroy();
        rpc?.destroy();
      }, onError: (_, __) {
        client.destroy();
        rpc?.destroy();
      });
    } catch (_) {
      client.destroy();
      rpc?.destroy();
    }
  }

  Future<void> _copyRemaining(StreamIterator<Uint8List> incoming, Socket rpc) async {
    try {
      while (await incoming.moveNext()) {
        rpc.add(incoming.current);
      }
    } catch (_) {
      rpc.destroy();
    }
  }
}

/// Local side of a master connection. llama.cpp connects here with no
/// knowledge of the token; this relay presents the token to the worker and
/// then copies bytes both ways.
class ClusterRelay {
  ClusterRelay._(this._server);

  final ServerSocket _server;
  int get port => _server.port;

  static Future<ClusterRelay> start({
    required String host,
    required int port,
    required Uint8List token,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final relay = ClusterRelay._(server);
    server.listen((client) {
      unawaited(_bridge(client, host, port, token));
    });
    return relay;
  }

  static Future<void> _bridge(
      Socket client, String host, int port, Uint8List token) async {
    Socket? remote;
    try {
      remote = await Socket.connect(host, port, timeout: ClusterAuth.handshakeTimeout);
      remote.add(ClusterAuth.hello(token));
      await remote.flush();
      final incoming = StreamIterator<Uint8List>(remote);
      final buf = BytesBuilder(copy: false);
      while (buf.length < ClusterAuth.ack.length) {
        final more = await incoming
            .moveNext()
            .timeout(ClusterAuth.handshakeTimeout);
        if (!more) {
          client.destroy();
          remote.destroy();
          return;
        }
        buf.add(incoming.current);
      }
      final message = buf.takeBytes();
      final ack = message.sublist(0, ClusterAuth.ack.length);
      final extra = message.sublist(ClusterAuth.ack.length);
      if (!ClusterAuth.isAck(ack)) {
        await incoming.cancel();
        client.destroy();
        remote.destroy();
        return;
      }
      if (extra.isNotEmpty) client.add(extra);
      unawaited(() async {
        try {
          while (await incoming.moveNext()) {
            client.add(incoming.current);
          }
        } catch (_) {
          client.destroy();
        }
      }());
      client.listen((chunk) => remote?.add(chunk), onDone: () {
        remote?.destroy();
        client.destroy();
      }, onError: (_, __) {
        remote?.destroy();
        client.destroy();
      });
    } catch (_) {
      client.destroy();
      remote?.destroy();
    }
  }

  Future<void> close() => _server.close();
}
