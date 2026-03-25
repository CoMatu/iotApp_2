# Huawei Band 10: Pairing и чтение параметров в Flutter

Этот документ предназначен для AI-агента в Flutter-проекте.  
Цель: реализовать подключение к `Huawei Band 10`, пройти сопряжение (auth/bond) и читать основные параметры.

Исходный код приложения, с которого переписывали логику, лежит /Users/comatu/Pulkovo/gadgetbridge (используй его для проверки логики)

## 1) Что искать при BLE-сканировании

- Имя устройства: префикс `huawei band 10-` (регистр не важен)
- Основной BLE service UUID: `0000FE86-0000-1000-8000-00805F9B34FB`
- Characteristic для записи: `0000FE01-0000-1000-8000-00805F9B34FB`
- Characteristic для чтения/notify: `0000FE02-0000-1000-8000-00805F9B34FB`

## 2) Низкоуровневый формат Huawei-пакета

Huawei использует собственный контейнер поверх BLE:

- `magic`: `0x5A`
- `length`: 2 байта
- флаги slice/fragment
- `serviceId`: 1 байт
- `commandId`: 1 байт
- TLV payload
- CRC16 в конце

Важно:

- Есть sliced/unsliced режимы (фрагментация крупных пакетов).
- MTU и размер slice приходят от устройства на шаге `LinkParams`.
- Часть команд нешифрованные (особенно ранний handshake), далее используется шифрование TLV по negotiated параметрам.

## 3) Минимальная последовательность подключения (state machine)

Ниже минимальная инициализация, повторяющая рабочую логику:

1. Подключиться к GATT.
2. Включить notify на `FE02`.
3. Отправить `DeviceConfig.LinkParams` (`serviceId=0x01`, `commandId=0x01`).
4. Разобрать ответ и сохранить:
   - `mtu`
   - `sliceSize`
   - `authVersion`
   - `serverNonce`
   - `deviceSupportType`
   - `authAlgo`
   - `encryptMethod`
5. Определить режим аутентификации:
   - через `DeviceConfig.SecurityNegotiation` (`0x01/0x33`) или
   - сразу normal flow (зависит от `deviceSupportType`).
6. Выполнить auth/bond цепочку:
   - `Auth` (`0x01/0x13`)
   - `BondParams` (`0x01/0x0F`)
   - `Bond` (`0x01/0x0E`)
7. После успеха отправить init-команды:
   - `ProductInfo` (`0x01/0x07`)
   - `TimeRequest` (`0x01/0x05`)
   - `BatteryLevel` (`0x01/0x08`)
   - `SupportedServices` (`0x01/0x02`)
8. Далее по возможностям устройства запросить нужные данные.

## 3.1) Алгоритм подключения и установления сопряжения (pairing)
Используй эту последовательность как чеклист верхнего уровня:
1. BLE scan: найти устройство с именем/префиксом `huawei band 10-`, затем подключиться к GATT.
2. Поднять transport: включить `notify` на characteristic `FE02`, убедиться, что `write` доступен на `FE01`.
3. LinkParams:
   - отправить `DeviceConfig.LinkParams` (`0x01/0x01`) с учетом Huawei-провайдера (CRC16 и slicing),
   - дождаться ответа и сохранить `mtu`, `sliceSize`, `authVersion`, `serverNonce`, `deviceSupportType`, `authAlgo`, `encryptMethod`.
4. Security negotiation (если требуется):
   - если `deviceSupportType`/ответ указывает на необходимость, отправить `DeviceConfig.SecurityNegotiation` (`0x01/0x33`),
   - из ответа вывести ветку auth/bond, которую нужно выполнить.
5. Auth/Bond цепочка:
   - отправить `Auth` (`0x01/0x13`) и обработать challenge/response (при необходимости подготовить данные из `serverNonce`),
   - отправить `BondParams` (`0x01/0x0F`),
   - отправить `Bond` (`0x01/0x0E`).
6. Критерий success pairing:
   - последующие команды принимаются без auth ошибок,
   - успешно читаются `ProductInfo` (`0x01/0x07`) и `BatteryLevel` (`0x01/0x08`).
7. После success initialization:
   - запросить `SupportedServices` (`0x01/0x02`) и продолжить работу по capabilities,
   - при необходимости запросить `TimeRequest` (`0x01/0x05`) и другие поддерживаемые сущности.

