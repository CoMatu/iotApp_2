import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'huawei_crypto.dart';
import 'huawei_packet_codec.dart';
import 'huawei_tlv.dart';

class HuaweiPairingResult {
  final String deviceId;
  final String? productModel;
  final int? batteryLevel;

  const HuaweiPairingResult({
    required this.deviceId,
    required this.productModel,
    required this.batteryLevel,
  });
}

class HuaweiBand10PairingManager {
  // Band 10 proprietary transport.
  static const String _serviceUuid = 'FE86';
  static const String _txUuid = 'FE01';
  static const String _rxUuid = 'FE02';

  // Used for persistence between app restarts.
  static const String kPairedDeviceIdsKey = 'huawei_paired_device_ids';

  // DeviceConfig = 0x01 serviceId.
  static const int _serviceId = 0x01;

  // Commands.
  static const int _cmdLinkParams = 0x01; // 0x01/0x01
  static const int _cmdAuth = 0x13; // 0x01/0x13
  static const int _cmdSecurityNegotiation = 0x33; // 0x01/0x33
  static const int _cmdBondParams = 0x0F; // 0x01/0x0F
  static const int _cmdBond = 0x0E; // 0x01/0x0E
  static const int _cmdPinCode = 0x2C; // 0x01/0x2C

  // Init.
  static const int _cmdProductInfo = 0x07; // 0x01/0x07
  static const int _cmdTimeRequest = 0x05; // 0x01/0x05
  static const int _cmdBatteryLevel = 0x08; // 0x01/0x08
  static const int _cmdSupportedServices = 0x02; // 0x01/0x02

  // ProductInfo tags for non-AW devices.
  static const List<int> _productInfoTagsNormal = [
    0x01,
    0x02,
    0x07,
    0x09,
    0x0A,
    0x11,
    0x12,
    0x16,
    0x1A,
    0x1D,
    0x1E,
    0x1F,
    0x20,
    0x21,
    0x22,
    0x23,
  ];

  // From DeviceConfig.SupportedServices.knownSupportedServices.
  static const List<int> _knownSupportedServices = [
    0x02,
    0x03,
    0x04,
    0x05,
    0x06,
    0x07,
    0x08,
    0x09,
    0x0A,
    0x0B,
    0x0C,
    0x0D,
    0x0E,
    0x0F,
    0x10,
    0x11,
    0x12,
    0x13,
    0x14,
    0x15,
    0x16,
    0x17,
    0x18,
    0x19,
    0x1A,
    0x1B,
    0x1D,
    0x20,
    0x22,
    0x23,
    0x24,
    0x25,
    0x26,
    0x27,
    0x2A,
    0x2B,
    0x2D,
    0x2E,
    0x30,
    0x32,
    0x33,
    0x34,
    0x35,
  ];

