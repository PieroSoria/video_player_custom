/// A finite HLS playlist and the resources needed to play it offline.
///
/// Kept separate from browser storage so malformed and live playlists can be
/// rejected before committing any cache entry.
class WebHlsManifest {
  WebHlsManifest(this.text, this.baseUri) {
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('Not an HLS playlist');
    }
    final List<String> lines = text.split('\n');
    final bool media = lines.any(
      (String line) =>
          line.trim().startsWith('#EXTINF:') ||
          line.trim().startsWith('#EXT-X-TARGETDURATION:'),
    );
    if (media && !lines.any((String line) => line.trim() == '#EXT-X-ENDLIST')) {
      throw const FormatException('Live HLS playlists cannot be cached');
    }
    if (lines.any(
      (String line) =>
          line.startsWith('#EXT-X-DEFINE:') ||
          line.startsWith('#EXT-X-CONTENT-STEERING:'),
    )) {
      throw UnsupportedError(
        'HLS variables and content steering are not cached',
      );
    }
    bool nextPlaylist = false;
    bool hasVariant = false;
    for (final String raw in lines) {
      final String line = raw.trim();
      if (line.isEmpty) {
        continue;
      }
      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-KEY:') ||
            line.startsWith('#EXT-X-SESSION-KEY:')) {
          if (line.contains('KEYFORMAT=') &&
              !line.contains('KEYFORMAT="identity"')) {
            throw UnsupportedError('DRM HLS keys cannot be cached');
          }
          if (!line.contains('METHOD=AES-128') &&
              !line.contains('METHOD=NONE')) {
            throw UnsupportedError('Only identity AES-128 HLS keys are cached');
          }
        }
        final bool playlist =
            line.startsWith('#EXT-X-MEDIA:') ||
            line.startsWith('#EXT-X-I-FRAME-STREAM-INF:');
        if (_uriAttributeStart.allMatches(raw).length !=
            _uriAttribute.allMatches(raw).length) {
          throw const FormatException(
            'HLS URI attributes must be nonempty and quoted',
          );
        }
        for (final RegExpMatch match in _uriAttribute.allMatches(raw)) {
          references.add((uri: _resolve(match.group(2)!), playlist: playlist));
        }
        if (line.startsWith('#EXT-X-STREAM-INF:')) {
          nextPlaylist = true;
          hasVariant = true;
        } else if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
          hasVariant = true;
        }
      } else {
        references.add((uri: _resolve(line), playlist: nextPlaylist));
        nextPlaylist = false;
      }
    }
    if ((!media && !hasVariant) || references.isEmpty || nextPlaylist) {
      throw const FormatException(
        'HLS playlist has no complete media presentation',
      );
    }
  }

  final String text;
  final Uri baseUri;
  final List<({String uri, bool playlist})> references =
      <({String uri, bool playlist})>[];
  static final RegExp _uriAttribute = RegExp(r'(^|[:,])\s*URI="([^"]+)"');
  static final RegExp _uriAttributeStart = RegExp(r'(^|[:,])\s*URI=');

  String _resolve(String value) {
    final Uri uri = baseUri.resolve(value);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw UnsupportedError('HLS cache resources must use HTTP or HTTPS');
    }
    return uri.toString();
  }

  /// Rewrites both segment lines and URI attributes to completed local blobs.
  String rewrite(Map<String, String> sources) {
    return text
        .split('\n')
        .map((String raw) {
          final String line = raw.trim();
          if (line.isEmpty) {
            return raw;
          }
          if (!line.startsWith('#')) {
            return sources[_resolve(line)] ??
                (throw StateError('Missing cached HLS resource: $line'));
          }
          return raw.replaceAllMapped(_uriAttribute, (Match match) {
            final String uri = _resolve(match.group(2)!);
            final String? source = sources[uri];
            if (source == null) {
              throw StateError('Missing cached HLS resource: $uri');
            }
            return '${match.group(1)}URI="$source"';
          });
        })
        .join('\n');
  }
}
