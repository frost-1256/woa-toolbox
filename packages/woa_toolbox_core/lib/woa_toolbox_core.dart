/// WoA Toolbox の UI 非依存コア。
/// GUI と MCP サーバーはこのライブラリだけを操作し、
/// adb / fastboot の実行経路はここに一本化される（設計書 §2）。
library;

export 'src/crc32.dart';
export 'src/gpt/gpt.dart';
export 'src/gpt/gpt_reader.dart';
export 'src/device/command_runner.dart';
export 'src/device/adb_client.dart';
export 'src/device/device_probe.dart';
export 'src/device/fastboot_client.dart';
export 'src/device/gadget_service.dart';
export 'src/github/actions_client.dart';
export 'src/layout/layout_classifier.dart';
export 'src/logging/tool_logger.dart';
export 'src/backup/manifest.dart';
