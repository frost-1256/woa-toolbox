import 'dart:typed_data';

/// IEEE CRC-32（GPT が使う多項式 0xEDB88320）のテーブル実装。
class Crc32 {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      table[i] = c;
    }
    return table;
  }

  static int compute(List<int> bytes, [int start = 0, int? end]) {
    final limit = end ?? bytes.length;
    var crc = 0xFFFFFFFF;
    for (var i = start; i < limit; i++) {
      crc = _table[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
