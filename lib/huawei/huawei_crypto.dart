import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';

/// Huawei (LPv2/TLV) crypto port from gadgetbridge.
///
/// Implements challenge/response (Auth) and encryption for TLV (after Bond).
class HuaweiCrypto {
  // Constants from gadgetbridge HuaweiConstants/HuaweiCrypto.
  static const List<int> SECRET_KEY_1_V1 = [
    0x6F,
    0x75,
    0x6A,
    0x79,
    0x6D,
    0x77,
    0x71,
    0x34,
    0x63,
    0x6C,
    0x76,
    0x39,
    0x33,
    0x37,
    0x38,
    0x79,
  ];
  static const List<int> SECRET_KEY_2_V1 = [
    0x62,
    0x31,
    0x30,
    0x6A,
    0x67,
    0x66,
    0x64,
    0x39,
    0x79,
    0x37,
    0x76,
    0x73,
    0x75,
    0x64,
    0x61,
    0x39,
  ];
  static const List<int> SECRET_KEY_1_V23 = [
    0x55,
    0x53,
    0x86,
    0xFC,
    0x63,
    0x20,
    0x07,
    0xAA,
    0x86,
    0x49,
    0x35,
    0x22,
    0xB8,
    0x6A,
    0xE2,
    0x5C,
  ];
  static const List<int> SECRET_KEY_2_V23 = [
    0x33,
    0x07,
    0x9B,
    0xC5,
    0x7A,
    0x88,
    0x6D,
    0x3C,
    0xF5,
    0x61,
    0x37,
    0x09,
    0x6F,
    0x22,
    0x80,
    0x00,
  ];

  static const List<int> DIGEST_SECRET_V1 = [
    0x70,
    0xFB,
    0x6C,
    0x24,
    0x03,
    0x5F,
    0xDB,
    0x55,
    0x2F,
    0x38,
    0x89,
    0x8A,
    0xEE,
    0xDE,
    0x3F,
    0x69,
  ];
  static const List<int> DIGEST_SECRET_V2 = [
    0x93,
    0xAC,
    0xDE,
    0xF7,
    0x6A,
    0xCB,
    0x09,
    0x85,
    0x7D,
    0xBF,
    0xE5,
    0x26,
    0x1A,
    0xAB,
    0xCD,
    0x78,
  ];
  static const List<int> DIGEST_SECRET_V3 = [
    0x9C,
    0x27,
    0x63,
    0xA9,
    0xCC,
    0xE1,
    0x34,
    0x76,
    0x6D,
    0xE3,
    0xFF,
    0x61,
    0x18,
    0x20,
    0x05,
    0x53,
  ];

  // Messages used during digest.
  static final Uint8List MESSAGE_CHALLENGE = Uint8List.fromList([0x01, 0x00]);
  static final Uint8List MESSAGE_RESPONSE = Uint8List.fromList([0x01, 0x10]);
  static final Uint8List MESSAGE_CHALLENGE_V4 = Uint8List.fromList([0x04, 0x00]);

  static const int ENCRYPTION_COUNTER_MAX = 0xFFFFFFFF;

  final int authVersion;
  final int authAlgo;
  final int deviceSupportType;
  final int authMode;

  HuaweiCrypto(this.authVersion, this.authAlgo, this.deviceSupportType, this.authMode);

