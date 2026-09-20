#!/usr/bin/env python3
"""Inspect a checksum-pinned desktop ZIP or Apple XCFramework on a macOS host.

This checks packaging and binary APIs. It does not run audio or qualify devices.
No archive paths are extracted: each inspected binary goes to one temporary file.
"""
import argparse
import hashlib
import json
import plistlib
import posixpath
import re
import stat
import struct
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile

CLOCK_SYMBOLS = ('ConfigureAudioClockCorrectionV1', 'GetAudioClockCorrectionStateV1')
APPLE_ADM_METHODS = ('acquireExternalRecordingWithAudioProcessingOptions:',
                     'releaseExternalRecording', 'hasExternalRecordingDemand')
APPLE_FACTORY_DECLARATIONS = ('RTC_PCM_PLAYOUT_SHARED', 'startPcmPlayoutWithSampleRate:',
                              'pcmPlayoutStateForGeneration:')
APPLE_FACTORY_METHODS = ('startPcmPlayoutWithSampleRate:channels:shared:',
                         'pcmPlayoutStateForGeneration:')
APPLE_SLICES = {
    ('ios', ''): ({'arm64'}, 'ios'),
    ('ios', 'simulator'): ({'arm64', 'x86_64'}, 'iossimulator'),
    ('ios', 'maccatalyst'): ({'arm64', 'x86_64'}, 'macCatalyst'),
    ('macos', ''): ({'arm64', 'x86_64'}, 'macos'),
    ('tvos', ''): ({'arm64'}, 'tvos'),
    ('tvos', 'simulator'): ({'arm64'}, 'tvossimulator'),
    ('xros', ''): ({'arm64'}, 'xros'),
    ('xros', 'simulator'): ({'arm64'}, 'xrsimulator'),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE)


def archive_read(archive, name):
    """Resolve file and directory symlinks within the ZIP without extracting them."""
    for _ in range(20):
        name = posixpath.normpath(name)
        require(not name.startswith(('/', '../')) and name != '..', 'escaping ZIP path')
        parts = name.split('/')
        for count in range(1, len(parts) + 1):
            prefix = '/'.join(parts[:count])
            try:
                info = archive.getinfo(prefix)
            except KeyError:
                continue
            if stat.S_ISLNK(info.external_attr >> 16):
                target = archive.read(info).decode()
                require(not target.startswith('/'), 'absolute ZIP symlink')
                name = posixpath.join(posixpath.dirname(prefix), target, *parts[count:])
                break
        else:
            return archive.read(name)
    raise ValueError('ZIP symlink loop')


def unique_member(archive, suffix):
    members = [name for name in archive.namelist() if name.endswith('/' + suffix)]
    require(len(members) == 1, f'expected one {suffix}, found {members}')
    return members[0]


def binary_arch(data, platform):
    if platform == 'linux':
        require(data[:6] == b'\x7fELF\x02\x01', 'expected little-endian ELF64')
        machine = struct.unpack_from('<H', data, 18)[0]
        return {62: 'x64', 183: 'arm64'}.get(machine)
    require(data[:2] == b'MZ', 'expected PE binary')
    offset = struct.unpack_from('<I', data, 60)[0]
    require(data[offset:offset + 4] == b'PE\0\0', 'missing PE signature')
    return {0x8664: 'x64', 0xaa64: 'arm64'}.get(struct.unpack_from('<H', data, offset + 4)[0])


def desktop(archive, platform, arch, temporary):
    headers = {
        'rtc_audio_device.h': ('AcquireRecording()', 'ReleaseRecording()', 'GetRecordingState()',
                               'StartPcmPlayoutSource(', 'GetPcmPlayoutSourceState('),
        'rtc_audio_processing.h': ('ApplyCaptureProfile(', 'GetCaptureProcessingState()'),
        'rtc_audio_clock_correction.h': CLOCK_SYMBOLS,
    }
    for header, methods in headers.items():
        text = archive_read(archive, unique_member(archive, 'include/' + header)).decode()
        for method in methods:
            require(method in text, f'{header} lacks {method}')
    library = 'libwebrtc.so' if platform == 'linux' else 'libwebrtc.dll'
    member = unique_member(archive, 'lib/' + library)
    data = archive_read(archive, member)
    require(binary_arch(data, platform) == arch, 'binary architecture does not match target')
    binary = temporary / library
    binary.write_bytes(data)
    if platform == 'linux':
        exports = command('xcrun', 'llvm-nm', '--dynamic', '--defined-only', str(binary))
    else:
        unique_member(archive, 'lib/libwebrtc.dll.lib')
        exports = command('xcrun', 'llvm-objdump', '--private-headers', str(binary))
        require('Export Table' in exports, 'PE has no export table')
        exports = exports.split('Export Table', 1)[1]
    for symbol in (*CLOCK_SYMBOLS, 'CreateRTCPeerConnectionFactory'):
        require(symbol in exports, f'missing export {symbol}')
    return [{'library': member, 'architecture': arch,
             'sha256': hashlib.sha256(data).hexdigest()}]


