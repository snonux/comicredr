import 'dart:convert';
import 'dart:typed_data';

import 'package:comic_sync/comic_sync.dart';
import 'package:test/test.dart';

Manifest _manifest(String title, {String folder = 'Golden Age'}) => Manifest(
  contentKey: 'k1',
  title: title,
  format: 'zip',
  fileName: 'Weird Comics 4.cbz',
  folder: folder,
  ext: 'cbz',
  size: 10,
  uploadedBy: 'laptop',
  uploadedAt: DateTime.utc(2026, 10, 20),
);

void main() {
  test('a manifest moved keeps everything but its place', () {
    final m = _manifest('Weird Comics #4');
    final at = m.movedTo('Read/2026/Weird 4.cbz');
    expect((at.folder, at.fileName, at.relPath), ('Read/2026', 'Weird 4.cbz', 'Read/2026/Weird 4.cbz'));
    expect(at.toJson()..removeWhere((k, _) => k == 'folder' || k == 'file_name'), {
      ...m.toJson()..removeWhere((k, _) => k == 'folder' || k == 'file_name'),
    });
    final top = m.movedTo('Weird 4.cbz');
    expect((top.folder, top.relPath), ('', 'Weird 4.cbz'));
  });

  test('a manifest goes as UTF-8, and one from before, a byte a character, still reads', () {
    final m = _manifest('Akira — Part 1 ★');
    expect(Manifest.decodeBytes(m.bytes)?.title, 'Akira — Part 1 ★');
    expect(m.bytes, utf8.encode(m.encode()));
    final old = Uint8List.fromList(_manifest('Café').encode().codeUnits);
    expect(Manifest.decodeBytes(old)?.title, 'Café');
  });

  test('the shelf lists each comic with its manifest ETag', () async {
    final store = MemoryStore();
    const o = BookObjects('Comics/', 'k1');
    Future<void> put(String key) => store.put(key, Stream.value(Uint8List.fromList([1])), size: 1);
    await put(o.manifest);
    await put(o.cover);
    await put(const BookObjects('Comics/', 'k2').cover);
    final first = await listShelf(store, 'Comics/');
    expect(first.keys, ['k1']);
    expect(first['k1'], isNotNull);
    expect(first['k1'], isNot(contains('"')));
    await put(o.manifest);
    expect((await listShelf(store, 'Comics/'))['k1'], isNot(first['k1']));
    expect(plainEtag('"abc"'), 'abc');
    expect(plainEtag('&quot;abc&quot;'), 'abc');
  });
}
