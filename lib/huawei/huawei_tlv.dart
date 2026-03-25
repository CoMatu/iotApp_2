import 'dart:convert';
import 'dart:typed_data';

/// Huawei TLV.
///
/// Based on gadgetbridge implementation:
/// - tag: 1 byte
/// - length: VarInt (7 bits per byte, big-endian group order)
/// - value: [length] bytes
class HuaweiTLV {
  final List<_HuaweiTLVEntry> _entries = [];

  HuaweiTLV();

  List<_HuaweiTLVEntry> get entries => List.unmodifiable(_entries);

  int length() {
    var total = 0;
    for (final e in _entries) {
      total += 1 + _VarInt.sizeOf(e.value.length) + e.value.length;
    }
    return total;
  }

  HuaweiTLV parse(Uint8List buffer, int offset, int length) {
    var parsed = 0;
    while (parsed < length) {
      final tag = buffer[offset + parsed];
      parsed += 1;

      // gadgetbridge ignores extra null byte at the end of encrypted payload.
      if (parsed == length && tag == 0) {
        break;
      }

      final varInt = _VarInt(buffer, offset + parsed);
      final size = varInt.decodedValue;
      parsed += varInt.encodedSize;

      final value = Uint8List(size);
      if (size > 0) {
        value.setAll(0, buffer.sublist(offset + parsed, offset + parsed + size));
      }
      _entries.add(_HuaweiTLVEntry(tag, value));
      parsed += size;
    }
    return this;
  }

  HuaweiTLV parseAll(Uint8List buffer) => parse(buffer, 0, buffer.length);

  Uint8List serialize() {
    if (_entries.isEmpty) return Uint8List(0);

    final out = Uint8List(length());
    var pos = 0;
    for (final e in _entries) {
      out[pos] = e.tag;
      pos += 1;

      final varIntBytes = _VarInt.encode(e.value.length);
      out.setRange(pos, pos + varIntBytes.length, varIntBytes);
      pos += varIntBytes.length;

      out.setRange(pos, pos + e.value.length, e.value);
      pos += e.value.length;
    }
    return out;
  }

  HuaweiTLV putTag(int tag) {
    _entries.add(_HuaweiTLVEntry(tag, Uint8List(0)));
    return this;
  }

  HuaweiTLV putByte(int tag, int value) {
    _entries.add(_HuaweiTLVEntry(tag, Uint8List.fromList([value & 0xFF])));
    return this;
  }

  HuaweiTLV putShort(int tag, int value) {
    final v = value & 0xFFFF;
    _entries.add(_HuaweiTLVEntry(tag, Uint8List.fromList([(v >> 8) & 0xFF, v & 0xFF])));
    return this;
  }

  HuaweiTLV putInt(int tag, int value) {
    final v = value & 0xFFFFFFFF;
    _entries.add(_HuaweiTLVEntry(tag, Uint8List.fromList([
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ])));
    return this;
  }

  HuaweiTLV putBytes(int tag, Uint8List? value) {
    if (value == null) return this;
    _entries.add(_HuaweiTLVEntry(tag, Uint8List.fromList(value)));
    return this;
  }

  HuaweiTLV putString(int tag, String value) {
    return putBytes(tag, Uint8List.fromList(utf8.encode(value)));
  }

  bool containsTag(int tag) {
    return _entries.any((e) => e.tag == (tag & 0xFF));
  }

  Uint8List getBytes(int tag) {
    for (final e in _entries) {
      if (e.tag == (tag & 0xFF)) return Uint8List.fromList(e.value);
    }
    throw StateError('Missing tag: 0x${(tag & 0xFF).toRadixString(16)}');
  }

  Uint8List getBytesOr(int tag, Uint8List defaultValue) {
    try {
      return getBytes(tag);
    } catch (_) {
      return Uint8List.fromList(defaultValue);
    }
  }

  int getByte(int tag) => getBytes(tag).first;

  int getShort(int tag) {
    final v = getBytes(tag);
    if (v.length != 2) {
      throw StateError('Tag 0x${(tag & 0xFF).toRadixString(16)} is not a short: len=${v.length}');
    }
    return ((v[0] << 8) | v[1]) & 0xFFFF;
  }

  int getInt(int tag) {
    final v = getBytes(tag);
    if (v.length != 4) {
      throw StateError('Tag 0x${(tag & 0xFF).toRadixString(16)} is not an int: len=${v.length}');
    }
    return ((v[0] << 24) | (v[1] << 16) | (v[2] << 8) | v[3]) & 0xFFFFFFFF;
  }

  bool getBoolean(int tag) => getByte(tag) == 1;
}

class _HuaweiTLVEntry {
  final int tag; // 0..255
  final Uint8List value;

  _HuaweiTLVEntry(this.tag, this.value);
}

class _VarInt {
  final int decodedValue;
  final int encodedSize;

  _VarInt(Uint8List src, int offset)
      : this._(
          _decode(src, offset).value,
          _decode(src, offset).size,
        );

  _VarInt._(this.decodedValue, this.encodedSize);

  static int sizeOf(int value) {
    var result = 0;
    var v = value;
    do {
      result++;
      v = v >>> 7;
    } while (v != 0);
    return result;
  }

  static Uint8List encode(int value) {
    final size = sizeOf(value);
    final result = Uint8List(size);

    // gadgetbridge putVarIntValue:
    // result[size - 1] = (byte)(value & 0x7F);
    result[size - 1] = value & 0x7F;
    var v = value;
    for (var offset = size - 2; offset >= 0; offset--) {
      v = v >>> 7;
      result[offset] = (v & 0x7F) | 0x80;
    }
    return result;
  }

  static _VarIntDecoded _decode(Uint8List src, int offset) {
    var result = 0;
    var idx = offset;
    while (true) {
      final b = src[idx];
      result += (b & 0x7F);
      if ((b & 0x80) == 0) {
        return _VarIntDecoded(result, idx - offset + 1);
      }
      result <<= 7;
      idx += 1;
    }
  }

  // Intentionally no helpers beyond encode/decode/size.
}

class _VarIntDecoded {
  final int value;
  final int size;

  _VarIntDecoded(this.value, this.size);
}


