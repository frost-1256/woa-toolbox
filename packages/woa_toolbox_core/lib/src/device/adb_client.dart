import 'dart:typed_data';

import '../gpt/gpt_reader.dart';
import 'command_runner.dart';

enum AdbDeviceState {
  device,
  recovery,
  sideload,
  unauthorized,
  offline,
  unknown,
}

class AdbDevice {
  const AdbDevice({required this.serial, required this.state, this.product});
  final String serial;
  final AdbDeviceState state;
  final String? product;

  @override
  String toString() => 'AdbDevice($serial, $state, $product)';
}

/// `adb devices` の出力をパースする（テスト可能な純関数）。
List<AdbDevice> parseAdbDevices(String output) {
  final devices = <AdbDevice>[];
  for (final line in output.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('List of devices')) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final state = switch (parts[1]) {
      'device' => AdbDeviceState.device,
      'recovery' => AdbDeviceState.recovery,
      'sideload' => AdbDeviceState.sideload,
      'unauthorized' => AdbDeviceState.unauthorized,
      'offline' => AdbDeviceState.offline,
      _ => AdbDeviceState.unknown,
    };
    String? product;
    for (final p in parts.skip(2)) {
      if (p.startsWith('product:')) product = p.substring(8);
    }
    devices.add(AdbDevice(serial: parts[0], state: state, product: product));
  }
  return devices;
}

/// ブロックデバイスの物理情報（設計書 §4.1 の単位換算をここで確定させる）。
class BlockDeviceInfo {
  const BlockDeviceInfo({
    required this.logicalSectorSize,
    required this.totalBytes,
    required this.totalLbas,
  });

  final int logicalSectorSize;
  final int totalBytes;
  final int totalLbas;
}

/// /sys/block の値から BlockDeviceInfo を作る。
/// size512 は論理セクタサイズにかかわらず常に 512 バイト単位の値。
/// 容量バイト数 = size512 × 512、総 LBA = 容量バイト数 / 論理セクタサイズ。
/// 割り切れなければ矛盾として例外にする（書き込み系を止める根拠）。
BlockDeviceInfo blockInfoFromSysfs({
  required int logicalSectorSize,
  required int size512,
}) {
  if (logicalSectorSize <= 0 || (logicalSectorSize & (logicalSectorSize - 1)) != 0) {
    throw FormatException('論理セクタサイズが不正です: $logicalSectorSize');
  }
  final totalBytes = size512 * 512;
  if (totalBytes % logicalSectorSize != 0) {
    throw FormatException(
        '容量 ($totalBytes バイト) が論理セクタサイズ ($logicalSectorSize) で割り切れません');
  }
  return BlockDeviceInfo(
    logicalSectorSize: logicalSectorSize,
    totalBytes: totalBytes,
    totalLbas: totalBytes ~/ logicalSectorSize,
  );
}

class AdbClient {
  AdbClient(this._runner, {this.adbExecutable = 'adb'});

  final CommandRunner _runner;
  final String adbExecutable;

  Future<CommandResult> _run(List<String> args) =>
      _runner.run(adbExecutable, args);

  Future<List<AdbDevice>> devices() async {
    final result = await _run(['devices', '-l']);
    if (!result.ok) {
      throw StateError('adb devices が失敗しました: ${result.stderrText}');
    }
    return parseAdbDevices(result.stdoutText);
  }

  Future<String> shellText(String serial, List<String> command) async {
    final result = await _run(['-s', serial, 'shell', ...command]);
    if (!result.ok) {
      throw StateError(
          'adb shell ${command.join(' ')} が失敗しました: ${result.stderrText}');
    }
    return result.stdoutText.trim();
  }

  /// 再起動する。[target] は '' (通常) / 'bootloader' / 'recovery'。
  Future<void> reboot(String serial, {String target = ''}) async {
    final args = ['-s', serial, 'reboot'];
    if (target.isNotEmpty) args.add(target);
    final result = await _run(args);
    if (!result.ok) {
      throw StateError('adb reboot が失敗しました: ${result.stderrText}');
    }
  }

  Future<String?> getProp(String serial, String prop) async {
    final value = await shellText(serial, ['getprop', prop]);
    return value.isEmpty ? null : value;
  }

  /// /sys/block/<dev> から物理情報を読む（[dev] は sysfs 名、例: sda）。
  Future<BlockDeviceInfo> blockInfo(String serial, {String dev = 'sda'}) async {
    final sectorText =
        await shellText(serial, ['cat', '/sys/block/$dev/queue/logical_block_size']);
    final sizeText = await shellText(serial, ['cat', '/sys/block/$dev/size']);
    final sectorSize = int.tryParse(sectorText);
    final size512 = int.tryParse(sizeText);
    if (sectorSize == null || size512 == null) {
      throw FormatException(
          'ブロック情報を解釈できません: logical_block_size="$sectorText" size="$sizeText"');
    }
    return blockInfoFromSysfs(
        logicalSectorSize: sectorSize, size512: size512);
  }

  /// exec-out でバイナリをそのまま読む（PTY・改行変換なし）。
  Future<Uint8List> execOut(String serial, List<String> command) async {
    final result = await _run(['-s', serial, 'exec-out', ...command]);
    if (!result.ok) {
      throw StateError(
          'adb exec-out ${command.join(' ')} が失敗しました: ${result.stderrText}');
    }
    return result.stdoutBytes;
  }
}

/// adb exec-out の dd でブロックデバイスを読む LbaReader 実装。
/// 受信バイト数が期待値と一致しない場合は即座に例外にする（設計書 §7）。
class AdbLbaReader implements LbaReader {
  AdbLbaReader(this._adb, this.serial, this.info,
      {this.devicePath = '/dev/block/sda'});

  final AdbClient _adb;
  final String serial;
  final BlockDeviceInfo info;
  final String devicePath;

  @override
  int get sectorSize => info.logicalSectorSize;

  @override
  int get totalLbas => info.totalLbas;

  @override
  Future<Uint8List> readLbas(int startLba, int count) async {
    final bytes = await _adb.execOut(serial, [
      'dd',
      'if=$devicePath',
      'bs=$sectorSize',
      'skip=$startLba',
      'count=$count',
      'status=none',
    ]);
    final expected = count * sectorSize;
    if (bytes.length != expected) {
      throw StateError(
          'dd の受信バイト数が一致しません: 期待 $expected / 実際 ${bytes.length} (LBA $startLba +$count)');
    }
    return bytes;
  }
}
