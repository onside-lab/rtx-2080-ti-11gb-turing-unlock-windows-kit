import json
import re
import struct
import unittest
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def public_files():
    # Do not inspect private runtime output or local configuration as distribution.
    excluded = {'.git', '.test-scratch', '__pycache__', 'reports', 'backup',
                'state', 'staging', 'payload', '.agents', '.codex', '.aws'}
    return sorted(p for p in ROOT.rglob('*') if p.is_file()
                  and not excluded.intersection(p.relative_to(ROOT).parts)
                  and not p.name.endswith(('.local.json', '.pyc', '.pyo')))


def markdown_prose(text):
    text = re.sub(r'^\s*(`{3,}|~{3,})[^\n]*\n.*?^\s*\1\s*$', '',
                  text, flags=re.M | re.S)
    return re.sub(r'(`+)[^\n]*?\1', '', text)


def markdown_destinations(text):
    text = markdown_prose(text)
    # Inline links/images, reference definitions, and local HTML src/href links.
    target = r'(<[^>\n]+>|(?:[^\s()<>]|\([^()\n]*\))+)'
    inline = r'!?\[[^\]\n]*\]\(\s*' + target + r'(?:\s+[\"\x27].*?[\"\x27])?\s*\)'
    references = r'^\s{0,3}\[[^\]\n]+\]:\s*' + target
    for pattern in (inline, references):
        for match in re.finditer(pattern, text, flags=re.M):
            yield match.group(1).strip('<>')
    for match in re.finditer(r'(?:href|src)=[\"\x27]([^\"\x27]+)[\"\x27]', text, re.I):
        yield match.group(1)


def markdown_anchors(text):
    anchors, counts = set(), {}
    for heading in re.findall(r'^ {0,3}#{1,6}\s+(.+?)\s*#*$', text, flags=re.M):
        slug = re.sub(r'[^\w\- ]', '', heading.lower()).replace(' ', '-')
        count = counts.get(slug, 0)
        anchors.add(slug + ('-' + str(count) if count else ''))
        counts[slug] = count + 1
    return anchors


class PackagingTests(unittest.TestCase):
    def test_all_relative_markdown_links_resolve(self):
        for source in (p for p in public_files() if p.suffix.lower() == '.md'):
            for destination in markdown_destinations(source.read_text(encoding='utf-8')):
                with self.subTest(source=source.relative_to(ROOT), link=destination):
                    url = urlsplit(destination)
                    if url.scheme or url.netloc:
                        continue
                    path = (source.parent / unquote(url.path)).resolve() if url.path else source
                    self.assertTrue(path.is_relative_to(ROOT), 'Link leaves distribution')
                    self.assertTrue(path.exists(), 'Missing relative link target')
                    if url.fragment and path.suffix.lower() == '.md':
                        self.assertIn(unquote(url.fragment),
                                      markdown_anchors(path.read_text(encoding='utf-8')),
                                      'Missing heading anchor')

    def test_public_markdown_is_english_and_lf(self):
        japanese = re.compile('[\u3000-\u303f\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff66-\uff9f]')
        for path in (p for p in public_files() if p.suffix.lower() == '.md'):
            with self.subTest(path=path.relative_to(ROOT)):
                raw = path.read_bytes()
                self.assertNotIn(b'\r', raw)
                self.assertNotRegex(raw.decode('utf-8'), japanese)

    def test_no_forbidden_personal_strings_in_distribution(self):
        forbidden = ('ako' + '_v', 'e:/gpu' + '-unlock',
                     'e:\\gpu' + '-unlock', 'e:/tmp/' + 'handoff',
                     'e:\\tmp\\' + 'handoff', 'c:\\' + 'users\\', 'c:/' + 'users/')
        for path in public_files():
            # Byte scanning also covers metadata in images without decoding it.
            raw = path.read_bytes().lower()
            for value in forbidden:
                with self.subTest(path=path.relative_to(ROOT), value=value):
                    for encoding in ('utf-8', 'utf-16-le'):
                        self.assertNotIn(value.encode(encoding), raw)

    def test_social_preview_dimensions_and_metadata(self):
        raw = (ROOT / 'assets/social-preview.png').read_bytes()
        self.assertEqual(raw[:8], b'\x89PNG\r\n\x1a\n')
        self.assertEqual(raw[12:16], b'IHDR')
        self.assertEqual(struct.unpack('>II', raw[16:24]), (1280, 640))
        offset = 8
        while offset < len(raw):
            size = struct.unpack('>I', raw[offset:offset + 4])[0]
            chunk = raw[offset + 4:offset + 8]
            self.assertNotIn(chunk, (b'tEXt', b'zTXt', b'iTXt', b'eXIf'),
                             'Preview must not contain textual or EXIF metadata')
            offset += size + 12
        self.assertEqual(offset, len(raw))

    def test_ascii_line_endings_and_no_private_source_dependency(self):
        files=[ROOT / 'kit.py',ROOT / '.gitignore',ROOT / '.gitattributes']
        files+=list(ROOT.glob('*.cmd'))
        for folder in ('p2','scripts','config','tests'):
            files += [p for p in (ROOT / folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts]
        for path in files:
            with self.subTest(path=path.relative_to(ROOT)):
                raw=path.read_bytes()
                text=raw.decode('ascii')
                self.assertNotIn('ako'+'_v',text)
                self.assertNotIn('GPU'+'-UNLOCK',text)
                self.assertNotIn('from p'+'0.',text)
                if path.suffix == '.cmd':
                    self.assertNotIn(b'\n',raw.replace(b'\r\n',b''))
                    self.assertTrue(raw.endswith(b'\r\n'))
                else:
                    self.assertNotIn(b'\r',raw)

    def test_only_empty_target_templates(self):
        environment=json.loads((ROOT / 'config/environment.example.json').read_text())
        self.assertEqual(environment['gpu']['uuid'],'')
        self.assertEqual(environment['payload_root'],'')
        usb=json.loads((ROOT / 'config/p3-usb-policy.example.json').read_text())
        for field in ('identity_sha256','binding_sha256','volume_guid_path','inspect_report','inspect_sha256'):
            self.assertEqual(usb[field],'')
        self.assertTrue(all(entry['sha256']=='' and entry['bytes'] is None for entry in usb['payload_files']))
        self.assertEqual(list((ROOT / 'config').glob('*.local.json')),[])

    def test_no_distributed_payload(self):
        for folder in ('p2','scripts','config','tests'):
            self.assertFalse(any(p.suffix.lower() in ('.efi','.bin','.rom','.zip') for p in (ROOT / folder).rglob('*')))
