import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import adt
import mkadt
from spes_memory import select_memory


def fdt(banks, reservations=(), compatible=b'qcom,khaje\0'):
    """Minimal live-khaje FDT: root cells 2/2, one or more /memory nodes."""
    names = bytearray(); body = bytearray()
    def token(n): body.extend(struct.pack('>I', n))
    def begin(name):
        token(1); body.extend(name.encode() + b'\0'); body.extend(b'\0' * (-len(body) % 4))
    def prop(name, value):
        offset = len(names); names.extend(name.encode() + b'\0')
        body.extend(struct.pack('>III', 3, len(value), offset) + value)
        body.extend(b'\0' * (-len(body) % 4))
    begin(''); prop('compatible', compatible)
    prop('#address-cells', struct.pack('>I', 2)); prop('#size-cells', struct.pack('>I', 2))
    begin('memory'); prop('device_type', b'memory\0')
    prop('reg', b''.join(struct.pack('>QQ', *b) for b in banks)); token(2)
    token(2); token(9)
    reserve = b''.join(struct.pack('>QQ', *r) for r in reservations) + bytes(16)
    off = 40 + len(reserve); strings = off + len(body)
    return struct.pack('>10I', 0xd00dfeed, strings + len(names), off, strings, 40, 17, 16, 0,
                       len(names), len(body)) + reserve + body + names


# Verified on a live Redmi 10 Power (rain, SM6225, 4 GB) 2026-10-22: DRAM
# starts at 1 GiB, three banks with a ~35 MiB hole, ending at 5 GiB. Only the
# top 1 GiB is above 4 GiB, and no reservation sits there.
FOG_BANKS = [(0x40000000, 0x3dd00000), (0x80000000, 0x40000000),
             (0xc0000000, 0x80000000)]
FOG_RESERVED = [(0x45700000, 0x600000), (0x4ab00000, 0x6900000),
                (0x5c000000, 0xf00000), (0x5cf00000, 0x100000),
                (0x5d000000, 0x400000)]


class FogMemoryTests(unittest.TestCase):
    def test_four_gigabyte_map_uses_upper_bank(self):
        self.assertEqual(select_memory(fdt(FOG_BANKS, FOG_RESERVED)),
                         (0x100000000, 0x40000000))

    def test_upper_bank_without_reservations(self):
        self.assertEqual(select_memory(fdt(FOG_BANKS)), (0x100000000, 0x40000000))

    def test_sm6225_compatible_accepted(self):
        self.assertEqual(select_memory(fdt(FOG_BANKS, compatible=b'qcom,sm6225\0')),
                         (0x100000000, 0x40000000))

    def test_three_gigabyte_map_still_selects_upper_bank(self):
        banks = [(0x80000000, 0xc0000000), (0x100000000, 0x40000000)]
        self.assertEqual(select_memory(fdt(banks)), (0x100000000, 0x40000000))

    def test_stock_placeholder_rejected(self):
        with self.assertRaisesRegex(ValueError, 'live FDT'):
            select_memory(fdt([(0, 0)]))

    def test_no_upper_bank_reports_live_fdt(self):
        with self.assertRaisesRegex(ValueError, 'live FDT'):
            select_memory(fdt([(0x80000000, 0x80000000)]))


class FogAdtTests(unittest.TestCase):
    def build(self):
        return mkadt.build(device='fog', memory=(0x100000000, 0x80000000))

    def test_fog_requires_verified_memory(self):
        with self.assertRaises(ValueError):
            mkadt.build(device='fog')
        with self.assertRaises(ValueError):
            mkadt.build(device='fog', highmem=True, memory=(0x100000000, 0x80000000))
        with self.assertRaises(ValueError):
            mkadt.build(device='fog', qemu=True, memory=(0x100000000, 0x80000000))

    def test_fog_adt_contents(self):
        root, _ = adt.parse(adt.serialize(self.build()))
        children = {c.name: c for c in root.children}
        self.assertIn('fog-platform', children)
        self.assertNotIn('spes-platform', children)
        compatible = root.prop('compatible')
        self.assertIn(b'xiaomi,fog\0', compatible)
        self.assertIn(b'xiaomi,sweet\0', compatible)
        self.assertIn(b'qcom,khaje\0', compatible)
        chosen = children['chosen']
        self.assertEqual(struct.unpack('<Q', chosen.prop('dram-base'))[0], 0x100000000)
        self.assertEqual(struct.unpack('<Q', chosen.prop('dram-size'))[0], 0x80000000)
        self.assertEqual(struct.unpack('<I', chosen.prop('display-scale'))[0], 3)
        self.assertEqual(struct.unpack('<Q', chosen.prop('unique-chip-id'))[0],
                         0x464f470000000001)

    def test_fog_panel_geometry(self):
        root, _ = adt.parse(adt.serialize(self.build()))
        children = {c.name: c for c in root.children}
        fb = children['sweet-fbcon']
        self.assertEqual(struct.unpack('<QQ', fb.prop('reg')), (0x5c000000, 0xf00000))
        self.assertEqual(struct.unpack('<I', fb.prop('width'))[0], 720)
        self.assertEqual(struct.unpack('<I', fb.prop('height'))[0], 1650)
        self.assertEqual(struct.unpack('<I', fb.prop('stride'))[0], 720 * 4)

    def test_fog_cpus_are_gold_cluster(self):
        root, _ = adt.parse(adt.serialize(self.build()))
        cpus = next(c for c in root.children if c.name == 'cpus')
        self.assertEqual([struct.unpack('<I', c.prop('reg'))[0] for c in cpus.children],
                         [0x100, 0x101, 0x102, 0x103])
        self.assertEqual([struct.unpack('<I', c.prop('clock-frequency'))[0] for c in cpus.children],
                         [2400000000] * 4)

    def test_spec_keeps_its_own_profile(self):
        root, _ = adt.parse(adt.serialize(mkadt.build(device='spes',
                                                     memory=(0x100000000, 0xc0000000))))
        children = {c.name: c for c in root.children}
        self.assertIn('spes-platform', children)
        self.assertNotIn('fog-platform', children)
        self.assertEqual(struct.unpack('<I', children['sweet-fbcon'].prop('width'))[0], 1080)

    def test_rain_and_wind_aliases_share_board(self):
        # fog is the base codename: the verified handset identifies as rain
        # (220333QNY) and wind is the same family; all build the same
        # 720x1650 / /fog-platform layout with their own identity.
        for board in ('rain', 'wind'):
            with self.subTest(board=board):
                root, _ = adt.parse(adt.serialize(mkadt.build(
                    device=board, memory=(0x100000000, 0x40000000))))
                children = {c.name: c for c in root.children}
                self.assertIn('fog-platform', children)
                self.assertIn(('xiaomi,' + board + '\0').encode(), root.prop('compatible'))
                fb = children['sweet-fbcon']
                self.assertEqual(struct.unpack('<QQ', fb.prop('reg')), (0x5c000000, 0xf00000))
                self.assertEqual(struct.unpack('<I', fb.prop('width'))[0], 720)
                self.assertEqual(struct.unpack('<I', fb.prop('height'))[0], 1650)

    def test_unknown_device_rejected(self):
        with self.assertRaises(ValueError):
            mkadt.build(device='cancun')


if __name__ == '__main__':
    unittest.main()
