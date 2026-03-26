import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
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

  // Disconnect after pairing/auth failure (restores default behavior).
  static const bool _disconnectOnPairingFailure = true;

  // Used for persistence between app restarts.
  static const String kPairedDeviceIdsKey = 'huawei_paired_device_ids';

  // DeviceConfig = 0x01 serviceId.
  static const int _serviceId = 0x01;

  // Commands.
  static const int _cmdLinkParams = 0x01; // 0x01/0x01
  static const int _cmdAuth = 0x13; // 0x01/0x13
  static const int _cmdSecurityNegotiation = 0x33; // 0x01/0x33
  static const int _cmdHiChain = 0x28; // 0x01/0x28 (HiChain3)
  static const int _cmdBondParams = 0x0F; // 0x01/0x0F
  static const int _cmdBond = 0x0E; // 0x01/0x0E
  static const int _cmdPinCode = 0x2C; // 0x01/0x2C

  // Init.
  static const int _cmdProductInfo = 0x07; // 0x01/0x07
  static const int _cmdTimeRequest = 0x05; // 0x01/0x05
  static const int _cmdBatteryLevel = 0x08; // 0x01/0x08
  static const int _cmdBatteryLevelChange = 0x27; // 0x01/0x27 (async battery update)
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

    debugPrint(
      '🧭 [PAIR] Start pairing device=${shortDeviceId(deviceId)} timeout=${timeout.inSeconds}s',
    );
    String stage = 'connect/discover';

    await UniversalBle.connect(deviceId);
    debugPrint('🔌 [PAIR] Connected device=${shortDeviceId(deviceId)}');

    await UniversalBle.discoverServices(deviceId);
    debugPrint(
      '🧩 [PAIR] Services discovered device=${shortDeviceId(deviceId)}',
    );

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
    debugPrint(
      '📡 [PAIR] Subscribed notifications FE02 device=${shortDeviceId(deviceId)}',
    );

    StreamSubscription<Uint8List>? sub;
    bool failed = false;
    try {
      int? extractBatteryLevelFromTlv(HuaweiTLV tlv) {
        // Based on gadgetbridge:
        // - simple response: level is tag 0x01
        // - multiple batteries: first element is tag 0x02
        if (tlv.containsTag(0x01)) return tlv.getByte(0x01);
        if (tlv.containsTag(0x02)) {
          final bytes = tlv.getBytes(0x02);
          return bytes.isNotEmpty ? bytes.first : null;
        }
        return null;
      }

      sub = UniversalBle.characteristicValueStream(deviceId, _rxUuid).listen((
        value,
      ) {
        try {
          debugPrint('📥 [PAIR] RX FE02: ${hex(value)}');
          final packet = codec.parse(value);
          if (packet == null) return;
          final key = '${packet.serviceId}:${packet.commandId}';
          final q = waiters[key];
          if (q == null || q.isEmpty) {
            // Help debugging: during SecurityNegotiation we need to know if device
            // responds with a different commandId/serviceId.
            if (stage.startsWith('SecurityNegotiation')) {
              debugPrint(
                '⚠️ [PAIR] RX packet has no waiter during SecurityNegotiation: service=${packet.serviceId.toRadixString(16)} cmd=${packet.commandId.toRadixString(16)}',
              );
            }
            return;
          }
          q.removeFirst().complete(packet);
        } catch (e, st) {
          debugPrint('⚠️ [PAIR] Packet parse error: $e\n$st');
        }
      });

      Future<HuaweiPacket> waitPacket(int service, int command) {
        final key = '$service:$command';
        final c = Completer<HuaweiPacket>();
        final q = waiters.putIfAbsent(
          key,
          () => Queue<Completer<HuaweiPacket>>(),
        );
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
        encryptionCounter =
            ((iv[12] << 24) | (iv[13] << 16) | (iv[14] << 8) | iv[15]) &
            0xFFFFFFFF;
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
                ),
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
        int maxRetries = 0,
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
            debugPrint(
              '✅ [PAIR] $step response received (service=${serviceId.toRadixString(16)} cmd=${commandId.toRadixString(16)})',
            );
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
        debugPrint(
          '⚠️ [PAIR] LinkParams: missing tag 0x08 (authAlgo), default=0x00',
        );
      }
      if (linkTlv.containsTag(0x0C)) {
        encryptMethod = linkTlv.getByte(0x0C);
      } else {
        debugPrint(
          '⚠️ [PAIR] LinkParams: missing tag 0x0C (encryptMethod), default=0x00',
        );
      }

      // Decide mode.
      final bool isHiChainLite = deviceSupportType == 0x02;
      final bool isHiChain =
          deviceSupportType == 0x01 ||
          deviceSupportType == 0x03 ||
          deviceSupportType == 0x04 ||
          isHiChainLite;

      bool isHiChain3 = false;
      bool isHiChainLiteAuthType = false;
      bool isSupportedHiChain3AuthType = false;

      Uint8List? hiChainSelfAuthId;
      if (isHiChain) {
        // Для HiChainLite/HiChain выбираем authMode как в gadgetbridge.
        // deviceSupportType==0x04 соответствует HiChain3 (authMode=0x04).
        authMode = deviceSupportType == 0x04 ? 0x04 : 0x02;

        // 5) Security negotiation (0x01/0x33): decide which auth/bond branch to execute.
        stage = 'SecurityNegotiation (0x01/0x33)';
        debugPrint(
          '🔐 [PAIR] SecurityNegotiation required (authMode=0x${authMode.toRadixString(16)}), mtu=$mtu',
        );

        // Gadgetbridge uses persisted AndroidId (ASCII hex) as deviceUUID input.
        // If we fail to read AndroidId (non-Android platform), fall back to a deterministic value from deviceId.
        final androidId = await _getAndroidId();
        final uuidSource = (androidId != null && androidId.isNotEmpty)
            ? androidId
            : deviceId.replaceAll(':', '');
        final deviceUuidHex = _normalizeDeviceUuidHex32(uuidSource);
        final deviceUuid = Uint8List.fromList(utf8.encode(deviceUuidHex));

        final securityTlv2 = HuaweiTLV()..putByte(0x01, authMode);
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
          maxRetries: 1,
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

        isHiChain3 =
            (secAuthType ^ 0x01) == 0x04 || (secAuthType ^ 0x02) == 0x04;
        isHiChainLiteAuthType = secAuthType == 0x01 || secAuthType == 0x02;
        isSupportedHiChain3AuthType = authMode == 0x04 && isHiChain3;

        // For authMode=0x04 we can continue even if SecurityNegotiation reports HiChain3.
        // Without this, the pairing fails early with:
        // "Unsupported operation: HiChain mode is not implemented; SecurityNegotiation authType=0x5"
        if (secAuthType == 0x0186A0) {
          throw UnsupportedError(
            'HiChain mode is not implemented; SecurityNegotiation authType=0x${secAuthType.toRadixString(16)}',
          );
        }
        if (isHiChain3 && !isSupportedHiChain3AuthType) {
          throw UnsupportedError(
            'HiChain3 authType is not implemented for authMode=0x${authMode.toRadixString(16)}; SecurityNegotiation authType=0x${secAuthType.toRadixString(16)}',
          );
        }
        if (!isHiChainLiteAuthType && !isSupportedHiChain3AuthType) {
          throw StateError(
            'Unexpected SecurityNegotiation authType=0x${secAuthType.toRadixString(16)} (authMode=0x${authMode.toRadixString(16)})',
          );
        }

        debugPrint(
          '🧠 [PAIR] SecurityNegotiation authMode=0x${authMode.toRadixString(16)} authType=0x${secAuthType.toRadixString(16)} (proceed to Auth/Bond)',
        );

        // Keep for HiChain3.
        hiChainSelfAuthId = deviceUuid;
      } else {
        authMode = 0x00;
        debugPrint(
          '🧠 [PAIR] Normal flow (authMode=0x${authMode.toRadixString(16)}), mtu=$mtu',
        );
      }

      debugPrint(
        '📐 [PAIR] LinkParams parsed: sliceSize=0x${sliceSize.toRadixString(16)}, mtu=0x${mtu.toRadixString(16)}, authVersion=0x${authVersion.toRadixString(16)}, deviceSupportType=0x${deviceSupportType.toRadixString(16)}, authAlgo=0x${authAlgo.toRadixString(16)}, encryptMethod=0x${encryptMethod.toRadixString(16)}',
      );

      // 2) HiChain3 (authType=0x5) uses a different protocol: HiChain (0x01/0x28).
      // For HiChain3 we must derive final `secretKey` and then run only Init (ProductInfo/Battery/SupportedServices).
      if (isHiChain3) {
        stage = 'PinCode (0x01/0x2C) [HiChain3]';
        debugPrint('🧩 [PAIR] Request PinCode for HiChain3');

        final pinPacket = await sendAndWait(
          step: 'PinCode',
          serviceId: _serviceId,
          commandId: _cmdPinCode,
          tlv: HuaweiTLV()..putTag(0x01),
          encryptedTlV: false,
          isSliced: true,
        );
        final pinTlv = decryptIfNeeded(pinPacket.tlv);
        final pinMessage = pinTlv.getBytes(0x01);
        final pinIv = pinTlv.getBytes(0x02);
        final pinCrypto = HuaweiCrypto(
          authVersion,
          authAlgo,
          deviceSupportType,
          authMode,
        );
        pinCode = pinCrypto.decryptPinCode(encryptMethod, pinMessage, pinIv);
        debugPrint('🔑 [PAIR] PinCode decrypted (len=${pinCode.length})');

        final Uint8List selfAuthId = hiChainSelfAuthId!;

        Uint8List randomBytes(int len) {
          final rng = Random.secure();
          return Uint8List.fromList(
            List.generate(len, (_) => rng.nextInt(256)),
          );
        }

        Uint8List hexToBytes(String hexStr) {
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

        Uint8List concatBytes(List<Uint8List> parts) {
          final totalLen = parts.fold<int>(0, (sum, p) => sum + p.length);
          final out = Uint8List(totalLen);
          var offset = 0;
          for (final p in parts) {
            out.setRange(offset, offset + p.length, p);
            offset += p.length;
          }
          return out;
        }

        const String groupId =
            '7B0BC0CBCE474F6C238D9661C63400B797B166EA7849B3A370FC73A9A236E989';

        HuaweiTLV buildHiChainRequestTlv({
          required int operationCode, // 0x01 auth, 0x02 bind
          required int requestId,
          required int
          messageId, // step (1..4); device may OR with 0x10 for bind
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
              'groupId': groupId,
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

        Map<String, dynamic> parseHiChainPayload(HuaweiTLV tlv) {
          if (!tlv.containsTag(0x01)) {
            throw StateError('HiChain response missing TLV tag 0x01');
          }
          // Some firmwares append trailing zero bytes; gadgetbridge's getString()
          // is effectively "until null terminator".
          var jsonBytes = tlv.getBytes(0x01);
          final nullIdx = jsonBytes.indexWhere((b) => b == 0);
          if (nullIdx >= 0) {
            jsonBytes = jsonBytes.sublist(0, nullIdx);
          }
          var jsonStr = utf8.decode(jsonBytes, allowMalformed: true);

          // Be defensive: keep only the first JSON object we can parse.
          final firstBrace = jsonStr.indexOf('{');
          final lastBrace = jsonStr.lastIndexOf('}');
          if (firstBrace >= 0 && lastBrace > firstBrace) {
            jsonStr = jsonStr.substring(firstBrace, lastBrace + 1);
          }

          final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
          final payload = decoded['payload'] as Map<String, dynamic>;
          return payload;
        }

        Uint8List hkdfInfoSession = Uint8List.fromList(
          utf8.encode('hichain_iso_session_key'),
        );
        Uint8List hkdfInfoReturn = Uint8List.fromList(
          utf8.encode('hichain_return_key'),
        );
        Uint8List aadIsoExchange = Uint8List.fromList(
          utf8.encode('hichain_iso_exchange'),
        );
        Uint8List aadIsoResult = Uint8List.fromList(
          utf8.encode('hichain_iso_result'),
        );

        stage = 'HiChain3 auth (0x01/0x28)';
        final int requestIdAuth = DateTime.now().millisecondsSinceEpoch;
        final Uint8List seedAuth = randomBytes(32);
        final Uint8List randSelfAuth = randomBytes(16);

        // Step 1 (auth)
        final step1AuthPkt = await sendAndWait(
          step: 'HiChain3 Auth Step1',
          serviceId: _serviceId,
          commandId: _cmdHiChain,
          tlv: buildHiChainRequestTlv(
            operationCode: 0x01,
            requestId: requestIdAuth,
            messageId: 0x01,
            payloadExtra: {
              'isoSalt': hex(randSelfAuth),
              'peerAuthId': hex(selfAuthId),
              'operationCode': 0x01,
              'seed': hex(seedAuth),
              'peerUserType': 0x00,
            },
            outerExtra: const {},
          ),
          encryptedTlV: false,
          isSliced: true,
        );

        final payload1Auth = parseHiChainPayload(step1AuthPkt.tlv);
        final isoSaltHexAuth = payload1Auth['isoSalt'] as String?;
        final peerAuthIdHexAuth = payload1Auth['peerAuthId'] as String?;
        final tokenHexAuth = payload1Auth['token'] as String?;
        final errCode1 = payload1Auth['errorCode'];
        if (isoSaltHexAuth == null ||
            peerAuthIdHexAuth == null ||
            tokenHexAuth == null) {
          debugPrint(
            '⚠️ [PAIR] HiChain3 auth step1 payload parse issue: keys=${payload1Auth.keys} errorCode=$errCode1 payload=$payload1Auth',
          );
          throw StateError(
            'HiChain3 auth step1 missing isoSalt/peerAuthId/token',
          );
        }
        final Uint8List randPeerAuth = hexToBytes(isoSaltHexAuth);
        final Uint8List authIdPeerAuth = hexToBytes(peerAuthIdHexAuth);
        final Uint8List peerTokenAuth = hexToBytes(tokenHexAuth);

        // psk = HMAC( digest(pinCodeHexBytes), seed )
        final pinHexUpper = hex(pinCode);
        final pinKey = HuaweiCrypto.sha256Bytes(
          Uint8List.fromList(utf8.encode(pinHexUpper)),
        );
        final Uint8List pskAuth = HuaweiCrypto.hmacSha256(pinKey, seedAuth);

        // gadgetbridge:
        // - tokenCheck (peerToken) = HMAC(psk, randPeer + randSelf + authIdSelf + authIdPeer)
        // - selfToken (sent in Step2) = HMAC(psk, randSelf + randPeer + authIdPeer + authIdSelf)
        final peerMsgAuth = concatBytes([
          randPeerAuth,
          randSelfAuth,
          selfAuthId,
          authIdPeerAuth,
        ]);
        final tokenCheckAuth = HuaweiCrypto.hmacSha256(pskAuth, peerMsgAuth);
        if (!listEquals(tokenCheckAuth, peerTokenAuth)) {
          debugPrint(
            '⚠️ [PAIR] HiChain3 auth peerToken mismatch; computed=${hex(tokenCheckAuth)} device=${hex(peerTokenAuth)}',
          );
        }

        final selfMsgAuth = concatBytes([
          randSelfAuth,
          randPeerAuth,
          authIdPeerAuth,
          selfAuthId,
        ]);
        final selfTokenAuth = HuaweiCrypto.hmacSha256(pskAuth, selfMsgAuth);

        // Step 2 (auth)
        final step2AuthPkt = await sendAndWait(
          step: 'HiChain3 Auth Step2',
          serviceId: _serviceId,
          commandId: _cmdHiChain,
          tlv: buildHiChainRequestTlv(
            operationCode: 0x01,
            requestId: requestIdAuth,
            messageId: 0x02,
            payloadExtra: {
              'peerAuthId': hex(selfAuthId),
              'token': hex(selfTokenAuth),
            },
            outerExtra: const {},
          ),
          encryptedTlV: false,
          isSliced: true,
        );

        final payload2Auth = parseHiChainPayload(step2AuthPkt.tlv);
        final returnCodeMacHexAuth = payload2Auth['returnCodeMac'] as String?;
        final errCode2 = payload2Auth['errorCode'];
        if (returnCodeMacHexAuth == null) {
          debugPrint(
            '⚠️ [PAIR] HiChain3 auth step2 payload parse issue: keys=${payload2Auth.keys} errorCode=$errCode2 payload=$payload2Auth',
          );
          throw StateError('HiChain3 auth step2 missing returnCodeMac');
        }
        final Uint8List returnCodeMacAuth = hexToBytes(returnCodeMacHexAuth);
        final expectedReturnCodeMacAuth = HuaweiCrypto.hmacSha256(
          pskAuth,
          Uint8List(4),
        );
        if (!listEquals(returnCodeMacAuth, expectedReturnCodeMacAuth)) {
          debugPrint(
            '⚠️ [PAIR] HiChain3 auth returnCodeMac mismatch (continuing). computed=${hex(expectedReturnCodeMacAuth)} device=${hex(returnCodeMacAuth)}',
          );
        }

        // Step 3 (auth)
        final Uint8List saltAuth = concatBytes([randSelfAuth, randPeerAuth]);
        final Uint8List sessionKeyAuth = HuaweiCrypto.hkdfSha256(
          secretKey: pskAuth,
          salt: saltAuth,
          info: hkdfInfoSession,
          outputLength: 32,
        );

        final Uint8List nonceStep3Auth = randomBytes(12);
        final Uint8List challengeAuth = randomBytes(16);
        final Uint8List encDataAuth = HuaweiCrypto.encryptAesGcmNoPadWithAad(
          challengeAuth,
          sessionKeyAuth,
          nonceStep3Auth,
          aadIsoExchange,
        );

        final step3AuthPkt = await sendAndWait(
          step: 'HiChain3 Auth Step3',
          serviceId: _serviceId,
          commandId: _cmdHiChain,
          tlv: buildHiChainRequestTlv(
            operationCode: 0x01,
            requestId: requestIdAuth,
            messageId: 0x03,
            payloadExtra: {
              'nonce': hex(nonceStep3Auth),
              'encData': hex(encDataAuth),
            },
            outerExtra: const {},
          ),
          encryptedTlV: false,
          isSliced: true,
        );

        final payload3Auth = parseHiChainPayload(step3AuthPkt.tlv);
        final Uint8List nonceRespAuth = hexToBytes(
          payload3Auth['nonce'] as String,
        );
        final Uint8List encAuthTokenAuth = hexToBytes(
          payload3Auth['encAuthToken'] as String,
        );
        final Uint8List authToken = HuaweiCrypto.decryptAesGcmNoPadWithAad(
          encAuthTokenAuth,
          sessionKeyAuth,
          nonceRespAuth,
          challengeAuth,
        );

        // Step 4 (auth)
        final Uint8List nonceStep4Auth = randomBytes(12);
        final Uint8List encResultAuth = HuaweiCrypto.encryptAesGcmNoPadWithAad(
          Uint8List(4),
          sessionKeyAuth,
          nonceStep4Auth,
          aadIsoResult,
        );

        await sendAndWait(
          step: 'HiChain3 Auth Step4',
          serviceId: _serviceId,
          commandId: _cmdHiChain,
          tlv: buildHiChainRequestTlv(
            operationCode: 0x01,
            requestId: requestIdAuth,
            messageId: 0x04,
            payloadExtra: {
              'nonce': hex(nonceStep4Auth),
              'encResult': hex(encResultAuth),
              'operationCode': 0x01,
            },
            outerExtra: const {},
          ),
          encryptedTlV: false,
          isSliced: true,
          maxRetries: 0,
        );

        stage = 'HiChain3 bind (0x01/0x28)';
        final int requestIdBind = DateTime.now().millisecondsSinceEpoch;
        final Uint8List seedBind = randomBytes(32);
        final Uint8List randSelfBind = randomBytes(16);

        // Step 1 (bind)
        final step1BindPkt = await sendAndWait(
          step: 'HiChain3 Bind Step1',
          serviceId: _serviceId,
          commandId: _cmdHiChain,
          tlv: buildHiChainRequestTlv(
            operationCode: 0x02,
            requestId: requestIdBind,
            messageId: 0x01,
            payloadExtra: {
              'isoSalt': hex(randSelfBind),
              'peerAuthId': hex(selfAuthId),
              'operationCode': 0x02,
              'seed': hex(seedBind),
              'peerUserType': 0x00,
              'pkgName': 'com.huawei.devicegroupmanage',
              'serviceType': groupId,
              'keyLength': 0x20,
            },
            outerExtra: const {'isDeviceLevel': false},
          ),
          encryptedTlV: false,
          isSliced: true,
        );

        final payload1Bind = parseHiChainPayload(step1BindPkt.tlv);
        final isoSaltHexBind = payload1Bind['isoSalt'] as String?;
        final peerAuthIdHexBind = payload1Bind['peerAuthId'] as String?;
        final tokenHexBind = payload1Bind['token'] as String?;
        final errCode1b = payload1Bind['errorCode'];
        if (isoSaltHexBind == null ||
            peerAuthIdHexBind == null ||
            tokenHexBind == null) {
          debugPrint(
            '⚠️ [PAIR] HiChain3 bind step1 payload parse issue: keys=${payload1Bind.keys} errorCode=$errCode1b payload=$payload1Bind',
          );
          throw StateError(
            'HiChain3 bind step1 missing isoSalt/peerAuthId/token',
          );
        }
        final Uint8List randPeerBind = hexToBytes(isoSaltHexBind);
        final Uint8List authIdPeerBind = hexToBytes(peerAuthIdHexBind);
        final Uint8List peerTokenBind = hexToBytes(tokenHexBind);

        final Uint8List pskBind = HuaweiCrypto.hmacSha256(authToken, seedBind);
        // gadgetbridge:
        // - tokenCheck (peerToken) = HMAC(psk, randPeer + randSelf + authIdSelf + authIdPeer)
        // - selfToken (sent in Step2) = HMAC(psk, randSelf + randPeer + authIdPeer + authIdSelf)
        final peerMsgBind = concatBytes([
          randPeerBind,
          randSelfBind,
          selfAuthId,
          authIdPeerBind,
        ]);
        final tokenCheckBind = HuaweiCrypto.hmacSha256(pskBind, peerMsgBind);
        if (!listEquals(tokenCheckBind, peerTokenBind)) {
          debugPrint(
            '⚠️ [PAIR] HiChain3 bind peerToken mismatch; computed=${hex(tokenCheckBind)} device=${hex(peerTokenBind)}',
          );
        }

        final selfMsgBind = concatBytes([
          randSelfBind,
          randPeerBind,
          authIdPeerBind,
          selfAuthId,
        ]);
        final selfTokenBind = HuaweiCrypto.hmacSha256(pskBind, selfMsgBind);

        // Step 2 (bind)
        final step2BindPkt = await sendAndWait(
          step: 'HiChain3 Bind Step2',
          serviceId: _serviceId,
          commandId: _cmdHiChain,
          tlv: buildHiChainRequestTlv(
            operationCode: 0x02,
            requestId: requestIdBind,
            messageId: 0x02,
            payloadExtra: {
              'peerAuthId': hex(selfAuthId),
              'token': hex(selfTokenBind),
            },
            outerExtra: const {'isDeviceLevel': false},
          ),
          encryptedTlV: false,
          isSliced: true,
        );

        final payload2Bind = parseHiChainPayload(step2BindPkt.tlv);
        final returnCodeMacHexBind = payload2Bind['returnCodeMac'] as String?;
        final errCode2b = payload2Bind['errorCode'];
        if (returnCodeMacHexBind == null) {
          debugPrint(
            '⚠️ [PAIR] HiChain3 bind step2 payload parse issue: keys=${payload2Bind.keys} errorCode=$errCode2b payload=$payload2Bind',
          );
          throw StateError('HiChain3 bind step2 missing returnCodeMac');
        }
        final Uint8List returnCodeMacBind = hexToBytes(returnCodeMacHexBind);
        final expectedReturnCodeMacBind = HuaweiCrypto.hmacSha256(
          pskBind,
          Uint8List(4),
        );
        if (!listEquals(returnCodeMacBind, expectedReturnCodeMacBind)) {
          debugPrint(
            '⚠️ [PAIR] HiChain3 bind returnCodeMac mismatch (continuing). computed=${hex(expectedReturnCodeMacBind)} device=${hex(returnCodeMacBind)}',
          );
        }

        // Step 3 (bind) and Step 4 (bind response).
        // Проблема вашего лога как раз в пропуске сообщения с message=0x13.
        // Делаем явный Step3, после чего ждём ответ Step4.
        final Uint8List saltBind = concatBytes([randSelfBind, randPeerBind]);
        final Uint8List sessionKeyBind = HuaweiCrypto.hkdfSha256(
          secretKey: pskBind,
          salt: saltBind,
          info: hkdfInfoSession,
          outputLength: 32,
        );

        final Uint8List nonceStep3Bind = randomBytes(12);
        final Uint8List encResultBind = HuaweiCrypto.encryptAesGcmNoPadWithAad(
          Uint8List(4),
          sessionKeyBind,
          nonceStep3Bind,
          aadIsoResult,
        );

        final step3BindTlv = buildHiChainRequestTlv(
          operationCode: 0x02,
          requestId: requestIdBind,
          messageId: 0x03, // effective message becomes 0x13 for bind.
          payloadExtra: {
            // Step3 повторяет peerAuthId/token из Step2 и добавляет nonce/encResult.
            'peerAuthId': hex(selfAuthId),
            'token': hex(selfTokenBind),
            'encResult': hex(encResultBind),
            'nonce': hex(nonceStep3Bind),
            'operationCode': 0x02,
          },
          outerExtra: const {'isDeviceLevel': false},
        );

        // Некоторые прошивки могут не прислать ответ на Step4, но мы ждём его
        // в тех же рамках, что и раньше (и для Band10 это критично).
        await sendPacket(
          serviceId: _serviceId,
          commandId: _cmdHiChain,
          tlv: step3BindTlv,
          encryptedTlV: false,
          isSliced: true,
        );
        try {
          final step4RespPkt = await waitPacket(_serviceId, _cmdHiChain);
          try {
            final payload4 = parseHiChainPayload(step4RespPkt.tlv);
            debugPrint(
              '🧾 [PAIR] HiChain3 bind Step4 payload keys=${payload4.keys} errorCode=${payload4['errorCode']} returnCodeMac=${payload4['returnCodeMac']}',
            );
          } catch (e) {
            debugPrint(
              '⚠️ [PAIR] HiChain3 bind Step4 payload parse failed: $e',
            );
          }
        } on TimeoutException catch (_) {
          if (deviceSupportType == 0x04) {
            // For Band 10 (HiChain3), skipping init after this timeout reduces
            // the chance of device-side disconnect on SupportedServices.
            throw StateError(
              'HiChain3 bind Step4 response timeout (Band10) after Step3',
            );
          }
          debugPrint(
            '⚠️ [PAIR] HiChain3 bind Step4 response timeout after Step3, continuing...',
          );
        } catch (_) {
          debugPrint(
            '⚠️ [PAIR] HiChain3 bind Step4 response timeout after Step3, continuing...',
          );
        }

        // gadgetbridge: key = hkdfSha256(sessionKey, salt, info="hichain_return_key", 32)
        secretKey = HuaweiCrypto.hkdfSha256(
          secretKey: sessionKeyBind,
          salt: saltBind,
          info: hkdfInfoReturn,
          outputLength: 32,
        );

        debugPrint(
          '🔐 [PAIR] HiChain3 derived secretKey (len=${secretKey.length})',
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
        final productModelBytes = productTlvResp.containsTag(0x0A)
            ? productTlvResp.getBytes(0x0A)
            : null;
        final productModel = productModelBytes == null
            ? null
            : utf8.decode(productModelBytes).trim();
        debugPrint(
          '🏷️ [PAIR] ProductInfo parsed (model=${productModel ?? 'null'})',
        );

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

        debugPrint('🔋 [PAIR] BatteryPacket: ${batteryPacket.tlv.serialize()}');
        final batteryTlvResp = decryptIfNeeded(batteryPacket.tlv);
        int? batteryLevel = extractBatteryLevelFromTlv(batteryTlvResp);

        // Some firmwares may return only an ACK/status TLV for BatteryLevel request.
        // In that case, the real level is sent later as BatteryLevel.id_change (0x01/0x27).
        if (batteryLevel == null) {
          debugPrint(
            '🔋 [PAIR] BatteryLevel tag 0x01 missing, waiting async BatteryLevel (0x01/0x27)...',
          );
          try {
            final batteryChangePacket = await waitPacket(
              _serviceId,
              _cmdBatteryLevelChange,
            );
            final batteryChangeTlvResp =
                decryptIfNeeded(batteryChangePacket.tlv);
            debugPrint(
              '🔋 [PAIR] BatteryLevel change decrypted tags: has01=${batteryChangeTlvResp.containsTag(0x01)} has02=${batteryChangeTlvResp.containsTag(0x02)} has03=${batteryChangeTlvResp.containsTag(0x03)}',
            );
            batteryLevel = extractBatteryLevelFromTlv(batteryChangeTlvResp);
          } catch (_) {
            batteryLevel = null;
          }
        }

        // Some firmwares may deliver the actual battery level under the same commandId (0x08)
        // after the initial ACK/status.
        if (batteryLevel == null) {
          debugPrint(
            '🔋 [PAIR] BatteryLevel still missing, waiting another BatteryLevel (0x01/0x08)...',
          );
          try {
            final batteryPacket2 = await waitPacket(
              _serviceId,
              _cmdBatteryLevel,
            );
            final batteryTlvResp2 = decryptIfNeeded(batteryPacket2.tlv);
            batteryLevel = extractBatteryLevelFromTlv(batteryTlvResp2);
          } catch (_) {
            batteryLevel = null;
          }
        }
        debugPrint('🔋 [PAIR] BatteryLevel parsed (${batteryLevel ?? "null"})');

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

        // Считаем pairing успешным только если батарея реально получена.
        // `productModel` у некоторых прошивок может отсутствовать в раннем ответе,
        // но это не должно блокировать чтение батареи.
        if (batteryLevel == null || batteryLevel <= 0) {
          throw StateError('Init did not return BatteryLevel');
        }

        return HuaweiPairingResult(
          deviceId: deviceId,
          productModel: productModel,
          batteryLevel: batteryLevel,
        );
      }

      // 2) Secret key (random per session).
      stage = 'generate session keys';
      secretKey = HuaweiCrypto.generateNonce();

      // 3) Optional PinCode for HiChainLite when authVersion != 0x02.
      if (authMode == 0x02 && authVersion != 0x02) {
        stage = 'PinCode (0x01/0x2C)';
        debugPrint(
          '🧩 [PAIR] Request PinCode (required for this authVersion in current implementation)',
        );
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
        final crypto = HuaweiCrypto(
          authVersion,
          authAlgo,
          deviceSupportType,
          authMode,
        );
        pinCode = crypto.decryptPinCode(encryptMethod, message, iv);
        debugPrint(
          '🔑 [PAIR] PinCode decrypted (messageLen=${message.length})',
        );
      }

      // 4) Auth: Auth (0x01/0x13)
      stage = 'Auth (0x01/0x13)';
      debugPrint('🧬 [PAIR] Prepare Auth challenge and send Auth');
      final clientNonce = HuaweiCrypto.generateNonce();
      final doubleNonce = Uint8List(32)
        ..setRange(0, 16, serverNonce)
        ..setRange(16, 32, clientNonce);

      final nonce = Uint8List(18);
      nonce[0] = (authVersion >> 8) & 0xFF;
      nonce[1] = authVersion & 0xFF;
      nonce.setRange(2, 18, clientNonce);

      final crypto = HuaweiCrypto(
        authVersion,
        authAlgo,
        deviceSupportType,
        authMode,
      );

      final Uint8List? secretForAuth;
      if (authMode == 0x02) {
        secretForAuth = (authVersion == 0x02) ? secretKey : pinCode;
      } else {
        secretForAuth = null;
      }
      if (secretForAuth == null && authMode == 0x02) {
        throw StateError('PinCode/secretKey missing for authMode=0x02');
      }

      final digestChallenge = crypto.digestChallenge(
        secretForAuth,
        doubleNonce,
      );
      if (digestChallenge == null) {
        throw StateError('digestChallenge is null');
      }
      final challenge = digestChallenge.sublist(0, 32);
      firstKey = digestChallenge.sublist(32, 48);
      debugPrint(
        '🔐 [PAIR] Auth prepared (challengeLen=${challenge.length}, firstKeyLen=${firstKey.length})',
      );

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
      debugPrint(
        '📐 [PAIR] BondParams parsed (encryptionCounter=$encryptionCounter)',
      );

      // 6) Bond: Bond (0x01/0x0E)
      stage = 'Bond (0x01/0x0E)';
      final iv = getIv();
      final encryptionKey = authMode == 0x02
          ? firstKey
          : crypto.createSecretKey(deviceId);
      final bondingKey = crypto.encryptBondingKey(
        encryptMethod,
        secretKey,
        encryptionKey,
        iv,
      );
      debugPrint(
        '🧰 [PAIR] Prepared Bond payload (bondingKeyLen=${bondingKey.length}, ivLen=${iv.length})',
      );

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
      final productModelBytes = productTlvResp.containsTag(0x0A)
          ? productTlvResp.getBytes(0x0A)
          : null;
      final productModel = productModelBytes == null
          ? null
          : utf8.decode(productModelBytes).trim();
      debugPrint(
        '🏷️ [PAIR] ProductInfo parsed (model=${productModel ?? 'null'})',
      );

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
      int? batteryLevelMaybe = extractBatteryLevelFromTlv(batteryTlvResp);
      if (batteryLevelMaybe == null) {
        // Fallback to async battery update.
        debugPrint(
          '🔋 [PAIR] BatteryLevel tag 0x01 missing, waiting async BatteryLevel (0x01/0x27)...',
        );
        try {
          final batteryChangePacket = await waitPacket(
            _serviceId,
            _cmdBatteryLevelChange,
          );
          final batteryChangeTlvResp =
              decryptIfNeeded(batteryChangePacket.tlv);
          debugPrint(
            '🔋 [PAIR] BatteryLevel change decrypted tags: has01=${batteryChangeTlvResp.containsTag(0x01)} has02=${batteryChangeTlvResp.containsTag(0x02)} has03=${batteryChangeTlvResp.containsTag(0x03)}',
          );
          batteryLevelMaybe = extractBatteryLevelFromTlv(batteryChangeTlvResp);
        } catch (_) {
          batteryLevelMaybe = null;
        }
      }

      if (batteryLevelMaybe == null) {
        // Some firmwares may deliver the actual battery level under the same
        // commandId (0x08) after the initial ACK/status.
        debugPrint(
          '🔋 [PAIR] BatteryLevel still missing, waiting another BatteryLevel (0x01/0x08)...',
        );
        try {
          final batteryPacket2 = await waitPacket(
            _serviceId,
            _cmdBatteryLevel,
          );
          final batteryTlvResp2 = decryptIfNeeded(batteryPacket2.tlv);
          batteryLevelMaybe = extractBatteryLevelFromTlv(batteryTlvResp2);
        } catch (_) {
          batteryLevelMaybe = null;
        }
      }

      final int batteryLevel = batteryLevelMaybe ?? 0;
      debugPrint('🔋 [PAIR] BatteryLevel parsed (${batteryLevelMaybe ?? "null"})');

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

      // Считаем pairing успешным только если батарея реально получена.
      if (batteryLevel <= 0) {
        throw StateError('Init did not return BatteryLevel');
      }

      return HuaweiPairingResult(
        deviceId: deviceId,
        productModel: productModel,
        batteryLevel: batteryLevel,
      );
    } catch (e, st) {
      failed = true;
      debugPrint('❌ [PAIR] Failed at stage="$stage": $e\n$st');
      rethrow;
    } finally {
      await sub?.cancel();
      // Keep the connection for UI; just stop notification stream to reduce noise.
      try {
        await UniversalBle.unsubscribe(deviceId, _serviceUuid, _rxUuid);
      } catch (_) {}

      // If pairing/auth failed, make sure we fully disconnect.
      // Otherwise some devices stop advertising and won't show up again in scanStream.
      if (failed && _disconnectOnPairingFailure) {
        try {
          await UniversalBle.disconnect(deviceId);
        } catch (_) {}
      }
    }
  }

  Future<String?> _getAndroidId() async {
    try {
      if (defaultTargetPlatform != TargetPlatform.android) {
        return null;
      }
      final info = DeviceInfoPlugin();
      final androidInfo = await info.androidInfo;
      final androidId = androidInfo.id;
      return androidId.isNotEmpty ? androidId : null;
    } catch (e, st) {
      debugPrint('⚠️ [PAIR] Failed to read AndroidId: $e\n$st');
      return null;
    }
  }

  /// Gadgetbridge передаёт в TLV `SecurityNegotiation` ASCII hex строку ровно 32 символа.
  /// Важно: нельзя дополнять байтами `0x00`, иначе устройство может молчать.
  String _normalizeDeviceUuidHex32(String source) {
    final hexOnly = source.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (hexOnly.isEmpty) return '0'.padRight(32, '0');
    if (hexOnly.length >= 32) return hexOnly.substring(0, 32);
    return hexOnly.padRight(32, '0');
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
