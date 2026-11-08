import 'dart:io';

import 'package:flutter/material.dart';

Widget localFileImage(String path) {
  return Image.file(
    File(path),
    fit: BoxFit.cover,
    gaplessPlayback: true,
    errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
  );
}
