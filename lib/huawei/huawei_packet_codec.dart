import 'dart:typed_data';

import 'huawei_tlv.dart';

/// Decoded Huawei packet.
class HuaweiPacket {
  final int serviceId; // 0..255
  final int commandId; // 0..255
  final HuaweiTLV tlv;

  const HuaweiPacket({
    required this.serviceId,
    required this.commandId,
    required this.tlv,
  });
}

/// Huawei packet codec with CRC16 + slicing reassembly.
///
/// Based on gadgetbridge `HuaweiPacket.parseData()` and `serialize*()` logic.
class HuaweiPacketCodec {
  Uint8List? _partialPacket;
  Uint8List? _payload;

  /// Parse a single BLE notification payload.
  ///
  /// If the packet is sliced, the codec will keep state and return a packet only
  /// after the last slice is received.
  HuaweiPacket? parse(Uint8List data) {
    // Append partial packet if we previously got an incomplete prefix.
    if (_partialPacket != null) {
      final combined = Uint8List(_partialPacket!.length + data.length);
      combined.setAll(0, _partialPacket!);
      combined.setAll(_partialPacket!.length, data);
      data = combined;
    }

    int idx = 0;
    final int capacity = data.length;
    if (capacity < 3) {
      _partialPacket = data;
      return null;
    }

    final int magic = data[idx++];
    if (magic != 0x5A) {
      throw StateError('Magic mismatch: 0x${magic.toRadixString(16)} != 0x5A');
    }

    // Need at least magic + short length.
    if (capacity < 5) {
      _partialPacket = data;
      return null;
    }

    if (idx + 2 > capacity) {
      _partialPacket = data;
      return null;
    }

    final int expectedSize = _readUint16BE(data, idx);
    idx += 2;

    final int remaining = capacity - idx;
    // gadgetbridge: if expectedSize + 2 > remaining -> store partial.
    if (expectedSize + 2 > remaining) {
      _partialPacket = data;
      return null;
    }

    // From this point we have the full frame.
    _partialPacket = null;

    int addLen = 1;
    final int isSliced = data[idx++];
    if (isSliced == 1 || isSliced == 2 || isSliced == 3) {
      // Throw away slice flag byte.
      idx++;
      addLen++;
    }

    final int payloadLen = expectedSize - addLen;
    if (payloadLen < 0 || idx + payloadLen > capacity) {
      _partialPacket = data;
      return null;
    }

    Uint8List newPayload = data.sublist(idx, idx + payloadLen);
    idx += payloadLen;

    if (idx + 2 > capacity) {
      _partialPacket = data;
      return null;
    }

    final int expectedChecksum = _readUint16BE(data, idx);
    idx += 2;

    // Compute CRC16 on the same prefix as gadgetbridge.
    // gadgetbridge: new byte[expectedSize + 3]; buffer.get(dataNoCRC, 0, expectedSize+3)
    final int crcLen = expectedSize + 3;
    if (crcLen > data.length) {
      _partialPacket = data;
      return null;
    }
    final int actualChecksum = crc16(data.sublist(0, crcLen), 0x0000) & 0xFFFF;

    if (actualChecksum != (expectedChecksum & 0xFFFF)) {
      throw StateError(
        'Checksum mismatch: actual=0x${actualChecksum.toRadixString(16)} expected=0x${expectedChecksum.toRadixString(16)}',
      );
    }

    Uint8List payloadForParse = newPayload;
    if (isSliced == 1 || isSliced == 2 || isSliced == 3) {
      // Reassemble sliced payload.
      if (_payload != null) {
        final combined = Uint8List(_payload!.length + newPayload.length);
        combined.setAll(0, _payload!);
        combined.setAll(_payload!.length, newPayload);
        payloadForParse = combined;
      }

      if (isSliced != 3) {
        _payload = payloadForParse;
        return null;
      }
      _payload = null;
    }

    if (payloadForParse.length < 2) {
      throw StateError('Payload too short: ${payloadForParse.length}');
    }

    final int serviceId = payloadForParse[0];
    final int commandId = payloadForParse[1];
    final tlvBytes = payloadForParse.length > 2 ? payloadForParse.sublist(2) : Uint8List(0);

    final tlv = HuaweiTLV().parse(tlvBytes, 0, tlvBytes.length);
    return HuaweiPacket(serviceId: serviceId, commandId: commandId, tlv: tlv);
  }