  static Uint8List generateNonce() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
  }

  Uint8List getDigestSecretBytes() {
    if (authVersion == 1 || authVersion == 4) {
      return Uint8List.fromList(List<int>.from(DIGEST_SECRET_V1));
    }
    if (authVersion == 2) {
      return Uint8List.fromList(List<int>.from(DIGEST_SECRET_V2));
    }
    return Uint8List.fromList(List<int>.from(DIGEST_SECRET_V3));
  }

  Uint8List _hmacSha256(Uint8List key, Uint8List message) {
    final h = Hmac(sha256, key);
    return Uint8List.fromList(h.convert(message).bytes);
  }

  Uint8List _sha256(Uint8List bytes) {
    return Uint8List.fromList(sha256.convert(bytes).bytes);
  }

  String _hexdumpUpper(Uint8List bytes) {
    const hexChars = '0123456789ABCDEF';
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(hexChars[(b >> 4) & 0x0F]);
      out.write(hexChars[b & 0x0F]);
    }
    return out.toString();
  }

  Uint8List _pbkdf2Sha256(String key, String salt, int count, int lengthBits) {
    // gadgetbridge CryptoUtils.pbkdf2Sha256(key.toCharArray(), salt.getBytes(UTF_8), ...)
    // We mimic "char to byte" by taking the low 8 bits for ASCII hex chars.
    final passwordBytes = Uint8List.fromList(key.codeUnits.map((c) => c & 0xFF).toList());
    final saltBytes = Uint8List.fromList(utf8.encode(salt));
    final outLenBytes = lengthBits ~/ 8;
    final out = Uint8List(outLenBytes);

    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    derivator.init(Pbkdf2Parameters(saltBytes, count, outLenBytes));
    derivator.deriveKey(passwordBytes, 0, out, 0);
    return out;
  }

  Uint8List _computeDigest(Uint8List message, Uint8List nonce) {
    final digestSecret = getDigestSecretBytes();
    final msgToDigest = Uint8List(digestSecret.length + message.length)
      ..setAll(0, digestSecret)
      ..setAll(digestSecret.length, message);

    final digestStep1 = _hmacSha256(msgToDigest, nonce);
    final challengePart = _hmacSha256(digestStep1, nonce);

    final out = Uint8List(0x40);
    out.setRange(0, 0x20, challengePart);
    out.setRange(0x20, 0x40, digestStep1);
    return out;
  }

  Uint8List _computeDigestHiChainLite(Uint8List message, Uint8List key, Uint8List nonce) {
    // hashKey = sha256(hexdump(key).utf8)
    final hashKey = _sha256(Uint8List.fromList(utf8.encode(_hexdumpUpper(key))));

    final digestSecret = getDigestSecretBytes();
    for (var i = 0; i < digestSecret.length; i++) {
      digestSecret[i] = ((hashKey[i] ^ digestSecret[i]) & 0xFF);
    }

    // msgToDigest = digestSecret + message
    final msgToDigest = Uint8List(digestSecret.length + message.length)
      ..setAll(0, digestSecret)
      ..setAll(digestSecret.length, message);

    late final Uint8List digestStep1;
    if (authAlgo == 0x01) {
      digestStep1 = _pbkdf2Sha256(
        _hexdumpUpper(msgToDigest),
        _hexdumpUpper(nonce),
        0x3e8,
        0x100,
      );
    } else {
      // CryptoUtils.calcHmacSha256(msgToDigest, nonce) => key=msgToDigest, data=nonce
      digestStep1 = _hmacSha256(msgToDigest, nonce);
    }

    final challengePart = _hmacSha256(digestStep1, nonce);

    final out = Uint8List(0x40);
    out.setRange(0, 0x20, challengePart);
    out.setRange(0x20, 0x40, digestStep1);
    return out;
  }

  Uint8List? digestChallenge(Uint8List? secretKey, Uint8List nonce) {
    if (authMode == 0x02) {
      if (secretKey == null) return null;

      if (authVersion == 0x02) {
        final key = Uint8List(18)
          ..setAll(0, secretKey)
          ..setAll(secretKey.length, MESSAGE_CHALLENGE);

        final challengeHmac = _hmacSha256(key, nonce);
        final out = Uint8List(0x40);
        out.setRange(0, 0x20, challengeHmac);
        out.setRange(0x20, 0x40, key);
        return out;
      }

      return _computeDigestHiChainLite(MESSAGE_CHALLENGE, secretKey, nonce);
    }

    if (authVersion == 4) {
      return _computeDigest(MESSAGE_CHALLENGE_V4, nonce);
    }
    return _computeDigest(MESSAGE_CHALLENGE, nonce);
  }

  Uint8List? digestResponse(Uint8List? secretKey, Uint8List nonce) {
    if (authMode == 0x02) {
      if (secretKey == null) return null;

      if (authVersion == 0x02) {
        final key = Uint8List(18)
          ..setAll(0, secretKey)
          ..setAll(secretKey.length, MESSAGE_RESPONSE);

        final challengeHmac = _hmacSha256(key, nonce);
        final out = Uint8List(0x40);
        out.setRange(0, 0x20, challengeHmac);
        out.setRange(0x20, 0x40, key);
        return out;
      }

      return _computeDigestHiChainLite(MESSAGE_RESPONSE, secretKey, nonce);
    }

    return _computeDigest(MESSAGE_RESPONSE, nonce);
  }

  static Uint8List initializationVector(int counter) {
    var c = counter;
    if (c == ENCRYPTION_COUNTER_MAX) {
      c = 1;
    } else {
      c += 1;
    }

    final rng = generateNonce();
    final out = Uint8List(16);
    // First 12 bytes: random nonce (first 12 bytes).
    out.setRange(0, 12, rng.sublist(0, 12));

    // Last 4 bytes: int32 from incremented counter (big-endian).
    out[12] = (c >> 24) & 0xFF;
    out[13] = (c >> 16) & 0xFF;
    out[14] = (c >> 8) & 0xFF;
    out[15] = c & 0xFF;
    return out;
  }

  Uint8List encryptBondingKey(int encryptMethod, Uint8List data, Uint8List encryptionKey, Uint8List iv) {
    if (encryptMethod == 0x01) {
      return _encryptAesGcmNoPad(data, encryptionKey, iv);
    }
    return _encryptAesCbcPkcs7(data, encryptionKey, iv);
  }

  Uint8List decryptBondingKey(int encryptMethod, Uint8List data, Uint8List key, Uint8List iv) {
    if (encryptMethod == 0x01) {
      return _decryptAesGcmNoPad(data, key, iv);
    }
    return _decryptAesCbcPkcs7(data, key, iv);
  }

  Uint8List decryptPinCode(int encryptMethod, Uint8List message, Uint8List iv) {
    final secretKey = getDigestSecretBytes();
    if (encryptMethod == 0x01) {
      return _decryptAesGcmNoPad(message, secretKey, iv);
    }
    return _decryptAesCbcPkcs7(message, secretKey, iv);
  }

  static Uint8List encrypt(bool useGcm, Uint8List message, Uint8List key, Uint8List iv) {
    final crypto = HuaweiCrypto(1, 0, 0, 0); // dummy context for helpers.
    if (useGcm) {
      return crypto._encryptAesGcmNoPad(message, key, iv);
    }
    return crypto._encryptAesCbcPkcs7(message, key, iv);
  }

  static Uint8List decrypt(bool useGcm, Uint8List message, Uint8List key, Uint8List iv) {
    final crypto = HuaweiCrypto(1, 0, 0, 0); // dummy context for helpers.
    if (useGcm) {
      return crypto._decryptAesGcmNoPad(message, key, iv);
    }
    return crypto._decryptAesCbcPkcs7(message, key, iv);
  }

  Uint8List createSecretKey(String macAddress) {
    var secretKey1 = Uint8List.fromList(SECRET_KEY_1_V23);
    var secretKey2 = Uint8List.fromList(SECRET_KEY_2_V23);

    if (authVersion == 1) {
      secretKey1 = Uint8List.fromList(SECRET_KEY_1_V1);
      secretKey2 = Uint8List.fromList(SECRET_KEY_2_V1);
    }

    final macAddressKey = Uint8List.fromList(utf8.encode('${macAddress.replaceAll(':', '')}0000'));

    final mixedSecretKey = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      mixedSecretKey[i] = ((((secretKey1[i] & 0xFF) << 4) ^ (secretKey2[i] & 0xFF)) & 0xFF);
    }

    final mixedSecretKeyHash = _sha256(mixedSecretKey);
    final finalMixedKey = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      finalMixedKey[i] =
          ((((mixedSecretKeyHash[i] & 0xFF) >> 6) ^ (macAddressKey[i] & 0xFF)) & 0xFF);
    }

    final finalMixedKeyHash = _sha256(finalMixedKey);
    return Uint8List.fromList(finalMixedKeyHash.sublist(0, 16));
  }

  Uint8List _encryptAesGcmNoPad(Uint8List data, Uint8List key, Uint8List iv) {
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 16 * 8, iv, Uint8List(0));
    cipher.init(true, params);

    final out = Uint8List(cipher.getOutputSize(data.length));
    var offset = cipher.processBytes(data, 0, data.length, out, 0);
    offset += cipher.doFinal(out, offset);
    return out.sublist(0, offset);
  }

  Uint8List _decryptAesGcmNoPad(Uint8List data, Uint8List key, Uint8List iv) {
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 16 * 8, iv, Uint8List(0));
    cipher.init(false, params);

    final out = Uint8List(cipher.getOutputSize(data.length));
    var offset = cipher.processBytes(data, 0, data.length, out, 0);
    offset += cipher.doFinal(out, offset);
    return out.sublist(0, offset);
  }

  /// Huawei HiChain uses AES-GCM with a non-empty AAD.
  /// gadgetbridge uses:
  /// - encrypt(encData): AAD="hichain_iso_exchange".bytes
  /// - decrypt(encAuthToken): AAD=challengeBytes (random 16 bytes)
  static Uint8List encryptAesGcmNoPadWithAad(
    Uint8List data,
    Uint8List key,
    Uint8List iv,
    Uint8List aad,
  ) {
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 16 * 8, iv, aad);
    cipher.init(true, params);

    final out = Uint8List(cipher.getOutputSize(data.length));
    var offset = cipher.processBytes(data, 0, data.length, out, 0);
    offset += cipher.doFinal(out, offset);
    return out.sublist(0, offset);
  }

  static Uint8List decryptAesGcmNoPadWithAad(
    Uint8List data,
    Uint8List key,
    Uint8List iv,
    Uint8List aad,
  ) {
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 16 * 8, iv, aad);
    cipher.init(false, params);

    final out = Uint8List(cipher.getOutputSize(data.length));
    var offset = cipher.processBytes(data, 0, data.length, out, 0);
    offset += cipher.doFinal(out, offset);
    return out.sublist(0, offset);
  }

  static Uint8List hmacSha256(Uint8List key, Uint8List message) {
    final h = Hmac(sha256, key);
    return Uint8List.fromList(h.convert(message).bytes);
  }

  static Uint8List sha256Bytes(Uint8List bytes) {
    return Uint8List.fromList(sha256.convert(bytes).bytes);
  }

  /// Ported from gadgetbridge CryptoUtils.hkdfSha256.
  static Uint8List hkdfSha256({
    required Uint8List secretKey,
    required Uint8List salt,
    required Uint8List info,
    required int outputLength,
  }) {
    const hashLen = 32;

    // pseudoRandomKey = calcHmacSha256(salt, secretKey)  (key=salt, data=secretKey)
    final pseudoRandomKey = hmacSha256(salt, secretKey);

    final n = (outputLength % hashLen == 0)
        ? outputLength ~/ hashLen
        : (outputLength ~/ hashLen) + 1;

    var hashRound = Uint8List(0);
    final generated = Uint8List(n * hashLen);
    var offset = 0;

    // mac init: key = pseudoRandomKey
    for (var roundNum = 1; roundNum <= n; roundNum++) {
      final t = Uint8List(hashRound.length + info.length + 1)
        ..setAll(0, hashRound)
        ..setAll(hashRound.length, info);
      t[t.length - 1] = roundNum & 0xFF;

      hashRound = hmacSha256(pseudoRandomKey, t);
      generated.setRange(offset, offset + hashRound.length, hashRound);
      offset += hashRound.length;
    }

    return generated.sublist(0, outputLength);
  }

  Uint8List _encryptAesCbcPkcs7(Uint8List data, Uint8List key, Uint8List iv) {
    final paddingCipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()));
    paddingCipher.init(
      true,
      PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(key), iv),
        null,
      ),
    );
    return paddingCipher.process(data);
  }

  Uint8List _decryptAesCbcPkcs7(Uint8List data, Uint8List key, Uint8List iv) {
    final paddingCipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()));
    paddingCipher.init(
      false,
      PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(key), iv),
        null,
      ),
    );
    return paddingCipher.process(data);
  }
}

