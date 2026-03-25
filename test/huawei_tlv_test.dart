import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iot_monitor_2/huawei/huawei_tlv.dart';

void main() {
  test('HuaweiTLV serialize/parse roundtrip', () {
    final tlv = HuaweiTLV()
      ..putTag(0x01)
      ..putByte(0x02, 0x7F)
      ..putShort(0x03, 0x1234)
      ..putInt(0x04, 0xAABBCCDD)
      ..putBytes(0x05, Uint8List.fromList([0x10, 0x20, 0x30]));

    final bytes = tlv.serialize();
    final parsed = HuaweiTLV().parse(bytes, 0, bytes.length);

    expect(parsed.entries.length, tlv.entries.length);

    for (var i = 0; i < tlv.entries.length; i++) {
      expect(parsed.entries[i].tag, tlv.entries[i].tag);
      expect(parsed.entries[i].value, tlv.entries[i].value);
    }
  });
}