  Future<HuaweiPairingResult> pairAndInitialize({
    required String deviceId,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    String shortDeviceId(String id) {
      // MAC-like IDs are long; shorten to make logs readable.
      if (id.length <= 8) return id;
      return id.substring(id.length - 6);
    }

    debugPrint('🧭 [PAIR] Start pairing device=${shortDeviceId(deviceId)} timeout=${timeout.inSeconds}s');
    String stage = 'connect/discover';

    await UniversalBle.connect(deviceId);
    debugPrint('🔌 [PAIR] Connected device=${shortDeviceId(deviceId)}');

    await UniversalBle.discoverServices(deviceId);
    debugPrint('🧩 [PAIR] Services discovered device=${shortDeviceId(deviceId)}');

    final codec = HuaweiPacketCodec();
    final waiters = <String, Queue<Completer<HuaweiPacket>>>{};

    String hex(Uint8List bytes) {
      const hexChars = '0123456789ABCDEF';
      final sb = StringBuffer();
      for (final b in bytes) {
        sb.write(hexChars[(b >> 4) & 0x0F]);
        sb.write(hexChars[b & 0x0F]);
      }
      return sb.toString();
    }

    Uint8List? secretKey; // authkey generated per session.
    int sliceSize = 0x00F4; // default value before LinkParams.
    int mtu = 0;
    int authVersion = 0;
    int deviceSupportType = 0;
    int authAlgo = 0;
    int encryptMethod = 0;

    // From HuaweiSupportProvider: authMode is 0x02 for HiChainLite, otherwise 0.
    int authMode = 0;
    late Uint8List firstKey; // used for HiChainLite encryptionKey.

    Uint8List? pinCode; // used when authMode==0x02 and authVersion!=0x02.

    // Encryption IV/counter for subsequent TLV encryption.
    int encryptionCounter = 0;

    // Notifications for FE02.
    stage = 'subscribe notify FE02';
    await UniversalBle.subscribeNotifications(deviceId, _serviceUuid, _rxUuid);
    debugPrint('📡 [PAIR] Subscribed notifications FE02 device=${shortDeviceId(deviceId)}');

    StreamSubscription<Uint8List>? sub;
    try {
      sub = UniversalBle.characteristicValueStream(deviceId, _rxUuid).listen((value) {
        try {
          debugPrint('📥 [PAIR] RX FE02: ${hex(value)}');
          final packet = codec.parse(value);
          if (packet == null) return;
          final key = '${packet.serviceId}:${packet.commandId}';
          final q = waiters[key];
          if (q == null || q.isEmpty) return;
          q.removeFirst().complete(packet);
        } catch (e, st) {
          debugPrint('⚠️ [PAIR] Packet parse error: $e\n$st');
        }
      });

      Future<HuaweiPacket> waitPacket(int service, int command) {
        final key = '$service:$command';
        final c = Completer<HuaweiPacket>();
        final q = waiters.putIfAbsent(key, () => Queue<Completer<HuaweiPacket>>());
        q.add(c);
        return c.future.timeout(timeout).catchError((_) {
          q.remove(c);
          if (q.isEmpty) waiters.remove(key);
          throw TimeoutException('Timeout waiting Huawei packet $key');
        });
      }

      Uint8List getIv() {
        if (deviceSupportType == 0x04) {
          return HuaweiCrypto.generateNonce();
        }
        final iv = HuaweiCrypto.initializationVector(encryptionCounter);
        // Last 4 bytes contain incremented counter (big-endian).
        encryptionCounter = ((iv[12] << 24) | (iv[13] << 16) | (iv[14] << 8) | iv[15]) & 0xFFFFFFFF;
        return iv;
      }

      bool useGcm() => encryptMethod == 0x01 || deviceSupportType == 0x04;

      HuaweiTLV decryptIfNeeded(HuaweiTLV tlv) {
        if (secretKey == null) return tlv;
        if (!tlv.containsTag(0x7C) || !tlv.getBoolean(0x7C)) return tlv;

        final iv = tlv.getBytes(0x7D);
        final cipherText = tlv.getBytes(0x7E);
        final plain = HuaweiCrypto.decrypt(useGcm(), cipherText, secretKey, iv);
        return HuaweiTLV().parse(plain, 0, plain.length);
      }

      HuaweiTLV encryptHuaweiTlv(HuaweiTLV plainTlv) {
        if (secretKey == null) {
          throw StateError('secretKey is null; cannot encrypt TLV');
        }
        final iv = getIv();
        final plain = plainTlv.serialize();
        final cipherText = HuaweiCrypto.encrypt(useGcm(), plain, secretKey, iv);

        // CryptoTags: encryption=0x7C, initVector=0x7D, cipherText=0x7E
        return HuaweiTLV()
          ..putByte(0x7C, 0x01)
          ..putBytes(0x7D, iv)
          ..putBytes(0x7E, cipherText);
      }

      Future<void> sendPacket({
        required int serviceId,
        required int commandId,
        required HuaweiTLV tlv,
        required bool encryptedTlV,
        required bool isSliced,
      }) async {
        final tlvToSend = encryptedTlV ? encryptHuaweiTlv(tlv) : tlv;
        final serialized = tlvToSend.serialize();

        final frames = isSliced
            ? HuaweiPacketCodec.serializeSliced(
                serviceId: serviceId,
                commandId: commandId,
                serializedTlv: serialized,
                sliceSize: sliceSize,
              )
            : [
                HuaweiPacketCodec.serializeUnsliced(
                  serviceId: serviceId,
                  commandId: commandId,
                  serializedTlv: serialized,
                )
              ];

        var idx = 0;
        for (final frame in frames) {
          debugPrint(
            '📤 [PAIR] TX FE01 [${serviceId.toRadixString(16)}/${commandId.toRadixString(16)}] #$idx (enc=${encryptedTlV ? 1 : 0} slice=${isSliced ? 1 : 0}): ${hex(frame)}',
          );
          idx++;
          await UniversalBle.write(
            deviceId,
            _serviceUuid,
            _txUuid,
            frame,
            withoutResponse: true,
          );
        }
      }

      Future<HuaweiPacket> sendAndWait({
        required String step,
        required int serviceId,
        required int commandId,
        required HuaweiTLV tlv,
        required bool encryptedTlV,
        required bool isSliced,
        int maxRetries = 2,
      }) async {
        for (var attempt = 1; attempt <= maxRetries + 1; attempt++) {
          debugPrint('🧪 [PAIR] $step attempt $attempt');
          await sendPacket(
            serviceId: serviceId,
            commandId: commandId,
            tlv: tlv,
            encryptedTlV: encryptedTlV,
            isSliced: isSliced,
          );
          try {
            final packet = await waitPacket(serviceId, commandId);
            debugPrint('✅ [PAIR] $step response received (service=${serviceId.toRadixString(16)} cmd=${commandId.toRadixString(16)})');
            return packet;
          } on TimeoutException catch (_) {
            if (attempt > maxRetries) rethrow;
            debugPrint('⏳ [PAIR] $step timeout, retrying...');
          }
        }
        throw StateError('$step failed');
      }

      // 1) LinkParams: unencrypted, unsliced.
      stage = 'LinkParams (0x01/0x01)';
      debugPrint('🔍 [PAIR] Request LinkParams');
      final linkPacket = await sendAndWait(
        step: 'LinkParams',
        serviceId: _serviceId,
        commandId: _cmdLinkParams,
        tlv: HuaweiTLV()
          ..putTag(0x01)
          ..putTag(0x02)
          ..putTag(0x03)
          ..putTag(0x04)
          // These tags are read from the response below.
          ..putTag(0x05)
          ..putTag(0x07)
          ..putTag(0x08)
          ..putTag(0x0C),
        encryptedTlV: false,
        isSliced: false,
      );
      final linkTlv = linkPacket.tlv;

      sliceSize = linkTlv.getShort(0x02);
      mtu = linkTlv.getShort(0x03);

      final link05 = linkTlv.getBytes(0x05);
      authVersion = link05[1];
      final serverNonce = Uint8List.fromList(link05.sublist(2, 18));

      deviceSupportType = linkTlv.getByte(0x07);
      // Some firmwares may omit optional tags; keep defaults instead of crashing.
      if (linkTlv.containsTag(0x08)) {
        authAlgo = linkTlv.getByte(0x08);
      } else {
        debugPrint('⚠️ [PAIR] LinkParams: missing tag 0x08 (authAlgo), default=0x00');
      }
      if (linkTlv.containsTag(0x0C)) {
        encryptMethod = linkTlv.getByte(0x0C);
      } else {
        debugPrint('⚠️ [PAIR] LinkParams: missing tag 0x0C (encryptMethod), default=0x00');
      }

      // Decide mode.
      final bool isHiChainLite = deviceSupportType == 0x02;
      final bool isHiChain =
          deviceSupportType == 0x01 || deviceSupportType == 0x03 || deviceSupportType == 0x04 || isHiChainLite;
      if (isHiChain) {
        // For hi-chain devices, initial authMode is 0x04 only for deviceSupportType==0x04, otherwise 0x02.
        authMode = deviceSupportType == 0x04 ? 0x04 : 0x02;

        // 5) Security negotiation (0x01/0x33): decide which auth/bond branch to execute.
        stage = 'SecurityNegotiation (0x01/0x33)';
        debugPrint('🔐 [PAIR] SecurityNegotiation required (authMode=0x${authMode.toRadixString(16)}), mtu=$mtu');

        // Gadgetbridge uses persisted AndroidId (ASCII hex). We derive a deterministic 32-byte value from deviceId.
        final uuidBytesRaw = utf8.encode(deviceId.replaceAll(':', ''));
        final deviceUuid = Uint8List(32);
        final uuidLen = uuidBytesRaw.length < 32 ? uuidBytesRaw.length : 32;
        if (uuidLen > 0) {
          deviceUuid.setRange(0, uuidLen, uuidBytesRaw.sublist(0, uuidLen));
        }

        final securityTlv2 = HuaweiTLV()
          ..putByte(0x01, authMode);
        if (authMode == 0x02 || authMode == 0x04) {
          securityTlv2.putByte(0x02, 0x01);
        }
        securityTlv2
          ..putBytes(0x05, deviceUuid)
          ..putByte(0x03, 0x01)
          ..putByte(0x04, 0x00);
        if (authMode == 0x04) {
          securityTlv2
            ..putTag(0x06)
            ..putString(0x07, 'Flutter');
        }
        if (encryptMethod == 0x01) {
          securityTlv2.putByte(0x0D, 0x1);
        }

        final secPacket = await sendAndWait(
          step: 'SecurityNegotiation',
          serviceId: _serviceId,
          commandId: _cmdSecurityNegotiation,
          tlv: securityTlv2,
          encryptedTlV: false,
          isSliced: false,
        );
        final secTlv = secPacket.tlv;

        int secAuthType = -1;
        int pw = -1;
        if (secTlv.containsTag(0x01)) {
          final b = secTlv.getByte(0x01);
          if (b == 0x01) secAuthType = 0x0186A0;
          if (b == 0x04) pw = 4;
        }
        if (secTlv.containsTag(0x02)) {
          secAuthType = secTlv.getByte(0x02);
          if (pw != -1) {
            secAuthType ^= pw;
          }
        }
        if (secTlv.containsTag(0x7F)) {
          secAuthType = secTlv.getByte(0x7F);
        }

        final bool isHiChain3 = (secAuthType ^ 0x01) == 0x04 || (secAuthType ^ 0x02) == 0x04;
        if (secAuthType == 0x0186A0 || isHiChain3) {
          throw UnsupportedError('HiChain mode is not implemented; SecurityNegotiation authType=0x${secAuthType.toRadixString(16)}');
        }
        if (secAuthType != 0x01 && secAuthType != 0x02) {
          throw StateError('Unexpected SecurityNegotiation authType=0x${secAuthType.toRadixString(16)}');
        }

        debugPrint('🧠 [PAIR] SecurityNegotiation selected HiChainLite branch (authType=0x${secAuthType.toRadixString(16)})');
      } else {
        authMode = 0x00;
        debugPrint('🧠 [PAIR] Normal flow (authMode=0x${authMode.toRadixString(16)}), mtu=$mtu');
      }

      debugPrint(
        '📐 [PAIR] LinkParams parsed: sliceSize=0x${sliceSize.toRadixString(16)}, mtu=0x${mtu.toRadixString(16)}, authVersion=0x${authVersion.toRadixString(16)}, deviceSupportType=0x${deviceSupportType.toRadixString(16)}, authAlgo=0x${authAlgo.toRadixString(16)}, encryptMethod=0x${encryptMethod.toRadixString(16)}',
      );

      // 2) Secret key (random per session).
      stage = 'generate session keys';
      secretKey = HuaweiCrypto.generateNonce();

      // 3) Optional PinCode for HiChainLite when authVersion != 0x02.
      if (authMode == 0x02 && authVersion != 0x02) {
        stage = 'PinCode (0x01/0x2C)';
        debugPrint('🧩 [PAIR] Request PinCode (required for this authVersion in current implementation)');
        final pinPacket = await sendAndWait(
          step: 'PinCode',
          serviceId: _serviceId,
          commandId: _cmdPinCode,
          tlv: HuaweiTLV()..putTag(0x01),
          encryptedTlV: false,
          isSliced: true,
        );
        final pinTlv = decryptIfNeeded(pinPacket.tlv);
        final message = pinTlv.getBytes(0x01);
        final iv = pinTlv.getBytes(0x02);
        final crypto = HuaweiCrypto(authVersion, authAlgo, deviceSupportType, authMode);
        pinCode = crypto.decryptPinCode(encryptMethod, message, iv);
        debugPrint('🔑 [PAIR] PinCode decrypted (messageLen=${message.length})');
      }

      // 4) Auth: Auth (0x01/0x13)
      stage = 'Auth (0x01/0x13)';
      debugPrint('🧬 [PAIR] Prepare Auth challenge and send Auth');
      final clientNonce = HuaweiCrypto.generateNonce();
      final doubleNonce = Uint8List(32)..setRange(0, 16, serverNonce)..setRange(16, 32, clientNonce);

      final nonce = Uint8List(18);
      nonce[0] = (authVersion >> 8) & 0xFF;
      nonce[1] = authVersion & 0xFF;
      nonce.setRange(2, 18, clientNonce);

      final crypto = HuaweiCrypto(authVersion, authAlgo, deviceSupportType, authMode);

      final Uint8List? secretForAuth;
      if (authMode == 0x02) {
        secretForAuth = (authVersion == 0x02) ? secretKey : pinCode;
      } else {
        secretForAuth = null;
      }
      if (secretForAuth == null && authMode == 0x02) {
        throw StateError('PinCode/secretKey missing for authMode=0x02');
      }

      final digestChallenge = crypto.digestChallenge(secretForAuth, doubleNonce);
      if (digestChallenge == null) {
        throw StateError('digestChallenge is null');
      }
      final challenge = digestChallenge.sublist(0, 32);
      firstKey = digestChallenge.sublist(32, 48);
      debugPrint('🔐 [PAIR] Auth prepared (challengeLen=${challenge.length}, firstKeyLen=${firstKey.length})');

      final authTlv = HuaweiTLV()
        ..putBytes(0x01, challenge)
        ..putBytes(0x02, nonce);
      if (authMode == 0x02) {
        authTlv.putByte(0x03, authAlgo);
      }

      await sendPacket(
        serviceId: _serviceId,
        commandId: _cmdAuth,
        tlv: authTlv,
        encryptedTlV: false,
        isSliced: true,
      );

      // Validate Auth response (challengeResponse must match computed digestResponse).
      stage = 'Auth response validate (0x01/0x13)';
      final authRespPacket = await waitPacket(_serviceId, _cmdAuth);
      final authRespTlv = decryptIfNeeded(authRespPacket.tlv);
      final actualAnswer = authRespTlv.getBytes(0x01);

      final expectedDigest = crypto.digestResponse(secretForAuth, doubleNonce);
      if (expectedDigest == null) {
        throw StateError('digestResponse is null (secretForAuth missing?)');
      }
      final expectedAnswer = expectedDigest.sublist(0, 32);

      if (!listEquals(expectedAnswer, actualAnswer)) {
        throw StateError(
          'Auth challenge answer mismatch: expected=${expectedAnswer.length} bytes, actual=${actualAnswer.length} bytes',
        );
      }
      debugPrint('✅ [PAIR] Auth challenge validated');

      // 5) BondParams: BondParams (0x01/0x0F)
      stage = 'BondParams (0x01/0x0F)';
      debugPrint('🧱 [PAIR] Send BondParams');
      final macBytes = Uint8List.fromList(utf8.encode(deviceId));
      final clientSerial = _clientSerialBytes(deviceId);

      final bondParamsPacket = await sendAndWait(
        step: 'BondParams',
        serviceId: _serviceId,
        commandId: _cmdBondParams,
        tlv: HuaweiTLV()
          ..putTag(0x01)
          ..putBytes(0x03, clientSerial)
          ..putByte(0x04, 0x02)
          ..putTag(0x05)
          ..putBytes(0x07, macBytes)
          ..putTag(0x09),
        encryptedTlV: false,
        isSliced: true,
      );
      final bondParamsTlv = decryptIfNeeded(bondParamsPacket.tlv);
      encryptionCounter = bondParamsTlv.getInt(0x09);
      debugPrint('📐 [PAIR] BondParams parsed (encryptionCounter=$encryptionCounter)');

      // 6) Bond: Bond (0x01/0x0E)
      stage = 'Bond (0x01/0x0E)';
      final iv = getIv();
      final encryptionKey = authMode == 0x02 ? firstKey : crypto.createSecretKey(deviceId);
      final bondingKey = crypto.encryptBondingKey(encryptMethod, secretKey, encryptionKey, iv);
      debugPrint('🧰 [PAIR] Prepared Bond payload (bondingKeyLen=${bondingKey.length}, ivLen=${iv.length})');

      stage = 'Bond (0x01/0x0E)';
      await sendAndWait(
        step: 'Bond',
        serviceId: _serviceId,
        commandId: _cmdBond,
        tlv: HuaweiTLV()
          ..putTag(0x01)
          ..putByte(0x03, 0x00)
          ..putBytes(0x05, clientSerial)
          ..putBytes(0x06, bondingKey)
          ..putBytes(0x07, iv),
        encryptedTlV: false,
        isSliced: true,
      );

      // 7) Init: ProductInfo/Battery/SupportedServices (and TimeRequest)
      stage = 'Init: ProductInfo (0x01/0x07)';
      debugPrint('🧾 [PAIR] Request ProductInfo');
      final productTlv = HuaweiTLV();
      for (final t in _productInfoTagsNormal) {
        productTlv.putTag(t);
      }
      final productPacket = await sendAndWait(
        step: 'ProductInfo',
        serviceId: _serviceId,
        commandId: _cmdProductInfo,
        tlv: productTlv,
        encryptedTlV: true,
        isSliced: true,
      );
      final productTlvResp = decryptIfNeeded(productPacket.tlv);
      final productModelBytes = productTlvResp.containsTag(0x0A) ? productTlvResp.getBytes(0x0A) : null;
      final productModel = productModelBytes == null ? null : utf8.decode(productModelBytes).trim();
      debugPrint('🏷️ [PAIR] ProductInfo parsed (model=${productModel ?? 'null'})');

      // TimeRequest (ignore response).
      stage = 'Init: TimeRequest (0x01/0x05)';
      debugPrint('⏰ [PAIR] Send TimeRequest (response optional)');
      await sendPacket(
        serviceId: _serviceId,
        commandId: _cmdTimeRequest,
        tlv: _timeRequestTlv(),
        encryptedTlV: true,
        isSliced: true,
      );
      try {
        await waitPacket(_serviceId, _cmdTimeRequest);
      } catch (_) {}

      // BatteryLevel.
      stage = 'Init: BatteryLevel (0x01/0x08)';
      debugPrint('🔋 [PAIR] Request BatteryLevel');
      final batteryPacket = await sendAndWait(
        step: 'BatteryLevel',
        serviceId: _serviceId,
        commandId: _cmdBatteryLevel,
        tlv: HuaweiTLV()..putTag(0x01),
        encryptedTlV: true,
        isSliced: true,
      );
      final batteryTlvResp = decryptIfNeeded(batteryPacket.tlv);
      final batteryLevel = batteryTlvResp.getByte(0x01);
      debugPrint('🔋 [PAIR] BatteryLevel parsed ($batteryLevel)');

      // SupportedServices (must be last in gadgetbridge).
      stage = 'Init: SupportedServices (0x01/0x02)';
      debugPrint('🧰 [PAIR] Send SupportedServices');
      await sendPacket(
        serviceId: _serviceId,
        commandId: _cmdSupportedServices,
        tlv: HuaweiTLV()
          ..putBytes(0x01, Uint8List.fromList(_knownSupportedServices)),
        encryptedTlV: true,
        isSliced: true,
      );
      try {
        await waitPacket(_serviceId, _cmdSupportedServices);
      } catch (_) {}

      if (productModel == null || batteryLevel <= 0) {
        // BatteryLevel may legitimately be 0 on empty devices, so only check productModel.
        if (productModel == null) {
          throw StateError('Init did not return ProductInfo.productModel');
        }
      }

      return HuaweiPairingResult(
        deviceId: deviceId,
        productModel: productModel,
        batteryLevel: batteryLevel,
      );
    } catch (e, st) {
      debugPrint('❌ [PAIR] Failed at stage="$stage": $e\n$st');
      rethrow;
    } finally {
      await sub?.cancel();
      // Keep the connection for UI; just stop notification stream to reduce noise.
      try {
        await UniversalBle.unsubscribe(deviceId, _serviceUuid, _rxUuid);
      } catch (_) {}
    }
  }

  static Uint8List _clientSerialBytes(String macAddress) {
    final hex = macAddress.replaceAll(':', '');
    final serialStr = hex.substring(6, 12);
    return Uint8List.fromList(utf8.encode(serialStr));
  }

  HuaweiTLV _timeRequestTlv() {
    final now = DateTime.now();
    final seconds = now.millisecondsSinceEpoch ~/ 1000;

    final offsetSeconds = now.timeZoneOffset.inSeconds;
    final hourByte = offsetSeconds < 0
        ? ((-offsetSeconds ~/ 3600) + 128)
        : (offsetSeconds ~/ 3600);
    final minuteByte = (offsetSeconds ~/ 60) % 60;

    final shortValue = ((hourByte & 0xFF) << 8) | (minuteByte & 0xFF);

    return HuaweiTLV()
      ..putInt(0x01, seconds)
      ..putShort(0x02, shortValue);
  }
}

