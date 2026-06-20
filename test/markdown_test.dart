import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:syncpad/storage/attachment_store.dart';
import 'package:syncpad/storage/markdown_refs.dart';

void main() {
  group('markdown_refs', () {
    test('imageUrlsIn 提取、去重、保序，支持标题与尖括号', () {
      const text = '开头 ![a](attachments/h.jpg) 中间 '
          '![](https://e.com/i.png "标题") 末尾 ![](<a b.png>) ![dup](attachments/h.jpg)';
      expect(imageUrlsIn(text),
          ['attachments/h.jpg', 'https://e.com/i.png', 'a b.png']);
    });

    test('attachmentNamesIn 只挑本仓库附件、去前缀与查询串', () {
      const text = '![](attachments/abc.jpg?x=1) ![](https://e/i.png) ![](p.png)';
      expect(attachmentNamesIn(text), {'abc.jpg'});
      expect(attachmentNameOf('attachments/abc.jpg'), 'abc.jpg');
      expect(attachmentNameOf('https://e/i.png'), isNull);
    });

    test('rewriteImageUrls 按映射替换、保留 alt/网络图', () {
      const text = '![图](pic.png) 与 ![](https://e/i.png)';
      final out = rewriteImageUrls(text, {'pic.png': 'attachments/x.jpg'});
      expect(out, '![图](attachments/x.jpg) 与 ![](https://e/i.png)');
    });

    test('stripImagesForPreview 把图片换成占位', () {
      expect(stripImagesForPreview('你好 ![](a.png) 世界'), '你好 [图片] 世界');
    });
  });

  group('image prepare', () {
    test('normalizeImageExt / sniffImageExt', () {
      expect(normalizeImageExt('.JPEG'), 'jpg');
      expect(normalizeImageExt('PNG'), 'png');
      expect(normalizeImageExt('txt'), isNull);
      final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
      expect(sniffImageExt(png), 'png');
    });

    test('大图降采样到长边上限并转 JPEG', () {
      final big = Uint8List.fromList(
          img.encodePng(img.Image(width: 4000, height: 2000)));
      final out = prepareImage(big, maxEdge: 2560);
      expect(out.ext, 'jpg');
      final decoded = img.decodeImage(out.bytes)!;
      expect(decoded.width, 2560); // 宽 >= 高，长边缩到 2560
      expect(decoded.height, 1280);
    });

    test('小图原样保留（含原扩展名）', () {
      final small =
          Uint8List.fromList(img.encodePng(img.Image(width: 10, height: 10)));
      final out = prepareImage(small);
      expect(out.ext, 'png');
      expect(out.bytes.length, small.length); // 未重新编码
    });
  });

  group('AttachmentStore', () {
    test('add 内容寻址去重、hasName / localNames / bytesForName', () async {
      final tmp = await Directory.systemTemp.createTemp('syncpad_att_');
      try {
        final store = AttachmentStore(tmp);
        final bytes =
            Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));

        final ref1 = await store.add(bytes, sourceExt: 'png');
        final ref2 = await store.add(bytes, sourceExt: 'png'); // 同内容
        expect(ref1, ref2); // 同名
        expect(ref1.startsWith(attachmentRefPrefix), isTrue);

        final name = attachmentNameOf(ref1)!;
        expect(await store.hasName(name), isTrue);
        expect((await store.localNames()), {name}); // 去重为 1
        expect((await store.bytesForName(name))!.length, bytes.length);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
