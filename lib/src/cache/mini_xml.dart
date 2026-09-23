/// Minimal, dependency-free XML reader and writer used by the manifest
/// downloaders. It understands the subset found in DASH (`.mpd`) and Smooth
/// Streaming (`Manifest`) control documents: elements, attributes, comments,
/// processing instructions, CDATA and entity references. Text content is
/// collected but only used for elements like `<BaseURL>`.
library;

class XmlNode {
  XmlNode(this.tag, this.attributes) : children = <XmlNode>[];

  /// Local tag name (namespace prefixes are stripped).
  String tag;

  /// Local attribute names -> values (prefixes stripped, entities unescaped).
  Map<String, String> attributes;

  /// Child elements in document order.
  List<XmlNode> children;

  /// Raw character data between child tags (entities unescaped).
  final StringBuffer textBuffer = StringBuffer();

  /// Trimmed text content of this element.
  String get text => textBuffer.toString().trim();
}

/// Parses [source] into a single root [XmlNode], or `null` when no element is
/// present. Text is captured into each node's [XmlNode.textBuffer]; comments,
/// PIs, doctypes and CDATA sections are skipped.
XmlNode? parseXml(String source) {
  XmlNode? root;
  final List<XmlNode> stack = <XmlNode>[];
  int i = 0;
  while (i < source.length) {
    final int lt = source.indexOf('<', i);
    if (lt < 0) {
      break;
    }
    if (lt > i && stack.isNotEmpty) {
      stack.last.textBuffer.write(source.substring(i, lt));
    }
    i = lt + 1;
    if (i >= source.length) {
      break;
    }
    if (source.startsWith('!--', i)) {
      final int end = source.indexOf('-->', i);
      i = end < 0 ? source.length : end + 3;
      continue;
    }
    final int gt = _findTagEnd(source, i);
    if (gt < 0) {
      break;
    }
    final String content = source.substring(i, gt);
    i = gt + 1;
    if (content.startsWith('?') || content.startsWith('!')) {
      continue;
    }
    if (content.startsWith('/')) {
      if (stack.isNotEmpty) {
        stack.removeLast();
      }
      continue;
    }
    final bool selfClosing = content.endsWith('/');
    final String body = selfClosing
        ? content.substring(0, content.length - 1).trim()
        : content.trim();
    final int nameEnd = _indexOfWhitespace(body);
    final String tag =
        _stripNamespace(nameEnd < 0 ? body : body.substring(0, nameEnd));
    final XmlNode node = XmlNode(
      tag,
      _parseAttributes(nameEnd < 0 ? '' : body.substring(nameEnd)),
    );
    if (stack.isNotEmpty) {
      stack.last.children.add(node);
    } else {
      root ??= node;
    }
    if (!selfClosing) {
      stack.add(node);
    }
  }
  if (stack.isNotEmpty) {
    // Unterminated tag at EOF (malformed input): return what we have so far.
    while (stack.length > 1) {
      stack.removeLast();
    }
    root ??= stack.first;
  }
  return root;
}

/// Serializes [node] back to XML text. Elements whose tag (local name) is in
/// [skipTags] are omitted at any depth.
String serializeXml(XmlNode node, {Set<String> skipTags = const <String>{}}) {
  if (skipTags.contains(node.tag)) {
    return '';
  }
  final StringBuffer out = StringBuffer();
  out.write('<${node.tag}${xmlAttributes(node)}');
  if (node.children.isEmpty) {
    out.write('/>');
    return out.toString();
  }
  out.write('>');
  for (final XmlNode child in node.children) {
    out.write(serializeXml(child, skipTags: skipTags));
  }
  out.write('</${node.tag}>');
  return out.toString();
}

/// Serializes an attribute block: leading space, `name="value"` pairs.
String xmlAttributes(XmlNode node, {Set<String> skip = const <String>{}}) {
  final StringBuffer out = StringBuffer();
  node.attributes.forEach((String name, String value) {
    if (!skip.contains(name)) {
      out.write(' $name="${escapeXml(value)}"');
    }
  });
  return out.toString();
}

/// Escapes a string for use inside a double-quoted XML attribute.
String escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

int _findTagEnd(String source, int from) {
  bool inDouble = false;
  bool inSingle = false;
  for (int j = from; j < source.length; j++) {
    final String c = source[j];
    if (c == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (c == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (c == '>' && !inDouble && !inSingle) {
      return j;
    }
  }
  return -1;
}

Map<String, String> _parseAttributes(String text) {
  final Map<String, String> attributes = <String, String>{};
  int i = 0;
  while (i < text.length) {
    while (i < text.length && text.codeUnitAt(i) <= 0x20) {
      i += 1;
    }
    if (i >= text.length) {
      break;
    }
    final int nameStart = i;
    while (i < text.length &&
        text[i] != '=' &&
        text.codeUnitAt(i) > 0x20) {
      i += 1;
    }
    final String name = _stripNamespace(text.substring(nameStart, i));
    while (i < text.length && text.codeUnitAt(i) <= 0x20) {
      i += 1;
    }
    if (i >= text.length || text[i] != '=') {
      // Bare attribute without a value.
      attributes[name] = '';
      continue;
    }
    i += 1; // skip '='
    while (i < text.length && text.codeUnitAt(i) <= 0x20) {
      i += 1;
    }
    if (i >= text.length) {
      break;
    }
    final String quote = text[i];
    if (quote != '"' && quote != "'") {
      // Unquoted value: read until whitespace.
      final int valueStart = i;
      while (i < text.length && text.codeUnitAt(i) > 0x20) {
        i += 1;
      }
      attributes[name] = _unescape(text.substring(valueStart, i));
      continue;
    }
    i += 1;
    final int valueStart = i;
    while (i < text.length && text[i] != quote) {
      i += 1;
    }
    attributes[name] = _unescape(text.substring(valueStart, i));
    if (i < text.length) {
      i += 1; // skip closing quote
    }
  }
  return attributes;
}

String _stripNamespace(String name) {
  final int colon = name.indexOf(':');
  return colon < 0 ? name : name.substring(colon + 1);
}

String _unescape(String value) {
  String out = value;
  out = out.replaceAll('&lt;', '<');
  out = out.replaceAll('&gt;', '>');
  out = out.replaceAll('&quot;', '"');
  out = out.replaceAll('&apos;', "'");
  out = out.replaceAll('&amp;', '&');
  return out.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (Match m) => String.fromCharCode(int.parse(m.group(1)!)),
  );
}

int _indexOfWhitespace(String value) {
  for (int i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) <= 0x20) {
      return i;
    }
  }
  return -1;
}