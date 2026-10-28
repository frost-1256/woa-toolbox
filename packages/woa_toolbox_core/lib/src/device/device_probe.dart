import 'adb_client.dart';
import 'command_runner.dart';

/// ツールボックスから見た端末の動作モード。
enum DeviceMode { android, recovery, sideload, fastboot, unauthorized, offline, unknown }

class ToolboxDevice {
  const ToolboxDevice({
    required this.serial,
    required this.mode,
    this.product,
  });

  final String serial;
  final DeviceMode mode;
  final String? product;

  @override
  String toString() => 'ToolboxDevice($serial, $mode, $product)';
}

/// `fastboot devices` の出力をパースする。
List<String> parseFastbootDevices(String output) {
  final serials = <String>[];
  for (final line in output.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[1] == 'fastboot') {
      serials.add(parts[0]);
    }
  }
  return serials;
}

/// adb と fastboot の両方から端末一覧を集める。
/// adb / fastboot が PATH に無い環境では該当側を空として扱う
/// （初回検出・案内はアプリ側の責務）。
class DeviceProbe {
  DeviceProbe(this._runner,
      {this.adbExecutable = 'adb', this.fastbootExecutable = 'fastboot'});

  final CommandRunner _runner;
  final String adbExecutable;
  final String fastbootExecutable;

  Future<List<ToolboxDevice>> probe() async {
    final devices = <ToolboxDevice>[];
    try {
      final adb = AdbClient(_runner, adbExecutable: adbExecutable);
      for (final d in await adb.devices()) {
        devices.add(ToolboxDevice(
          serial: d.serial,
          product: d.product,
          mode: switch (d.state) {
            AdbDeviceState.device => DeviceMode.android,
            AdbDeviceState.recovery => DeviceMode.recovery,
            AdbDeviceState.sideload => DeviceMode.sideload,
            AdbDeviceState.unauthorized => DeviceMode.unauthorized,
            AdbDeviceState.offline => DeviceMode.offline,
            AdbDeviceState.unknown => DeviceMode.unknown,
          },
        ));
      }
    } on Object {
      // adb が無い・起動できない場合は fastboot のみで判定する。
    }
    try {
      final result = await _runner.run(fastbootExecutable, ['devices']);
      if (result.ok) {
        final seen = devices.map((d) => d.serial).toSet();
        // fastboot devices は通常 stderr に出す（ビルドにより stdout の
        // こともある）ため、両方を対象にパースする。
        for (final serial in parseFastbootDevices(
            '${result.stdoutText}\n${result.stderrText}')) {
          if (!seen.contains(serial)) {
            devices.add(ToolboxDevice(serial: serial, mode: DeviceMode.fastboot));
          }
        }
      }
    } on Object {
      // fastboot が無い場合は無視する。
    }
    return devices;
  }
}
