import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/services/cluster_auth.dart';

void main() {
  test('worker records omit the pairing token', () {
    const worker = ClusterWorker(
      name: 'Pixel',
      host: '10.0.0.8',
      port: 50052,
      token: 'secret-token-value',
      id: 'device-1',
    );
    expect(worker.toMap().containsKey('token'), isFalse);
    expect(worker.isComputer, isFalse);
    const computer = ClusterWorker(
      name: 'laptop',
      host: '10.0.0.9',
      port: 50052,
      kind: ClusterWorker.kindComputer,
    );
    expect(computer.isComputer, isTrue);
    expect(computer.toMap()['kind'], ClusterWorker.kindComputer);
  });

  test('a wrong pairing token never reaches the RPC port', () async {
    final rpc = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var rpcAccepts = 0;
    rpc.listen((socket) {
      rpcAccepts++;
      socket.destroy();
    });
    final token = Uint8List(ClusterAuth.tokenLength);
    for (var i = 0; i < token.length; i++) {
      token[i] = i + 1;
    }
    final gate = await ClusterGate.bind(token: token, internalPort: rpc.port);
    addTearDown(() async {
      await gate.close();
      await rpc.close();
    });

    final bad = await Socket.connect(InternetAddress.loopbackIPv4, gate.port);
    bad.add(Uint8List(ClusterAuth.helloLength));
    await bad.flush();
    await bad.done.timeout(const Duration(seconds: 2), onTimeout: () {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rpcAccepts, 0);

    final good = await Socket.connect(InternetAddress.loopbackIPv4, gate.port);
    good.add(ClusterAuth.hello(token));
    await good.flush();
    final ack = await _read(good, 2);
    expect(String.fromCharCodes(ack), 'OK');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rpcAccepts, 1);
    good.destroy();
  });

  test('a plain computer probe does not send a pairing hello', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = <int>[];
    server.listen((socket) async {
      socket.listen(received.addAll, onDone: socket.destroy);
    });
    addTearDown(server.close);

    final ok = await ClusterAuth.probeTcp(
      host: '127.0.0.1',
      port: server.port,
      timeout: const Duration(seconds: 2),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ok, isTrue);
    expect(received, isEmpty);
  });
}

Future<List<int>> _read(Socket socket, int count) async {
  final out = <int>[];
  await for (final chunk in socket) {
    out.addAll(chunk);
    if (out.length >= count) break;
  }
  return out.take(count).toList();
}