## 3.2) Таймауты и ретраи (для pairing)
Ориентиры для верхнеуровневого контроллера:
1. Таймаут на каждый шаг handshake: `5-10 секунд`.
2. На `timeout`: повторить текущий шаг один раз, затем сделать полный `reconnect` и начать с `LinkParams`.
3. Если CRC/длина не сходятся на sliced-пакете: сбросить текущую сборку и вернуться к шагу после `LinkParams`.
4. Если получен auth mismatch: начать pairing заново с шага `LinkParams`.

## 4) Коды команд, критичные для старта

Базовый `serviceId` для конфигурации: `DeviceConfig = 0x01`

- `LinkParams = 0x01`
- `SupportedServices = 0x02`
- `ProductInfo = 0x07`
- `BatteryLevel = 0x08`
- `Bond = 0x0E`
- `BondParams = 0x0F`
- `Auth = 0x13`
- `SecurityNegotiation = 0x33`
- `PinCode = 0x2C` (в некоторых сценариях первого сопряжения)

## 5) Что считать «успешным сопряжением»

Считать pairing успешным, когда:

- пройдены `Auth` + `BondParams/Bond` (или эквивалентный HiChain сценарий),
- устройство переходит в рабочее состояние,
- успешно читаются `ProductInfo` и `BatteryLevel`,
- последующие команды принимаются без auth ошибок.

## 6) Какие параметры читать в первую очередь

Минимальный полезный набор:

1. Инфо устройства (`ProductInfo`):
   - модель
   - серийный номер
   - версии ПО/железа
2. Батарея (`BatteryLevel`)
3. Список поддерживаемых сервисов (`SupportedServices`)
4. (Опционально) список поддерживаемых команд (`SupportedCommands`, `0x01/0x03`)

Рекомендация: не «хардкодить» функциональность по модели.  
Всегда ориентироваться на `SupportedServices/SupportedCommands` из ответа устройства.

## 7) Практическая структура Flutter-кода

Разделить на отдельные компоненты:

- `ble_transport.dart`
  - scan/connect/disconnect
  - write на `FE01`
  - subscribe notify `FE02`
- `huawei_packet_codec.dart`
  - encode/decode заголовка Huawei
  - CRC16
  - slicing/reassembly
- `huawei_tlv.dart`
  - TLV encode/decode
- `huawei_crypto.dart`
  - challenge/response
  - ключи/nonce/iv
  - encrypt/decrypt TLV (где требуется)
- `huawei_pairing_manager.dart`
  - state machine handshake
  - таймауты/ретраи
- `huawei_capabilities.dart`
  - хранение поддерживаемых сервисов/команд

## 8) Ошибки и ретраи

- Таймаут на каждый handshake шаг: 5-10 секунд.
- На timeout:
  - один повтор шага,
  - затем полный reconnect.
- Если CRC/длина не сходится: сбросить текущую сборку sliced-пакета.
- Если auth mismatch: начать handshake заново с `LinkParams`.

## 9) Минимальный псевдокод пайплайна

```text
scan(namePrefix: "huawei band 10-", service: FE86)
connect(device)
enableNotify(FE02)

send(LinkParams)
link = await waitResponse(0x01, 0x01)
save(link.mtu, link.sliceSize, link.authVersion, link.serverNonce, ...)

mode = decideAuthMode(link.deviceSupportType)
if (mode.requiresSecurityNegotiation) {
  send(SecurityNegotiation)
  sec = await waitResponse(0x01, 0x33)
  mode = deriveMode(sec)
}

runAuthBondChain(mode)

send(ProductInfo);      info = waitResponse(0x01, 0x07)
send(BatteryLevel);     batt = waitResponse(0x01, 0x08)
send(SupportedServices);caps = waitResponse(0x01, 0x02)
```

## 10) Что важно для AI-агента

- Это не стандартный GATT-протокол, а бинарный Huawei-протокол в `FE01/FE02`.
- Ключевая сложность: корректная сериализация пакетов, TLV, CRC16, slicing и auth-цепочка.
- Для `Band 10` нет отдельного уникального протокола, используется общий Huawei BLE-flow.
- Успешность интеграции проверять не по «подключился BLE», а по прохождению `Auth/Bond` и ответам `ProductInfo/Battery`.
