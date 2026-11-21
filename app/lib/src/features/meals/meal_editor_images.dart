import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../media/managed_media_store.dart';

/// Decode pixels and encode a fresh PNG. Original bytes (including EXIF, GPS
/// and other metadata) are never used as an upload fallback.
Future<Uint8List> encodeMealUpload(
  String reference, {
  required ManagedMediaStore media,
}) async {
  final file = await media.resolve(reference);
  if (file == null) {
    throw FileSystemException('Managed photo is unavailable', reference);
  }
  final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
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
