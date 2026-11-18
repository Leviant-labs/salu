import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

Future<String> storeMealImage(XFile picked, String id) async {
  final support = await getApplicationSupportDirectory();
  final directory = await Directory(
    '${support.path}${Platform.pathSeparator}meal-images',
  ).create(recursive: true);
  final filename = 'photo-${base64Url.encode(utf8.encode(id))}.image';
  final file = File('${directory.path}${Platform.pathSeparator}$filename');
  await file.create(exclusive: true);
  try {
    await picked.saveTo(file.path);
    return file.path;
  } catch (_) {
    await discardMealImage(file.path);
    rethrow;
  }
}

Future<void> discardMealImage(String path) async {
  try {
    await File(path).delete();
  } on FileSystemException {
    // The draft may already have been cleaned up.
  }
}

/// Decode pixels and encode a fresh PNG. Original bytes (including EXIF, GPS
/// and other metadata) are never used as an upload fallback.
Future<Uint8List> encodeMealUpload(String path) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      for (final limit in [1280, 900]) {
        final wide = descriptor.width >= descriptor.height;
        final longest = wide ? descriptor.width : descriptor.height;
        final codec = await descriptor.instantiateCodec(
          targetWidth: wide && longest > limit ? limit : null,
          targetHeight: !wide && longest > limit ? limit : null,
        );
        try {
          final frame = await codec.getNextFrame();
          try {
            final png = await frame.image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (png != null && png.lengthInBytes <= 4 * 1024 * 1024) {
              return png.buffer.asUint8List(
                png.offsetInBytes,
                png.lengthInBytes,
              );
            }
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      }
      throw const FormatException('Could not prepare a photo for upload');
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}
