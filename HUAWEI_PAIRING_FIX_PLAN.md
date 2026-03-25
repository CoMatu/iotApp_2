# Huawei Band 10: почему не работает сопряжение и что менять

## Критичные проблемы

- `lib/huawei/ble_transport.dart`  
  Запись идет через `String.fromCharCodes(bytes)`, а в плагине на Android потом `stringValue.toByteArray()` (UTF-8).  
  Для бинарного протокола Huawei это ломает байты `>= 0x80` (получаются многобайтные UTF-8 последовательности).

- `lib/huawei/huawei_packet_codec.dart`  
  Формат пакета не совпадает с Huawei/Gadgetbridge:
  - CRC считается с seed `0xFFFF`, а нужно `0x0000`;
  - порядок полей CRC/длины должен быть как в Huawei (big-endian в Java `ByteBuffer` по умолчанию);
  - текущая кодировка/декодировка не учитывает sliced packets как в протоколе.

- `lib/huawei/huawei_pairing_manager.dart`  
  На handshake отправляются пустые payload для `LinkParams`, `Auth`, `BondParams`, `Bond`, `SecurityNegotiation`.  
  Это невалидно: у Huawei это TLV-команды с обязательными полями (nonce/challenge/serial/mac/iv и т.д.).

- `lib/huawei/huawei_pairing_manager.dart`  
  `deviceSupportType` читается как `linkParams.payload.first`, но ответ `LinkParams` — TLV, нужно парсить tag `0x07`.

## Что изменить в проекте (по шагам)

1. **Сделать бинарную запись без UTF-8 искажения**
   - Либо изменить плагин `flutter_splendid_ble` (лучше): принимать `List<int>` в MethodChannel и писать `ByteArray` напрямую.
   - Либо временно кодировать `List<int>` в base64 в Dart и декодировать base64 в Kotlin перед `writeCharacteristic`.

2. **Исправить пакетный codec**
   - seed CRC16 = `0x0000`;
   - корректная сборка `0x5A + len + flags + serviceId + commandId + tlv + crc`;
   - добавить reassembly sliced фрагментов (flags `0x01/0x02/0x03`), иначе часть ответов не соберется.

3. **Реализовать TLV-слой отдельно**
   - encode/decode Huawei TLV (varint длины, как в Gadgetbridge).
   - без этого невозможно корректно формировать `LinkParams/Auth/Bond*`.

4. **Реализовать реальный pairing state machine**
   - `LinkParams (0x01/0x01)` -> parse: `authVersion`, `serverNonce`, `authAlgo`, `encryptMethod`, `deviceSupportType`, `mtu`, `sliceSize`.
   - `SecurityNegotiation (0x01/0x33)` при нужном режиме.
   - `Auth (0x01/0x13)` с challenge-response.
   - `BondParams (0x01/0x0F)` и `Bond (0x01/0x0E)` с корректной криптографией.
   - только после успеха: `ProductInfo`, `Battery`, `SupportedServices`.

5. **Добавить детальный лог raw bytes**
   - логировать hex TX/RX до и после decode;
   - логировать `serviceId/commandId` и TLV tags;
   - это сразу покажет, на каком шаге развал.

## Минимальный практический план

- Сначала исправить транспорт (п.1) и codec (п.2), иначе любые попытки pairing бессмысленны.
- Затем внедрить TLV и только `LinkParams` + его parse (без auth).
- Потом добавлять auth/bond по шагам, сверяя каждый пакет с Gadgetbridge.