  /// Serialize an unsliced packet.
  static Uint8List serializeUnsliced({
    required int serviceId,
    required int commandId,
    required Uint8List serializedTlv,
  }) {
    final int headerLength = 4; // magic + (short)(bodyLength + 1) + 0x00
    final int bodyHeaderLength = 2; // serviceId + commandId
    final int footerLength = 2; // CRC16
    final int bodyLength = bodyHeaderLength + serializedTlv.length;

    final frameNoCrc = Uint8List(headerLength + bodyLength);
    var idx = 0;
    frameNoCrc[idx++] = 0x5A;

    _writeUint16BE(frameNoCrc, idx, bodyLength + 1);
    idx += 2;

    frameNoCrc[idx++] = 0x00;
    frameNoCrc[idx++] = serviceId & 0xFF;
    frameNoCrc[idx++] = commandId & 0xFF;
    frameNoCrc.setRange(idx, idx + serializedTlv.length, serializedTlv);

    final crc = crc16(frameNoCrc, 0x0000) & 0xFFFF;
    final out = Uint8List(frameNoCrc.length + footerLength);
    out.setRange(0, frameNoCrc.length, frameNoCrc);
    _writeUint16BE(out, frameNoCrc.length, crc);
    return out;
  }

  /// Serialize using slicing logic from gadgetbridge.
  ///
  /// If slicing results in `packetCount == 1`, it falls back to unsliced.
  static List<Uint8List> serializeSliced({
    required int serviceId,
    required int commandId,
    required Uint8List serializedTlv,
    required int sliceSize,
  }) {
    final int headerLength = 5; // Magic + (short)(bodyLength + 1) + 0x00 + extra slice info
    final int bodyHeaderLength = 2; // sID + cID
    final int footerLength = 2; // CRC16
    final int maxBodySize = sliceSize - headerLength - footerLength;
    if (maxBodySize <= 0) {
      // Fallback to unsliced if slice size is too small for any slicing.
      return [serializeUnsliced(serviceId: serviceId, commandId: commandId, serializedTlv: serializedTlv)];
    }

    final packetCount = ((serializedTlv.length + bodyHeaderLength) + maxBodySize - 1) ~/ maxBodySize;
    if (packetCount <= 1) {
      return [serializeUnsliced(serviceId: serviceId, commandId: commandId, serializedTlv: serializedTlv)];
    }

    final tlvBuffer = Uint8List.fromList(serializedTlv);
    var tlvIdx = 0;

    final out = <Uint8List>[];
    var slice = 0x01;
    var flag = 0x00;

    for (var i = 0; i < packetCount; i++) {
      final int remainingTlv = tlvBuffer.length - tlvIdx;
      final int computedPacketSize = remainingTlv + headerLength + footerLength;
      final int actualPacketSize = computedPacketSize < sliceSize ? computedPacketSize : sliceSize;

      final packet = Uint8List(actualPacketSize);
      var p = 0;

      packet[p++] = 0x5A;

      // gadgetbridge: packet.putShort((short)(packetSize - headerLength))
      _writeUint16BE(packet, p, actualPacketSize - headerLength);
      p += 2;

      if (i == packetCount - 1) {
        slice = 0x03;
      }

      packet[p++] = slice;
      packet[p++] = flag;
      flag = (flag + 1) & 0xFF;

      var contentSize = actualPacketSize - headerLength - footerLength;
      if (slice == 0x01) {
        packet[p++] = serviceId & 0xFF;
        packet[p++] = commandId & 0xFF;
        slice = 0x02;
        contentSize -= 2;
      }

      final take = remainingTlv < contentSize ? remainingTlv : contentSize;
      packet.setRange(p, p + take, tlvBuffer.sublist(tlvIdx, tlvIdx + take));
      tlvIdx += take;
      p += take;

      // Build CRC prefix.
      final int crcPrefixLen = actualPacketSize - footerLength; // exact prefix without CRC.
      final crc = crc16(packet.sublist(0, crcPrefixLen), 0x0000) & 0xFFFF;
      // Put CRC.
      _writeUint16BE(packet, actualPacketSize - footerLength, crc);
      out.add(packet);
    }

    return out;
  }

  static int crc16(Uint8List seq, int crcSeed) {
    var crc = crcSeed & 0xFFFF;
    for (final b in seq) {
      crc = ((crc >>> 8) | (crc << 8)) & 0xFFFF;
      crc ^= (b & 0xFF);
      crc ^= ((crc & 0xFF) >> 4);
      crc ^= (crc << 12) & 0xFFFF;
      crc ^= ((crc & 0xFF) << 5) & 0xFFFF;
    }
    crc &= 0xFFFF;
    return crc;
  }

  static int _readUint16BE(Uint8List data, int offset) {
    return ((data[offset] << 8) | data[offset + 1]) & 0xFFFF;
  }

  static void _writeUint16BE(Uint8List out, int offset, int value) {
    final v = value & 0xFFFF;
    out[offset] = (v >> 8) & 0xFF;
    out[offset + 1] = v & 0xFF;
  }
}

