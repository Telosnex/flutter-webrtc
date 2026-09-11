import io
import stat
import struct
import unittest
from zipfile import ZipFile, ZipInfo

from verify_native_archive import archive_read, binary_arch, require, unique_member


class NativeArchiveTest(unittest.TestCase):
    def test_elf_architecture(self):
        data = bytearray(64)
        data[:6] = b'\x7fELF\x02\x01'
        for machine, arch in ((62, 'x64'), (183, 'arm64')):
            struct.pack_into('<H', data, 18, machine)
            self.assertEqual(arch, binary_arch(data, 'linux'))
        with self.assertRaises(ValueError):
            binary_arch(b'not an elf file', 'linux')

    def test_pe_architecture(self):
        data = bytearray(128)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 60, 64)
        data[64:68] = b'PE\0\0'
        for machine, arch in ((0x8664, 'x64'), (0xaa64, 'arm64')):
            struct.pack_into('<H', data, 68, machine)
            self.assertEqual(arch, binary_arch(data, 'win'))

    def archive(self, entries, links=()):
        buffer = io.BytesIO()
        with ZipFile(buffer, 'w') as archive:
            for name, value in entries:
                archive.writestr(name, value)
            for name, value in links:
                info = ZipInfo(name)
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(info, value)
        archive = ZipFile(buffer)
        self.addCleanup(archive.close)
        return archive

    def test_framework_directory_symlinks(self):
        archive = self.archive([('WebRTC.framework/Versions/A/Headers/ADM.h', 'api')], [
            ('WebRTC.framework/Headers', 'Versions/Current/Headers'),
            ('WebRTC.framework/Versions/Current', 'A'),
        ])
        self.assertEqual(b'api', archive_read(archive, 'WebRTC.framework/Headers/ADM.h'))

    def test_symlink_loop_rejected(self):
        archive = self.archive([], [('one', 'two'), ('two', 'one')])
        with self.assertRaises(ValueError):
            archive_read(archive, 'one')

    def test_escaping_symlink_rejected(self):
        for target in ('../../escape', '/absolute'):
            archive = self.archive([], [('one/link', target)])
            with self.assertRaises(ValueError):
                archive_read(archive, 'one/link')

    def test_ambiguous_library_rejected(self):
        archive = self.archive([('a/lib/libwebrtc.so', ''), ('b/lib/libwebrtc.so', '')])
        with self.assertRaises(ValueError):
            unique_member(archive, 'lib/libwebrtc.so')

    def test_required_condition_fails_closed(self):
        with self.assertRaisesRegex(ValueError, 'missing API'):
            require(False, 'missing API')