def apple(archive, temporary):
    root = 'WebRTC.xcframework'
    plist = plistlib.loads(archive_read(archive, root + '/Info.plist'))
    libraries = plist['AvailableLibraries']
    keys = [(lib['SupportedPlatform'], lib.get('SupportedPlatformVariant', '')) for lib in libraries]
    require(len(keys) == len(set(keys)) and set(keys) == set(APPLE_SLICES),
            f'XCFramework platform entries differ from recipe: {keys}')
    receipt = []
    for lib in libraries:
        key = (lib['SupportedPlatform'], lib.get('SupportedPlatformVariant', ''))
        expected_arches, expected_platform = APPLE_SLICES[key]
        require(set(lib['SupportedArchitectures']) == expected_arches, f'{key}: plist architectures differ')
        require(lib['LibraryPath'] == 'WebRTC.framework', 'unexpected framework path')
        base = f"{root}/{lib['LibraryIdentifier']}/{lib['LibraryPath']}"
        adm_header = archive_read(archive, base + '/Headers/RTCAudioDeviceModule.h').decode()
        factory_header = archive_read(archive, base + '/Headers/RTCPeerConnectionFactory.h').decode()
        for method in APPLE_ADM_METHODS:
            require(method in adm_header, f'{base}: missing declaration {method}')
        for declaration in APPLE_FACTORY_DECLARATIONS:
            require(declaration in factory_header, f'{base}: missing declaration {declaration}')
        data = archive_read(archive, base + '/WebRTC')
        binary = temporary / 'WebRTC'
        binary.write_bytes(data)
        arches = set(command('xcrun', 'lipo', '-archs', str(binary)).split())
        require(arches == expected_arches, f'{base}: Mach-O architectures differ: {arches}')
        for arch in sorted(arches):
            load = command('xcrun', 'llvm-objdump', '--macho', f'--arch={arch}', '--private-headers', str(binary))
            require(re.search(r'platform\s+' + expected_platform + r'\s', load) is not None,
                    f'{base}/{arch}: Mach-O platform mismatch')
            metadata = command('xcrun', 'llvm-objdump', '--macho', f'--arch={arch}', '--objc-meta-data', str(binary))
            require('_OBJC_CLASS_$_RTCAudioDeviceModule' in metadata, 'missing Objective-C ADM class')
            require('_OBJC_CLASS_$_RTCPeerConnectionFactory' in metadata,
                    'missing Objective-C peer connection factory class')
            for method in (*APPLE_ADM_METHODS, *APPLE_FACTORY_METHODS):
                require(method in metadata, f'{base}/{arch}: missing Objective-C method {method}')
        receipt.append({'library': base, 'architectures': sorted(arches),
                        'platform': expected_platform, 'sha256': hashlib.sha256(data).hexdigest()})
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--expected-sha', required=True)
    parser.add_argument('--platform', choices=('linux', 'win', 'apple'), required=True)
    parser.add_argument('--arch', choices=('x64', 'arm64'))
    args = parser.parse_args()
    require(re.fullmatch('[0-9a-f]{64}', args.expected_sha), 'malformed expected SHA-256')
    with args.archive.open('rb') as stream:
        actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    require(actual == args.expected_sha, f'archive SHA mismatch: {actual}')
    require(args.platform == 'apple' or args.arch is not None, '--arch is required for desktop')
    with ZipFile(args.archive) as archive, tempfile.TemporaryDirectory() as directory:
        require(len(archive.namelist()) == len(set(archive.namelist())), 'duplicate ZIP members')
        temporary = Path(directory)
        libraries = apple(archive, temporary) if args.platform == 'apple' else desktop(archive, args.platform, args.arch, temporary)
    print(json.dumps({'archive': str(args.archive), 'sha256': actual, 'libraries': libraries}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
