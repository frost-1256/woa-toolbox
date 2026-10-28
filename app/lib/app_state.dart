import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// UEFI イメージライブラリの1件。
class UefiImageEntry {
  const UefiImageEntry({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
  });
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modified;
}

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
  MassStorageState? massStorage;
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
    massStorage = null;
    error = null;
    notifyListeners();
    if (device.mode == DeviceMode.recovery) {
      refreshMassStorageState();
    }
  }

  bool get canUseMassStorage => selected?.mode == DeviceMode.recovery;

  Future<void> refreshMassStorageState() async {
    final device = selected;
    if (device == null || !canUseMassStorage) return;
    try {
      massStorage =
          await GadgetService(_runner).massStorageState(device.serial);
      notifyListeners();
    } catch (_) {
      // 状態が読めない場合は unknown のままにする（致命的でない）。
    }
  }

  Future<void> enableMassStorage() async {
    final device = selected;
    if (device == null || !canUseMassStorage) return;
    await _guard(() async {
      logger.info('${device.serial} で Mass Storage を有効化します');
      await GadgetService(_runner).enableMassStorage(
        device.serial,
        onStep: (step) => logger.command(['adb', 'shell', step]),
      );
      massStorage = MassStorageState.on;
      logger.info(
          'Mass Storage を有効化しました。PC 側にディスクが見えるはずです。'
          '戻すときは端末を再起動して Recovery に入り直してください。');
    });
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

  // ---- UEFI イメージライブラリ / fastboot boot / Actions 取得 ----

  List<UefiImageEntry> uefiImages = [];
  String? selectedUefiImagePath;
  String githubToken = '';

  Future<Directory> _appDataDir() async {
    final String base;
    if (Platform.isWindows) {
      base = Platform.environment['APPDATA'] ??
          (await Directory.systemTemp.createTemp()).path;
    } else {
      final home = Platform.environment['HOME'] ?? '/tmp';
      base = '$home/.local/share';
    }
    final dir = Directory('$base${Platform.pathSeparator}woa-toolbox');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _uefiImagesDir() async {
    final dir = Directory(
        '${(await _appDataDir()).path}${Platform.pathSeparator}uefi-images');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _settingsFile() async =>
      File('${(await _appDataDir()).path}${Platform.pathSeparator}settings.json');

  Future<void> loadUefiLibrary() async {
    try {
      final settings = await _settingsFile();
      if (await settings.exists()) {
        final json = jsonDecode(await settings.readAsString())
            as Map<String, Object?>;
        githubToken = (json['githubToken'] as String?) ?? '';
      }
    } catch (_) {
      // 設定が壊れていても起動は続ける。
    }
    await _refreshUefiImages();
    notifyListeners();
  }

  Future<void> setGithubToken(String token) async {
    githubToken = token.trim();
    final settings = await _settingsFile();
    await settings.writeAsString(jsonEncode({'githubToken': githubToken}));
  }

  Future<void> _refreshUefiImages() async {
    final dir = await _uefiImagesDir();
    final entries = <UefiImageEntry>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.img')) {
        final stat = await entity.stat();
        entries.add(UefiImageEntry(
          name: entity.uri.pathSegments.last,
          path: entity.path,
          sizeBytes: stat.size,
          modified: stat.modified,
        ));
      }
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    uefiImages = entries;
    if (selectedUefiImagePath != null &&
        !entries.any((e) => e.path == selectedUefiImagePath)) {
      selectedUefiImagePath = null;
    }
  }

  void selectUefiImage(String path) {
    selectedUefiImagePath = path;
    notifyListeners();
  }

  /// ローカルファイルを取り込む（形式検証を通ったものだけ）。
  Future<void> addUefiImage(String sourcePath) async {
    await _guard(() async {
      final problem = await BootImage.validateFile(sourcePath);
      if (problem != null) {
        throw StateError('UEFI イメージとして使えません: $problem');
      }
      final dir = await _uefiImagesDir();
      final name = sourcePath.split(RegExp(r'[\\/]')).last;
      var target = File('${dir.path}${Platform.pathSeparator}$name');
      if (await target.exists()) {
        final stem = name.replaceAll(RegExp(r'\.img$'), '');
        target = File(
            '${dir.path}${Platform.pathSeparator}$stem-${DateTime.now().millisecondsSinceEpoch}.img');
      }
      await File(sourcePath).copy(target.path);
      logger.info('UEFI イメージを取り込みました: ${target.uri.pathSegments.last}');
      await _refreshUefiImages();
      selectedUefiImagePath = target.path;
    });
  }

  /// Mu-Silicium の Actions から最新の成功 run の UEFI を取得する。
  Future<void> downloadLatestUefi() async {
    await _guard(() async {
      logger.info('GitHub Actions の最新 UEFI を取得します…');
      final client = GitHubActionsClient(token: githubToken);
      final result = await client.fetchLatestArtifactFile(
        owner: 'frost-1256',
        repo: 'Mu-Silicium',
        workflowFileName: 'spacewar.yml',
        artifactName: 'uefi-spacewar',
        fileNameInZip: 'boot.img',
      );
      final problem = BootImage.validateBytes(result.fileBytes);
      if (problem != null) {
        throw StateError('取得したイメージが不正です: $problem');
      }
      final dir = await _uefiImagesDir();
      final name = 'Mu-spacewar-run${result.run.runNumber}.img';
      final target = File('${dir.path}${Platform.pathSeparator}$name');
      await target.writeAsBytes(result.fileBytes);
      logger.info(
          'Run #${result.run.runNumber} (${result.run.headSha}) の UEFI を保存しました: $name');
      await _refreshUefiImages();
      selectedUefiImagePath = target.path;
    });
  }

  bool get canBootUefi =>
      selected?.mode == DeviceMode.fastboot && selectedUefiImagePath != null;

  /// 選択中の fastboot 端末で、選択中のイメージを一時ブートする。
  Future<void> bootSelectedUefi() async {
    final device = selected;
    final imagePath = selectedUefiImagePath;
    if (device == null || imagePath == null || !canBootUefi) return;
    await _guard(() async {
      logger.info(
          '${device.serial} で UEFI を一時ブートします: ${imagePath.split(RegExp(r'[\\/]')).last}');
      await FastbootClient(_runner).boot(
        device.serial,
        imagePath,
        onOutput: (line) => logger.info('fastboot: $line'),
      );
      logger.info('ブートイメージを送信しました。端末側で UEFI が起動します。');
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
