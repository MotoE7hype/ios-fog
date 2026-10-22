"""Read a live khaje FDT and select contiguous RAM above 4 GiB for XNU.

Shared by the spes and fog ports. Never infer physical RAM addresses from the
advertised RAM capacity. Qualcomm ABL fills /memory; the placeholder in stock
vendor_boot is deliberately rejected.
"""
import struct

# XNU's kernel, ADT and boot_args are placed at dram-base, so the range must
# be large enough for the kernel plus a diagnostic ramdisk.
MIN_RANGE = 0x20000000          # 512 MiB
ALIGN = 0x2000000               # 32 MiB, one 16K L2 block
LOW_LIMIT = 0x100000000         # 4 GiB, above every khaje XPU carve-out
# Upper search bound (16 GiB); even 8 GB khaje phones stay below it.
HIGH_LIMIT = 0x400000000


def parse(blob):
    def words(offset, count):
        if offset < 0 or offset + count * 4 > len(blob):
            raise ValueError('truncated FDT')
        return struct.unpack_from('>' + 'I' * count, blob, offset)
    magic, total, off, strings, reserve, version, _, _, ns, ds = words(0, 10)
    if magic != 0xd00dfeed or version < 17 or total > len(blob):
        raise ValueError('invalid FDT header')
    end = off + ds
    if end > total or strings + ns > total:
        raise ValueError('invalid FDT sections')
    def string(pos, limit):
        if not 0 <= pos < limit:
            raise ValueError('invalid FDT string offset')
        stop = blob.find(b'\0', pos, limit)
        if stop < 0:
            raise ValueError('unterminated FDT string')
        return blob[pos:stop].decode('ascii'), stop + 1
    stack, nodes = [], {}
    while off + 4 <= end:
        token, = words(off, 1); off += 4
        if token == 1:
            name, off = string(off, end); off = (off + 3) & ~3
            stack.append(name); nodes['/'.join(stack)] = {}
        elif token == 2:
            if not stack:
                raise ValueError('unbalanced FDT')
            stack.pop()
        elif token == 3:
            if off + 8 > end or not stack:
                raise ValueError('invalid FDT property')
            size, nameoff = words(off, 2); off += 8
            if off + size > end:
                raise ValueError('truncated FDT property')
            name, _ = string(strings + nameoff, strings + ns)
            nodes['/'.join(stack)][name] = blob[off:off + size]
            off = (off + size + 3) & ~3
        elif token == 9:
            if stack:
                raise ValueError('unbalanced FDT')
            break
        elif token != 4:
            raise ValueError('invalid FDT token')
    else:
        raise ValueError('missing FDT end')
    reservations = []
    while reserve + 16 <= total:
        base, size = struct.unpack_from('>QQ', blob, reserve); reserve += 16
        if not base and not size:
            return nodes, reservations
        reservations.append((base, size))
    raise ValueError('unterminated FDT reservations')


def select_memory(blob):
    nodes, reserved = parse(blob)
    root = nodes.get('', {})
    compatible = root.get('compatible', b'')
    if b'qcom,khaje' not in compatible and b'qcom,sm6225' not in compatible:
        raise ValueError('expected a live khaje/sm6225 device tree (spes, fog)')
    def cells(props, key, default):
        value = props.get(key, struct.pack('>I', default))
        if len(value) != 4:
            raise ValueError('invalid cell count')
        return struct.unpack('>I', value)[0]
    def ranges(value, ac, sc):
        if ac not in (1, 2) or sc not in (1, 2) or len(value) % (4 * (ac + sc)):
            raise ValueError('invalid FDT address range')
        return [(int.from_bytes(value[i:i + 4*ac], 'big'),
                 int.from_bytes(value[i + 4*ac:i + 4*(ac+sc)], 'big'))
                for i in range(0, len(value), 4*(ac+sc))]
    ac, sc = cells(root, '#address-cells', 2), cells(root, '#size-cells', 1)
    banks = []
    for path, props in nodes.items():
        if path.count('/') == 1 and props.get('device_type') == b'memory\0':
            banks += ranges(props.get('reg', b''), ac, sc)
    rp = nodes.get('/reserved-memory', {})
    rac, rsc = cells(rp, '#address-cells', ac), cells(rp, '#size-cells', sc)
    for path, props in nodes.items():
        if path.startswith('/reserved-memory/') and path.count('/') == 2:
            if props.get('status') == b'disabled\0':
                continue
            reserved += ranges(props.get('reg', b''), rac, rsc)
            if 'size' in props and 'reg' not in props:
                allocation = ranges(props.get('alloc-ranges', b''), rac, rsc)
                if not allocation or any(b + s > 0x100000000 for b, s in allocation):
                    raise ValueError('unresolved dynamic reservation above 4 GiB')
    candidates = []
    for base, size in banks:
        spans = [(max(base, LOW_LIMIT), min(base + size, HIGH_LIMIT))]
        for rb, rs in reserved:
            spans = [(a, b) for lo, hi in spans for a, b in
                     ((lo, min(hi, rb)), (max(lo, rb + rs), hi)) if a < b]
        for lo, hi in spans:
            lo = (lo + ALIGN - 1) & ~(ALIGN - 1)
            hi &= ~(ALIGN - 1)
            if hi - lo >= MIN_RANGE:
                candidates.append((lo, hi - lo))
    if not candidates:
        raise ValueError('no verified >=512 MiB RAM range above 4 GiB; '
                         'supply the live FDT (4 GB devices map their upper bank '
                         'above 4 GiB; check /memory and /reserved-memory)')
    return max(candidates, key=lambda item: item[1])
