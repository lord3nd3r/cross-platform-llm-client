import 'dart:io';

bool get hostIsAndroid => Platform.isAndroid;
bool get hostIsIOS => Platform.isIOS;

Future<int> hostFileLength(String path) => File(path).length();

/// Wi-Fi IPv4 (wlan* on Android, en0 on iOS), if the radio is up.
Future<String?> hostWifiAddress() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  final wifi = interfaces.where((i) => i.name.startsWith('wlan') || i.name == 'en0');
  if (wifi.isEmpty || wifi.first.addresses.isEmpty) return null;
  return wifi.first.addresses.first.address;
}
