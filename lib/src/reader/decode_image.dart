import 'dart:typed_data';
import 'dart:ui' as ui;

/// The size to decode a source of `width` x `height` at: null for a side
/// left to the codec (the source's own, or kept in proportion).
typedef DecodeSize = ({int? width, int? height}) Function(int width, int height);

/// Decodes [bytes] to one image: an encoded file (JPEG, PNG, WebP...), or,
/// given [raw], pixels of that size in [format]. [size] picks the size to
/// decode at from the source's; without it the source's own size is kept.
///
/// Returns the image and the source's width. The buffer, descriptor and
/// codec are freed whatever happens, so a page that fails part-way leaks
/// nothing native.
Future<(ui.Image, int)> decodeImage(
  Uint8List bytes, {
  ({int width, int height})? raw,
  ui.PixelFormat format = ui.PixelFormat.bgra8888,
  DecodeSize? size,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = raw == null
        ? await ui.ImageDescriptor.encoded(buffer)
        : ui.ImageDescriptor.raw(buffer, width: raw.width, height: raw.height, pixelFormat: format);
    final want = size?.call(descriptor.width, descriptor.height);
    codec = await descriptor.instantiateCodec(targetWidth: want?.width, targetHeight: want?.height);
    return ((await codec.getNextFrame()).image, descriptor.width);
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
