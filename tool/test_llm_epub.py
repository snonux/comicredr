"""EPUB page identity/order protects imported annotations from shifting pages.

Run: python3 -m unittest discover -s tool -p 'test_llm_epub.py'
"""
import io
import unittest
import zipfile
from unittest.mock import patch

from llm_panels import epub_pages, numbered_pages


def book(manifest, spine, documents, metadata=''):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w') as z:
        z.writestr('META-INF/container.xml', '<container><rootfile full-path="OPS/book.opf"/></container>')
        z.writestr('OPS/book.opf', f'<package><metadata>{metadata}</metadata><manifest>{manifest}</manifest><spine>{spine}</spine></package>')
        for path, contents in documents.items():
            z.writestr(path, contents)
    data.seek(0)
    return zipfile.ZipFile(data)


class EpubPagesTest(unittest.TestCase):
    def test_selected_zip_page_keeps_natural_order_and_decodes_only_requested_image(self):
        from PIL import Image
        from pathlib import Path
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as tmp:
            path = Path(tmp) / 'comic.cbz'
            with zipfile.ZipFile(path, 'w') as z:
                for name, colour in [('10.png', 'red'), ('2.png', 'blue')]:
                    out = io.BytesIO()
                    Image.new('RGB', (2, 2), colour).save(out, 'PNG')
                    z.writestr(name, out.getvalue())
            with patch('PIL.Image.open', wraps=Image.open) as opened:
                selected = list(numbered_pages(path, {2}))
                self.assertEqual(opened.call_count, 1)
            self.assertEqual([n for n, _ in selected], [2])
            self.assertEqual(selected[0][1].getpixel((0, 0)), (255, 0, 0))

    def test_selected_epub_page_keeps_spine_number_and_decodes_only_that_page(self):
        from PIL import Image
        from pathlib import Path
        from tempfile import TemporaryDirectory

        def png(colour):
            out = io.BytesIO()
            Image.new('RGB', (2, 2), colour).save(out, 'PNG')
            return out.getvalue()

        with book('<item id="a" href="2.png"/><item id="b" href="1.png"/>',
                  '<itemref idref="a"/><itemref idref="b"/><itemref idref="a"/>',
                  {'OPS/1.png': png('red'), 'OPS/2.png': png('blue')}) as z, TemporaryDirectory() as tmp:
            path = Path(tmp) / 'comic.epub'
            path.write_bytes(z.fp.getvalue())
            with patch('PIL.Image.open', wraps=Image.open) as opened:
                selected = list(numbered_pages(path, {3}))
                self.assertEqual(opened.call_count, 1)
            self.assertEqual([n for n, _ in selected], [3])
            self.assertEqual(selected[0][1].getpixel((0, 0)), (0, 0, 255))

    def test_spine_order_repeated_images_non_linear_and_unlisted_images(self):
        with book('''<item id="b" href="images/2.jpg" media-type="image/jpeg"/>
                     <item id="a" href="images/1.jpg" media-type="image/jpeg"/>''',
                  '<itemref idref="b"/><itemref idref="a" linear="no"/><itemref idref="b"/>',
                  {'OPS/images/1.jpg': b'a', 'OPS/images/2.jpg': b'b', 'OPS/images/logo.jpg': b'logo'}) as z:
            self.assertEqual(epub_pages(z), ['OPS/images/2.jpg', 'OPS/images/2.jpg'])

    def test_wrappers_resolve_paths_svg_css_and_image_only_runs(self):
        with book('''<item id="a" href="text/a.xhtml"/><item id="b" href="text/b.svg"/>
                     <item id="c" href="text/c.xhtml"/><item id="d" href="text/legal.xhtml"/>''',
                  ''.join(f'<itemref idref="{i}"/>' for i in 'abcd'),
                  {'OPS/text/a.xhtml': '<body><img src="../images/page%201.jpg#fragment"/><img src="../images/2.jpg?size=3"/></body>',
                   'OPS/text/b.svg': '<svg><image xlink:href="../images/2.jpg"/></svg>',
                   'OPS/text/c.xhtml': '<body style="background:url(\'/OPS/images/page%201.jpg\')">1</body>',
                   'OPS/text/legal.xhtml': '<body>Copyright notice</body>',
                   'OPS/images/page 1.jpg': b'1', 'OPS/images/2.jpg': b'2'}) as z:
            self.assertEqual(epub_pages(z), ['OPS/images/page 1.jpg', 'OPS/images/2.jpg',
                                            'OPS/images/2.jpg', 'OPS/images/page 1.jpg'])

    def test_fixed_layout_chooses_largest_uncompressed_image(self):
        with book('<item id="a" href="a.xhtml"/>', '<itemref idref="a"/>',
                  {'OPS/a.xhtml': '<body><img src="logo.jpg"/><img src="art.jpg"/>' + 'text ' * 100 + '</body>',
                   'OPS/logo.jpg': b'logo', 'OPS/art.jpg': b'art' * 100},
                  '<meta property="rendition:layout">pre-paginated</meta>') as z:
            self.assertEqual(epub_pages(z), ['OPS/art.jpg'])

    def test_text_ebooks_and_cut_out_scans_are_rejected(self):
        for images in ['<img src="1.jpg"/>', '<img src="1.jpg"/><img src="2.jpg"/>']:
            with self.subTest(images=images), book('<item id="a" href="a.xhtml"/>', '<itemref idref="a"/>',
                    {'OPS/a.xhtml': '<body>' + 'prose ' * 100 + images + '</body>',
                     'OPS/1.jpg': b'1', 'OPS/2.jpg': b'2'}) as z:
                with self.assertRaisesRegex(ValueError, 'Not a comic EPUB'):
                    epub_pages(z)

    def test_package_must_be_readable_and_spine_nonempty(self):
        with book('', '', {}) as z:
            with self.assertRaisesRegex(ValueError, 'empty spine'):
                epub_pages(z)
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            z.writestr('META-INF/container.xml', '<container><rootfile full-path="absent.opf"/></container>')
        data.seek(0)
        with zipfile.ZipFile(data) as z:
            with self.assertRaisesRegex(ValueError, 'no readable package'):
                epub_pages(z)


if __name__ == '__main__':
    unittest.main()
