import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'huawei_tlv.dart';

const String kHuaweiHiChainServiceType =
    '7B0BC0CBCE474F6C238D9661C63400B797B166EA7849B3A370FC73A9A236E989';

class HuaweiHiChain3 {
  static const String _groupId = kHuaweiHiChainServiceType;

  static Uint8List randomBytes(int len) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(len, (_) => rng.nextInt(256)));
  }

  static Uint8List hexToBytes(String hexStr) {
    final s = hexStr.trim();
    if (s.isEmpty) return Uint8List(0);
    if (s.length.isOdd) {
      throw StateError('Invalid hex string length: ${s.length}');
    }
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final slice = s.substring(i * 2, i * 2 + 2);
      out[i] = int.parse(slice, radix: 16);
    }
    return out;
  }

  static Uint8List concatBytes(List<Uint8List> parts) {
    final totalLen = parts.fold<int>(0, (sum, p) => sum + p.length);
    final out = Uint8List(totalLen);
    var offset = 0;
    for (final p in parts) {
      out.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    return out;
  }

  static HuaweiTLV buildHiChainRequestTlv({
    required Uint8List selfAuthId,
    required int operationCode,
    required int requestId,
    required int messageId,
    required Map<String, dynamic> payloadExtra,
    required Map<String, dynamic> outerExtra,
  }) {
    final effectiveMessageId = operationCode == 0x02
        ? (messageId | 0x10)
        : messageId;

    final jsonPayload = <String, dynamic>{
      'version': {'minVersion': '1.0.0', 'currentVersion': '2.0.16'},
      ...payloadExtra,
    };

    final outerValue = <String, dynamic>{
      'authForm': 0x00,
      'payload': jsonPayload,
      'groupAndModuleVersion': '2.0.1',
      'message': effectiveMessageId,
      ...outerExtra,
    };

    if (operationCode == 0x01) {
      final selfAuthStr = utf8.decode(selfAuthId);
      outerValue.addAll({
        'requestId': requestId.toString(),
        'groupId': _groupId,
        'groupName': 'health_group_name',
        'groupOp': 2,
        'groupType': 256,
        'peerDeviceId': selfAuthStr,
        'connDeviceId': selfAuthStr,
        'appId': 'com.huawei.health',
        'ownerName': '',
      });
    }

    final requestIdBytes = ByteData(8);
    requestIdBytes.setInt64(0, requestId, Endian.big);

    return HuaweiTLV()
      ..putString(0x01, jsonEncode(outerValue))
      ..putByte(0x02, operationCode)
      ..putBytes(0x03, requestIdBytes.buffer.asUint8List());
  }

  static Map<String, dynamic> parseHiChainPayload(HuaweiTLV tlv) {
    if (!tlv.containsTag(0x01)) {
      throw StateError('HiChain response missing TLV tag 0x01');
    }
    var jsonBytes = tlv.getBytes(0x01);
    final nullIdx = jsonBytes.indexWhere((b) => b == 0);
    if (nullIdx >= 0) {
      jsonBytes = jsonBytes.sublist(0, nullIdx);
    }
    var jsonStr = utf8.decode(jsonBytes, allowMalformed: true);

    final firstBrace = jsonStr.indexOf('{');
    final lastBrace = jsonStr.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      jsonStr = jsonStr.substring(firstBrace, lastBrace + 1);
    } else {
      return <String, dynamic>{'payloadRaw': jsonStr.trim()};
    }

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) {
        final payload = decoded['payload'];
        if (payload is Map<String, dynamic>) {
          return payload;
        }
        if (payload != null) {
          return <String, dynamic>{'payloadRaw': payload};
        }
        return decoded;
      }
      return <String, dynamic>{'payloadRaw': decoded};
    } on FormatException {
      return <String, dynamic>{'payloadRaw': jsonStr.trim()};
    }
  }
}
