/// Same order as the mobile detector so stored indexes stay valid.
enum SocFamily {
  apple,
  snapdragon,
  mediatek,
  exynos,
  googleTensor,
  unisoc,
  rockchip,
  hisilicon,
  unknown,
}

extension SocFamilyExt on SocFamily {
  String get displayName => 'Unknown';
  String get recommendedQuant => 'Q4_K_M (universal default)';
  String? get quantWarning => null;
}

/// Web device info — no RAM detection, use generous defaults.
Future<Map<String, dynamic>> getDeviceInfo() async {
  return {
    'totalRamGB': 8.0,
    'availableRamGB': 4.0,
    'isTensorSoC': 0.0,
    'socFamily': 8, // unknown
    'socHardware': '',
  };
}
