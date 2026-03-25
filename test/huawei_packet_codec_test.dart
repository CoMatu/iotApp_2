import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iot_monitor_2/huawei/huawei_packet_codec.dart';
import 'package:iot_monitor_2/huawei/huawei_tlv.dart';

void main() {
  test('HuaweiPacketCodec unsliced serialize/parse roundtrip', () {
    final tlv = HuaweiTLV()
      ..putTag(0x01)
      ..putBytes(0x02, Uint8List.fromList([0xAA, 0xBB]));

    final frame = HuaweiPacketCodec.serializeUnsliced(
      serviceId: 0x01,
      commandId: 0x01,
      serializedTlv: tlv.serialize(),
    );

    final codec = HuaweiPacketCodec();
    final packet = codec.parse(frame);
    expect(packet, isNotNull);
    expect(packet!.serviceId, 0x01);
    expect(packet.commandId, 0x01);
    expect(packet.tlv.entries.length, tlv.entries.length);
    for (var i = 0; i < tlv.entries.length; i++) {
      expect(packet.tlv.entries[i].tag, tlv.entries[i].tag);
      expect(packet.tlv.entries[i].value, tlv.entries[i].value);
    }
  });

  test('HuaweiPacketCodec sliced serialize/parse reassembly', () {
    final largeValue = Uint8List.fromList(List.generate(120, (i) => i & 0xFF));
    final tlv = HuaweiTLV()..putBytes(0x01, largeValue);

    // Force slicing by using small sliceSize.
    final frames = HuaweiPacketCodec.serializeSliced(
      serviceId: 0x01,
      commandId: 0x13,
      serializedTlv: tlv.serialize(),
      sliceSize: 80,
    );

    expect(frames.length, greaterThan(1));

    final codec = HuaweiPacketCodec();
    HuaweiPacket? last;
    for (final f in frames) {
      last = codec.parse(f);
    }

    expect(last, isNotNull);
    expect(last!.serviceId, 0x01);
    expect(last.commandId, 0x13);
    expect(last.tlv.entries.length, 1);
    expect(last.tlv.entries.first.tag, 0x01);
    expect(last.tlv.entries.first.value, largeValue);
  });
}

