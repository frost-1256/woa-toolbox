import 'command_runner.dart';

/// USB Mass Storage ガジェットの状態。
enum MassStorageState {
  /// LUN にブロックデバイスが割り当たっている。
  on,

  /// LUN が空（または未構成）。
  off,

  /// 読み取れなかった。
  unknown,
}

/// Recovery 上で configfs ガジェットを組み、ディスク全体を USB Mass Storage
/// として PC に見せる操作（実績のある ms_on.sh の手順を固定テンプレート化）。
///
/// 設計書 §7 のとおり、端末側コマンドはこのテンプレート以外使わない。
/// パラメータは対象ブロックデバイスだけで、許可リストで検証してから差し込む。
class GadgetService {
  GadgetService(this._runner, {this.adbExecutable = 'adb'});

  final CommandRunner _runner;
  final String adbExecutable;

  static const _gadget = '/config/usb_gadget/g1';
  static const _lunFile =
      '$_gadget/configs/b.1/mass_storage.0/lun.0/file';
  static const _udcName = 'a600000.dwc3';

  /// 許可するブロックデバイス（当面はディスク全体のみ）。
  static const allowedDevices = {'/dev/block/sda'};

  Future<CommandResult> _shell(String serial, String command) =>
      _runner.run(adbExecutable, ['-s', serial, 'shell', command]);

  /// 現在の Mass Storage 状態を読む（読み取り専用）。
  Future<MassStorageState> massStorageState(String serial) async {
    final result = await _shell(serial, 'cat $_lunFile');
    if (!result.ok) return MassStorageState.unknown;
    return result.stdoutText.trim().isEmpty
        ? MassStorageState.off
        : MassStorageState.on;
  }

  /// Mass Storage を有効化する。[blockDevice] は許可リスト内のみ。
  /// 手順は ms_on.sh と同一。成否は最後の読み戻し検証で確定させる
  /// （adb shell の終了コードは当てにならないため）。
  Future<void> enableMassStorage(
    String serial, {
    String blockDevice = '/dev/block/sda',
    void Function(String step)? onStep,
  }) async {
    if (!allowedDevices.contains(blockDevice)) {
      throw ArgumentError('許可されていないブロックデバイスです: $blockDevice');
    }
    // (コマンド, 失敗を許容するか) — ms_on.sh の順序そのまま。
    final steps = <(String, bool)>[
      ('umount /data 2>/dev/null', true),
      ('umount /metadata 2>/dev/null', true),
      ('umount /sdcard 2>/dev/null', true),
      ('setenforce 0', true),
      ('mkdir -p $_gadget/functions/mass_storage.0', false),
      ('echo 0xEF > $_gadget/bDeviceClass', false),
      ('echo 0x02 > $_gadget/bDeviceSubClass', false),
      ('echo 0x01 > $_gadget/bDeviceProtocol', false),
      ('ln -s $_gadget/functions/mass_storage.0/ $_gadget/configs/b.1/ 2>/dev/null', true),
      ('echo $blockDevice > $_lunFile', false),
      ('echo 0 > $_gadget/configs/b.1/mass_storage.0/lun.0/cdrom', false),
      ('echo 0 > $_gadget/configs/b.1/mass_storage.0/lun.0/removable', false),
      ('echo 0 > $_gadget/configs/b.1/mass_storage.0/lun.0/ro', false),
      // UDC の張り直し。成功すると USB が再構成され、この shell 自体が
      // 切れることがあるため失敗許容にし、検証は読み戻しで行う。
      ("sh -c 'echo > $_gadget/UDC; echo $_udcName > $_gadget/UDC'", true),
    ];
    for (final (command, tolerate) in steps) {
      onStep?.call(command);
      final result = await _shell(serial, command);
      if (!result.ok && !tolerate) {
        throw StateError(
            'コマンドが失敗しました: $command (${result.stderrText.trim()})');
      }
    }
    // 読み戻し検証（UDC 張り直しで adb が一時的に切れる場合があるため数回試す）。
    for (var attempt = 0; attempt < 5; attempt++) {
      final file = await _shell(serial, 'cat $_lunFile');
      if (file.ok && file.stdoutText.trim() == blockDevice) {
        final udc = await _shell(serial, 'cat $_gadget/UDC');
        if (udc.ok && udc.stdoutText.trim() == _udcName) {
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    throw StateError(
        'Mass Storage の有効化を読み戻しで確認できませんでした（LUN / UDC の状態が想定と異なります）');
  }
}
