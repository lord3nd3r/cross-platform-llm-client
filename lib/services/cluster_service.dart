import 'dart:async';
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/constants.dart';
import '../core/ui.dart';
import 'app_log_service.dart';
import 'cluster_auth.dart' if (dart.library.html) 'cluster_auth_web.dart';
import 'cluster_host.dart';
import 'credential_vault.dart';
import 'hive_service.dart';

/// What this phone does in a phone cluster.
enum ClusterRole {
  off,

  /// Runs the model, with part of it on the workers.
  master,

  /// Lends its processor and memory to a master.
  worker,
}

/// One phone's part of the loaded model.
class ClusterShare {
  final String name;
  final double mb;
  final bool isThisPhone;
  const ClusterShare(this.name, this.mb, {this.isThisPhone = false});
}

/// A phone the master can put layers on, for planning a load.
class _Phone {
  final ClusterWorker? worker; // null: the master itself
  final double capacityMb;
  final double speed; // GB/s
  double assignedMb = 0;
  _Phone(this.worker, this.capacityMb, this.speed);
}

/// Phone cluster: spread a GGUF model across phones on the same Wi-Fi.
/// The master runs the model; workers hold part of its layers.
class ClusterService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  static bool get isSupported => !kIsWeb && (hostIsAndroid || hostIsIOS);

  /// Running a model across workers is Android-only for now; iOS devices
  /// can be workers (their GPU serves a master's layers).
  static bool get canBeMaster => !kIsWeb && hostIsAndroid;

  /// iOS can't stop the worker without closing the app.
  static bool get workerStopsWithApp => !kIsWeb && hostIsIOS;

  /// QR codes a worker shows: privatelm://worker?host=…&port=…
  static const _qrScheme = 'privatelm';

  /// Speed assumed for workers paired before they reported one (GB/s).
  static const _unknownSpeed = 4.0;

  /// A Windows/desktop rpc-server did not measure itself. Laptop DRAM is
  /// usually at least this fast, so it is not left with a scrap of the model.
  static const _computerSpeed = 16.0;

  /// Used when the address is typed without a memory number: a normal
  /// laptop, not a phone. Override it in the add-computer field.
  static const _computerRamMb = 16 * 1024;

  /// Workers the master can use on its next GGUF load.
  final workers = <ClusterWorker>[].obs;

  /// Master mode: use [workers] when loading GGUF models.
  final enabled = false.obs;

  final found = <ClusterWorker>[].obs;
  final isScanning = false.obs;

  /// This phone's worker service.
  final worker = const ClusterWorkerStatus(state: 'stopped').obs;
  final _workerRequested = false.obs;

  /// The API server is running (other devices, e.g. a PC, use the model).
  final serving = false.obs;

  /// This phone's Wi-Fi address, or null when it isn't on Wi-Fi.
  final wifiAddress = RxnString();

  /// How the loaded model is spread across phones; empty when it isn't.
  final split = <ClusterShare>[].obs;

  String deviceName = '';
  double? _localSpeed;
  final List<ClusterRelay> _relays = [];
  final Map<String, String> _relayNames = {};
  late final Future<void> _tokensReady;
  Timer? _statusTimer;

  ClusterRole get role => _workerRequested.value || worker.value.running
      ? ClusterRole.worker
      : enabled.value
          ? ClusterRole.master
          : ClusterRole.off;

  /// "Pixel 8 72% · POCO F1 28%", or null when the model isn't split.
  String? get splitSummary {
    final total = split.fold<double>(0, (a, s) => a + s.mb);
    if (split.length < 2 || total <= 0) return null;
    return split.map((s) => '${s.name} ${(s.mb / total * 100).round()}%').join(' · ');
  }

  @override
  void onInit() {
    super.onInit();
    enabled.value = _hive.getSetting<bool>(AppConstants.keyClusterEnabled) ?? false;
    final saved = _hive.getSetting<List>(AppConstants.keyClusterWorkers) ?? const [];
    workers.assignAll(saved.whereType<Map>().map(ClusterWorker.fromMap));
    _tokensReady = _hydrateTokens();
    if (isSupported) {
      if (hostIsIOS) {
        DeviceInfoPlugin().iosInfo.then((info) => deviceName = info.modelName);
      } else {
        DeviceInfoPlugin().androidInfo.then((info) => deviceName = info.model);
      }
      refreshWorkerStatus().then((_) {
        if (worker.value.running) _watchWorker();
      });
      // A worker runs at full speed only while PrivateLM is on screen (it
      // borrows the app's priority), so keep the screen on while sharing.
      ever<ClusterWorkerStatus>(worker, (_) => _updateKeepScreenOn());
      ever<bool>(serving, (_) => _updateKeepScreenOn());
      refreshWifiAddress();
    }
  }

  @override
  void onClose() {
    _statusTimer?.cancel();
    super.onClose();
  }

  /// Android throttles a phone whose screen is off (slow cores, low CPU
  /// share), so keep it on while this device works for others: as a worker,
  /// or serving the model over the network.
  bool? _screenKeptOn;
  void _updateKeepScreenOn() {
    final s = worker.value;
    final on = s.running || s.starting || serving.value;
    if (on == _screenKeptOn) return;
    _screenKeptOn = on;
    LlamaCluster.setKeepScreenOn(on).catchError((_) {});
  }

  Future<void> setRole(ClusterRole next) async {
    if (next == role) return;
    if (next != ClusterRole.worker && role == ClusterRole.worker) {
      if (workerStopsWithApp) {
        showToast('Still sharing', 'Close PrivateLM to stop sharing this device.');
        return;
      }
      await stopWorker();
    }
    await _setEnabled(next == ClusterRole.master);
    if (next == ClusterRole.worker) await startWorker();
    await refreshWifiAddress();
  }

  // ── Worker ─────────────────────────────────────────────────────────────

  /// What the master scans to add this phone, once the worker is running.
  String? get workerQrData {
    final host = wifiAddress.value;
    final status = worker.value;
    final token = status.token;
    if (host == null || !status.running || token == null || token.isEmpty) {
      return null;
    }
    return Uri(scheme: _qrScheme, host: 'worker', queryParameters: {
      'host': host,
      'port': '${LlamaCluster.defaultPort}',
      'token': token,
      if (deviceName.isNotEmpty) 'name': deviceName,
      if (status.ramMb > 0) 'ram': '${status.ramMb}',
      if (status.bandwidth > 0) 'bw': status.bandwidth.toStringAsFixed(1),
      if (status.id != null) 'id': status.id!,
    }).toString();
  }

  Future<void> startWorker() async {
    if (hostIsAndroid) {
      // Unrestricted battery keeps Android (Samsung especially) from moving
      // the worker to slow cores once it gets busy.
      final status = await LlamaCluster.workerStatus();
      if (!status.batteryUnrestricted) await LlamaCluster.requestBatteryUnrestricted();
    }
    _workerRequested.value = true;
    worker.value = const ClusterWorkerStatus(state: 'starting');
    await LlamaCluster.startWorker();
    _watchWorker();
  }

  Future<void> stopWorker() async {
    _workerRequested.value = false;
    _statusTimer?.cancel();
    await LlamaCluster.stopWorker();
    await Future.delayed(const Duration(milliseconds: 600));
    await refreshWorkerStatus();
  }

  /// Follows the worker service (its own process) while it runs: whether a
  /// master is connected and how much it holds.
  void _watchWorker() {
    _statusTimer?.cancel();
    var checks = 0;
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await refreshWorkerStatus();
      final s = worker.value;
      // Give the service a few seconds to come up before calling it stopped.
      if (!s.running && !s.starting && ++checks > 3) {
        _workerRequested.value = false;
        _statusTimer?.cancel();
      }
    });
  }

  Future<void> refreshWorkerStatus() async {
    try {
      worker.value = await LlamaCluster.workerStatus();
    } catch (e) {
      Get.find<AppLogService>().error('Cluster worker status failed', details: e);
    }
  }

  /// Finds this device's IPv4 address on Wi-Fi (wlan* on Android, en0 on
  /// iOS), if any.
  Future<void> refreshWifiAddress() async {
    try {
      wifiAddress.value = await hostWifiAddress();
    } catch (_) {
      wifiAddress.value = null;
    }
  }

  // ── Master: workers ────────────────────────────────────────────────────

  /// Adds the worker from a scanned QR code. Returns an error message, or
  /// null on success.
  Future<String?> addFromQr(String data) async {
    final uri = Uri.tryParse(data.trim());
    final params = uri?.queryParameters ?? const {};
    final host = params['host'];
    final port = int.tryParse(params['port'] ?? '');
    final token = params['token'];
    if (uri == null || uri.scheme != _qrScheme || host == null || port == null) {
      return 'That isn\'t a PrivateLM worker code';
    }
    if (ClusterAuth.decodeToken(token) == null) {
      return 'That code has no pairing secret. Update PrivateLM on the worker '
          'and scan the new code.';
    }
    return _add(ClusterWorker(
      name: params['name'] ?? host,
      host: host,
      port: port,
      ramMb: int.tryParse(params['ram'] ?? ''),
      bandwidth: double.tryParse(params['bw'] ?? ''),
      model: params['name'],
      id: params['id'],
      token: token,
    ));
  }

  /// Adds a worker by IP and pairing code ("192.168.1.20:50052 <code>").
  /// The code is the one under the worker's QR. An address alone is refused.
  Future<String?> addManual(String input) async {
    final text = input.trim();
    final parts = text.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      return 'Enter the worker IP and its pairing code, from the worker screen.';
    }
    final address = parts.first;
    final token = parts.sublist(1).join();
    if (ClusterAuth.decodeToken(token) == null) {
      return 'That pairing code is not valid.';
    }
    final host = address.contains(':')
        ? address.substring(0, address.lastIndexOf(':'))
        : address;
    final port = address.contains(':')
        ? int.tryParse(address.substring(address.lastIndexOf(':') + 1))
        : LlamaCluster.defaultPort;
    if (host.isEmpty || port == null) return 'Use the form 192.168.1.20:50052 <code>';
    return _add(ClusterWorker(name: host, host: host, port: port, token: token));
  }

  /// Adds a computer running llama.cpp's rpc-server.
  ///
  /// That server has no pairing secret, so this is an explicit address the
  /// user typed, not something found on the network. PrivateLM phones are
  /// never added this way. Optional second field is free memory in GB
  /// (`192.168.1.10:50052 32`).
  Future<String?> addComputer(String input) async {
    final parts = input.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) {
      return 'Enter the computer\'s address, for example 192.168.1.10:50052';
    }
    final address = parts.first;
    final host = address.contains(':')
        ? address.substring(0, address.lastIndexOf(':'))
        : address;
    final port = address.contains(':')
        ? int.tryParse(address.substring(address.lastIndexOf(':') + 1))
        : LlamaCluster.defaultPort;
    if (host.isEmpty || port == null) {
      return 'Use the form 192.168.1.10:50052';
    }
    int? ramMb;
    if (parts.length >= 2) {
      final gb = double.tryParse(parts[1]);
      if (gb == null || gb <= 0 || gb > 1024) {
        return 'Memory should be a number of gigabytes, such as 32';
      }
      ramMb = (gb * 1024).round();
    }
    return _add(ClusterWorker(
      name: host,
      host: host,
      port: port,
      // Blank memory means "a normal laptop", so it actually takes layers.
      ramMb: ramMb ?? _computerRamMb,
      kind: ClusterWorker.kindComputer,
      model: 'Windows laptop',
    ));
  }

  double _workerCapacityMb(ClusterWorker worker) {
    final ram = worker.ramMb ?? (worker.isComputer ? _computerRamMb : 2000);
    return ram * (worker.isComputer ? 0.8 : 0.75);
  }

  double _workerSpeed(ClusterWorker worker) =>
      worker.bandwidth ?? (worker.isComputer ? _computerSpeed : _unknownSpeed);

  /// Nearby discovery does not carry the pairing secret.
  Future<String?> addFound(ClusterWorker w) async {
    if (w.token == null || w.token!.isEmpty) {
      return 'Scan that phone\'s QR code. Finding it on the network does not pair it.';
    }
    return _add(w);
  }

  /// Finds saved workers that no longer answer at their address (they moved
  /// to another Wi-Fi, a hotspot, or got a new IP) by their device ID on
  /// the network, and updates them. Returns the ones still unreachable.
  Future<List<ClusterWorker>> relocateWorkers() async {
    final missing = <ClusterWorker>[];
    final unreachable = <ClusterWorker>[];
    for (final w in workers) {
      if (w.isComputer) {
        if (!await ClusterAuth.probeTcp(host: w.host, port: w.port)) {
          unreachable.add(w);
        }
        continue;
      }
      if (!await _pairedProbe(w)) missing.add(w);
    }
    if (missing.isEmpty) return unreachable;
    final seen = await LlamaCluster.discover();
    var moved = 0;
    for (final w in missing) {
      final match = seen.firstWhereOrNull((s) => w.id != null && s.id == w.id);
      final i = workers.indexWhere((x) => x.endpoint == w.endpoint);
      if (match == null || match.endpoint == w.endpoint || i < 0) {
        unreachable.add(w);
        continue;
      }
      workers[i] = w.movedTo(match.host, match.port);
      moved++;
    }
    if (moved > 0) {
      await _save();
      Get.find<AppLogService>().info('Phone cluster: found $moved worker(s) at a new address');
    }
    return unreachable;
  }

  Future<bool> _pairedProbe(ClusterWorker worker) async {
    final token = ClusterAuth.decodeToken(worker.token);
    if (token == null) return false;
    return ClusterAuth.probe(host: worker.host, port: worker.port, token: token);
  }

  Future<bool> _canReach(ClusterWorker worker) {
    if (worker.isComputer) {
      return ClusterAuth.probeTcp(host: worker.host, port: worker.port);
    }
    return _pairedProbe(worker);
  }

  Future<String?> _add(ClusterWorker worker) async {
    if (worker.isComputer) {
      if (!await ClusterAuth.probeTcp(host: worker.host, port: worker.port)) {
        return 'Can\'t reach ${worker.endpoint}. On the laptop run '
            'rpc-server.exe -H 0.0.0.0 -p ${worker.port} -c, allow it through Windows '
            'Firewall, and use the laptop\'s Wi-Fi IPv4 address.';
      }
    } else {
      final token = ClusterAuth.decodeToken(worker.token);
      if (token == null) {
        return 'This phone has no pairing secret. Scan its QR code.';
      }
      if (!await ClusterAuth.probe(
          host: worker.host, port: worker.port, token: token)) {
        return 'Can\'t pair with ${worker.endpoint}. Check the code, that the phone '
            'is a worker, and that both are on the same Wi-Fi.';
      }
    }
    workers.removeWhere((w) => w.endpoint == worker.endpoint);
    workers.add(worker);
    found.removeWhere((w) => w.endpoint == worker.endpoint);
    await _save();
    return null;
  }

  Future<void> remove(ClusterWorker w) async {
    workers.removeWhere((s) => s.endpoint == w.endpoint);
    await _save();
  }

  bool isAdded(ClusterWorker w) => workers.any((s) => s.endpoint == w.endpoint);

  /// Looks for workers on the Wi-Fi (doesn't work on every router).
  Future<void> scanNearby() async {
    if (isScanning.value) return;
    isScanning.value = true;
    try {
      final list = await LlamaCluster.discover();
      found.assignAll(list.where((w) => !isAdded(w)));
    } finally {
      isScanning.value = false;
    }
  }

  Future<void> _setEnabled(bool value) async {
    enabled.value = value;
    await _hive.setSetting(AppConstants.keyClusterEnabled, value);
  }

  Future<void> _save() async {
    await _hive.setSetting(
        AppConstants.keyClusterWorkers, [for (final w in workers) w.toMap()]);
    if (!Get.isRegistered<CredentialVault>()) return;
    final vault = Get.find<CredentialVault>();
    for (final w in workers) {
      final id = w.id ?? w.endpoint;
      await vault.write(CredentialVault.clusterTokenKey(id), w.token ?? '');
    }
  }

  Future<void> _hydrateTokens() async {
    if (!Get.isRegistered<CredentialVault>()) return;
    final vault = Get.find<CredentialVault>();
    final next = <ClusterWorker>[];
    for (final w in workers) {
      final id = w.id ?? w.endpoint;
      final token = vault.read(CredentialVault.clusterTokenKey(id));
      next.add(token.isEmpty ? w : w.withToken(token));
    }
    workers.assignAll(next);
  }

  Future<void> _closeRelays() async {
    for (final relay in _relays) {
      await relay.close();
    }
    _relays.clear();
    _relayNames.clear();
  }

  // ── Master: loading ────────────────────────────────────────────────────

  /// Plans a GGUF load right before it starts and hands the plan to the
  /// native engine (or turns cluster mode off for it). Returns the number of
  /// workers used; throws with a readable message if the model won't fit
  /// or a worker can't be reached.
  ///
  /// If the model fits on this phone, asks whether to keep it here (faster:
  /// no Wi-Fi in the loop) or share it with the workers anyway. Otherwise
  /// the fastest phones are filled first, up to their free memory: phones
  /// take turns on every token, so the most work belongs on the fastest one,
  /// and phones that aren't needed are left out (one less Wi-Fi hop each).
  Future<int> applyForNextLoad(String modelPath, {String? modelName}) async {
    split.clear();
    if (!isSupported) return 0;
    await _tokensReady;
    await _closeRelays();
    if (!enabled.value || workers.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }

    // Workers that are off or away are left out, not fatal: the model may
    // fit without them.
    final unpaired = workers
        .where((w) => !w.isComputer && ClusterAuth.decodeToken(w.token) == null)
        .toList();
    if (unpaired.isNotEmpty) {
      showToast(
        'Phone cluster',
        'Re-scan the QR code for: ${unpaired.map((w) => w.model ?? w.name).join(', ')}',
      );
    }
    final candidates = workers.where((w) => w.isComputer || !unpaired.contains(w)).toList();
    final offline = <ClusterWorker>[];
    final movedOff = <ClusterWorker>[];
    for (final w in candidates) {
      if (!await _canReach(w)) {
        if (w.isComputer) {
          offline.add(w);
        } else {
          movedOff.add(w);
        }
      }
    }
    if (movedOff.isNotEmpty) {
      final seen = await LlamaCluster.discover();
      var moved = 0;
      for (final w in movedOff) {
        final match = seen.firstWhereOrNull((s) => w.id != null && s.id == w.id);
        final i = workers.indexWhere((x) => x.endpoint == w.endpoint);
        if (match == null || match.endpoint == w.endpoint || i < 0) {
          offline.add(w);
          continue;
        }
        workers[i] = w.movedTo(match.host, match.port);
        moved++;
      }
      if (moved > 0) await _save();
    }
    final available = workers.where((w) {
      if (unpaired.contains(w) || offline.any((o) => o.id == w.id && o.endpoint == w.endpoint)) {
        return false;
      }
      if (w.isComputer) return !offline.any((o) => o.endpoint == w.endpoint);
      return ClusterAuth.decodeToken(w.token) != null &&
          !offline.any((o) => o.endpoint == w.endpoint);
    }).toList();
    if (offline.isNotEmpty) {
      final names = offline.map((w) => w.model ?? w.name).join(', ');
      showToast('Phone cluster', 'Not reachable, loading without: $names');
    }

    await _tokensReady;
    final modelMb = await hostFileLength(modelPath) / (1024 * 1024);
    final needMb = modelMb * 1.1; // + KV cache and working buffers
    _localSpeed ??= await LlamaCluster.benchmark();
    // Free RAM: workers report theirs when they start. The master also runs
    // the app and the KV cache, so it offers less of its own.
    final master = _Phone(null, await LlamaCluster.localFreeRamMb() * 0.7, _localSpeed!);
    final phones = [
      master,
      for (final w in available) _Phone(w, _workerCapacityMb(w), _workerSpeed(w)),
    ];
    final totalMb = phones.fold<double>(0, (a, p) => a + p.capacityMb);
    if (needMb > totalMb) {
      throw Exception('This model (${_gb(modelMb)}) is too big for these '
          '${phones.length} phones: together they have about ${_gb(totalMb)} '
          'free.${offline.isEmpty ? '' : ' Not reachable: ${offline.map((w) => w.model ?? w.name).join(', ')}.'} '
          'Add another worker, close apps on the phones, or pick a '
          'smaller model.');
    }

    if (available.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }
    if (needMb <= master.capacityMb) {
      final share = await _askFitsHere(
          modelName ?? modelPath.split('/').last, modelMb, available.length);
      if (!share) {
        await LlamaCluster.clear();
        return 0;
      }
      _splitBySpeed(phones, needMb);
    } else {
      _fillFastestFirst(phones, needMb);
    }

    final used = phones.where((p) => p.worker != null && p.assignedMb > 0).toList();
    if (used.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }
    try {
      final linked = <ClusterWorker>[];
      final weights = <double>[];
      for (final p in used) {
        final worker = p.worker!;
        if (worker.isComputer) {
          _relayNames[worker.endpoint] = worker.model ?? worker.name;
          linked.add(worker);
          weights.add(p.assignedMb);
          continue;
        }
        final token = ClusterAuth.decodeToken(worker.token);
        if (token == null) continue;
        final relay = await ClusterRelay.start(
          host: worker.host,
          port: worker.port,
          token: token,
        );
        _relays.add(relay);
        final local = worker.movedTo('127.0.0.1', relay.port);
        _relayNames[local.endpoint] = worker.model ?? worker.name;
        linked.add(local);
        weights.add(p.assignedMb);
      }
      if (linked.isEmpty) {
        await LlamaCluster.clear();
        return 0;
      }
      await LlamaCluster.setCluster(
        linked,
        weights: weights,
        localWeight: master.assignedMb,
      );
    } on PlatformException catch (e) {
      throw Exception(
          '${e.message ?? 'A worker is unreachable'}. Turn on Worker on that '
          'phone, or set this phone\'s Phone cluster to Off.');
    }
    return used.length;
  }

  /// Fastest first, each up to its free memory, until the model is placed.
  static void _fillFastestFirst(List<_Phone> phones, double needMb) {
    final bySpeed = [...phones]..sort((a, b) => b.speed.compareTo(a.speed));
    var left = needMb;
    for (final p in bySpeed) {
      p.assignedMb = math.min(p.capacityMb, left);
      left -= p.assignedMb;
    }
  }

  /// Shares in proportion to speed, capped at each phone's free memory
  /// (what a capped phone can't take goes to the others).
  static void _splitBySpeed(List<_Phone> phones, double needMb) {
    var open = [...phones];
    var left = needMb;
    while (open.isNotEmpty && left > 0.5) {
      final speedSum = open.fold<double>(0, (a, p) => a + p.speed);
      final capped = [
        for (final p in open)
          if (p.assignedMb + left * p.speed / speedSum >= p.capacityMb) p,
      ];
      if (capped.isEmpty) {
        for (final p in open) {
          p.assignedMb += left * p.speed / speedSum;
        }
        left = 0;
      } else {
        for (final p in capped) {
          left -= p.capacityMb - p.assignedMb;
          p.assignedMb = p.capacityMb;
        }
        open = open.where((p) => !capped.contains(p)).toList();
      }
    }
  }

  /// LiteRT models can't be split across phones (the cluster is llama.cpp).
  /// When this phone is a master with workers, asks before loading one here
  /// alone. True to go ahead.
  Future<bool> confirmLiteRtRunsHere(String model) async {
    final context = Get.context;
    if (role != ClusterRole.master || workers.isEmpty || context == null) return true;
    final go = await showAppSheet<bool>(
      context,
      title: 'This model can\'t use your workers',
      subtitle: '${model.replaceAll(RegExp(r'\.(litertlm|task)$'), '')} is a LiteRT '
          'model, and only GGUF models can be shared across phones. It will run '
          'on this phone only. To use your workers, load a GGUF model instead.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(ctx, label: 'Cancel', onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    );
    return go == true;
  }

  /// "Fits on this phone" sheet. True to share with workers anyway.
  Future<bool> _askFitsHere(String model, double modelMb, int workerCount) async {
    final context = Get.context;
    if (context == null) return false;
    final share = await showAppSheet<bool>(
      context,
      title: 'This model fits on this phone',
      subtitle: '${model.replaceAll(RegExp(r'\.gguf$'), '')} needs about '
          '${_gb(modelMb)}, and this phone has room for it. Running it here '
          'is faster, because sharing sends every word over Wi-Fi. Share it '
          'to free up memory on this phone.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label: 'Share with $workerCount worker${workerCount == 1 ? '' : 's'}',
            onTap: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return share == true;
  }

  /// Reads where the model actually went after a cluster load. Workers'
  /// shares come from llama.cpp's per-device weight buffers; this phone's
  /// share is the rest of the file, because its own buffers overlap (the
  /// mapped file and the CPU's repacked copy of the same weights).
  Future<void> refreshSplit(String modelPath) async {
    final buffers = await LlamaCluster.lastLoadBuffers();
    final remote = <String, double>{};
    for (final b in buffers) {
      final open = b.name.indexOf('[');
      if (open < 0) continue;
      final endpoint = b.name.substring(open + 1, b.name.lastIndexOf(']'));
      final named = _relayNames[endpoint] ??
          workers.firstWhereOrNull((w) => w.endpoint == endpoint)?.model;
      final name = named ?? endpoint;
      remote[name] = (remote[name] ?? 0) + b.mb;
    }
    final fileMb = await hostFileLength(modelPath) / (1024 * 1024);
    final remoteMb = remote.values.fold<double>(0, (a, b) => a + b);
    split.assignAll([
      ClusterShare(deviceName.isEmpty ? 'This phone' : deviceName,
          math.max(0, fileMb - remoteMb), isThisPhone: true),
      for (final e in remote.entries) ClusterShare(e.key, e.value),
    ]);
  }

  void clearSplit() => split.clear();

  static String _gb(double mb) => '${(mb / 1024).toStringAsFixed(1)} GB';
}
