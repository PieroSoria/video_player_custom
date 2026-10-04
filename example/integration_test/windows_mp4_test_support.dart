import 'dart:typed_data';

/// Stretches the bundled MP4's timestamps for paused seek tests without
/// changing the compressed samples, chunk offsets, or adding another asset.
/// Audio is not played from this fixture because its codec sample rate stays
/// unchanged while its presentation timestamps are stretched.
Uint8List stretchMp4Timeline(Uint8List source, {int factor = 4}) {
  if (factor < 1) throw ArgumentError.value(factor, 'factor');
  final result = Uint8List.fromList(source);
  final bytes = ByteData.sublistView(result);
  var durationHeaders = 0;

  void visit(int start, int end) {
    var offset = start;
    while (offset < end) {
      if (end - offset < 8) throw const FormatException('Truncated MP4 box');
      var size = bytes.getUint32(offset);
      final type = String.fromCharCodes(result.sublist(offset + 4, offset + 8));
      var headerSize = 8;
      if (size == 1) {
        if (end - offset < 16) {
          throw const FormatException('Truncated extended MP4 box');
        }
        size = bytes.getUint64(offset + 8);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < headerSize || size > end - offset) {
        throw const FormatException('Invalid MP4 box size');
      }
      final payload = offset + headerSize;
      final boxEnd = offset + size;
      if (type == 'moov' || type == 'trak' || type == 'mdia') {
        visit(payload, boxEnd);
      } else if (type == 'mvhd' || type == 'mdhd') {
        if (payload >= boxEnd || result[payload] > 1) {
          throw const FormatException('Unsupported MP4 duration header');
        }
        final scaleOffset = payload + (result[payload] == 1 ? 20 : 12);
        if (scaleOffset + 4 > boxEnd) {
          throw const FormatException('Truncated MP4 timescale');
        }
        final scale = bytes.getUint32(scaleOffset);
        if (scale < factor || scale % factor != 0) {
          throw const FormatException('MP4 timescale cannot be stretched');
        }
        bytes.setUint32(scaleOffset, scale ~/ factor);
        durationHeaders++;
      }
      offset = boxEnd;
    }
  }

  visit(0, result.length);
  if (durationHeaders < 2) {
    throw const FormatException('Missing MP4 movie or media header');
  }
  return result;
}
