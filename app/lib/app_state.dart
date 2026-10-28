import 'package:flutter/foundation.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// アプリ全体の状態（Phase 1: 読み取り専用）。
/// 状態管理は ChangeNotifier で軽量に始める（設計書 §9 の未決定事項への暫定回答）。
class AppState extends ChangeNotifier {
  AppState() : logger = ToolLogger(sink: LogSink.memory);

  final ToolLogger logger;
  final CommandRunner _runner = const ProcessCommandRunner();

  List<ToolboxDevice> devices = [];
  ToolboxDevice? selected;
  GptTable? primaryTable;
  bool? gptConsistent;
  PartitionLayout? layout;
  bool busy = false;
  String? error;

  bool get canReadGpt {
    final mode = selected?.mode;
    return mode == DeviceMode.recovery || mode == DeviceMode.android;
  }

  Future<void> refreshDevices() async {
    await _guard(() async {
      logger.info('端末を検出しています…');
      devices = await DeviceProbe(_runner).probe();
      logger.info('${devices.length} 台の端末が見つかりました');
      if (selected != null &&
          !devices.any((d) => d.serial == selected!.serial)) {
        selected = null;
        primaryTable = null;
        gptConsistent = null;
        layout = null;
      }
    });
  }

  void select(ToolboxDevice device) {
    selected = device;
    primaryTable = null;
    gptConsistent = null;
    layout = null;
    error = null;
    notifyListeners();
  }

  Future<void> readGpt() async {
    final device = selected;
    if (device == null || !canReadGpt) return;
    await _guard(() async {
      logger.info('${device.serial} の GPT を読み取ります');
      final adb = AdbClient(_runner);
      final info = await adb.blockInfo(device.serial);
      logger.info(
          'セクタサイズ ${info.logicalSectorSize}B / 総 LBA ${info.totalLbas}');
      final reader = AdbLbaReader(adb, device.serial, info);
      final both = await GptReader.readBoth(reader);
      primaryTable = both.primary;
      gptConsistent = both.consistent;
      layout = classifyLayout(both.primary);
      logger.info(
          'GPT 読み取り完了: ${both.primary.partitions.length} パーティション、'
          'プライマリ/バックアップ整合 = ${both.consistent}');
      if (!both.consistent) {
        logger.warn('プライマリとバックアップの GPT が一致しません');
      }
    });
  }

  Future<void> _guard(Future<void> Function() body) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await body();
    } catch (e) {
      error = e.toString();
      logger.error(e.toString());
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
