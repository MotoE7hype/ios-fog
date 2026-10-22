#!/usr/bin/env python3
"""Build the minimal Apple Device Tree that the SWEET xnu needs to boot.

Only what the early boot path actually reads (see NOTES.md); every MMIO
address comes from the khaje (SM6225) live FDT. The device profile selects
the DT identity, panel geometry and clock; spes/fog additionally require the
bootloader-populated live FDT for RAM. Usage:  mkadt.py OUT.adt [--device
topaz|spes|fog] [--memory-dtb LIVE.dtb] [--dump] [--qemu] [--highmem]
"""
import argparse, hashlib, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402

# Kernel-managed RAM: above every Qualcomm XPU carve-out (see NOTES.md)
PHYS_BASE = 0xb0000000
MEM_SIZE = 0x4d000000
# --highmem (phone only): the whole upper DDR bank. The topaz live FDT memory
# node is <0x40000000 0x3bb00000>, <0x80000000 3G>, <0x1_40000000 4G>; every
# fixed reserved-memory carve-out is below 0x63900000 and the dynamic pools are
# limited below 4G.
HIGH_PHYS_BASE = 0x140000000
HIGH_MEM_SIZE = 0x100000000
# /arm-io children are relative to this; it must not be 0 (serial_init bails)
SOC_BASE = 0x01000000

# interrupt-controller@f200000 (redistributor-stride 0x20000, 8 cores)
GICD, GICD_SIZE = 0x0f200000, 0x10000
GICR, GICR_SIZE = 0x0f300000, 0x100000
# cont_splash_region left lit by ABL (same carve-out on khaje/spes/fog)
FB_SIZE = 0xf00000
SWEET_ECID = 0x544f50415a000001  # 'TOPAZ' + 1, synthetic
# Internal UFS host (ufshc@4804000 "ufs_mem"); QEMU virt has none
UFS, UFS_SIZE = 0x04804000, 0x3000
TIMEBASE = 19200000
VTIMER_INTID = 19
# QEMU virt (-M virt,gic-version=3 -cpu cortex-a76): GICD/GICR and the generic timer's CNTFRQ
QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE = 0x08000000, 0x080a0000, 62500000
QEMU_VTIMER_INTID = 27

# Per-device identity and panel. Only "topaz" keeps a static RAM layout; the
# ports require --memory-dtb because their stock memory nodes are zero-filled.
#   clock:    Gold-cluster nominal clock in Hz
#   chip_id:  synthetic unique-chip-id (never the phone's real ECID)
#   platform: optional kernel platform marker node (SecureDTLookupEntry)
#   fb:       (splash base, width, height); stride is width * 4
#   canvas:   IOMobileFramebuffer canvas reported to iOS (iPhone X logical size)
#
# The 720x1650 khaje board ships as Redmi 10C (fog) and Redmi 10 Power (rain,
# model 220333QNY, verified live); all three Redmi 10 variants (fog, rain,
# wind) fall under the fog base and share the /fog-platform marker, so one
# kernel patch serves them. All panel nodes in the verified live FDT are
# 720x1650; wind's panel is assumed identical until a wind unit is probed.
def _khaje_720():
    return dict(clock=2400000000, chip_id=0x464f470000000001,
                platform='fog-platform', live_memory=True,
                fb=(0x5c000000, 720, 1650),
                canvas=(1125, 2436), display_scale=3)


DEVICES = {
    'topaz': dict(clock=2803200000, chip_id=SWEET_ECID, platform=None,
                  live_memory=False, fb=(0x5c000000, 1080, 2400),
                  canvas=(1125, 2436), display_scale=3),
    'spes': dict(clock=2400000000, chip_id=0x5350455300000001,
                 platform='spes-platform', live_memory=True,
                 fb=(0x5c000000, 1080, 2400),
                 canvas=(1125, 2436), display_scale=3),
    # iPhone X logical canvas is kept so UIKit has a supported screen class;
    # until the present() scale path exists the panel shows the centre crop.
    'fog': _khaje_720(),
    'rain': _khaje_720(),
    'wind': _khaje_720(),
}

# The iOS userland is the iPhone X (iPhone10,3 / D22AP) IPSW. MobileGestalt
# derives product type, device class, home-button-less UI, artwork etc. from
# the root identity and /product of the real D22AP device tree. That tree is
# an Apple artifact (kept out of git): extract it from the IPSW with
#   tools/remotezip.py URL DeviceTree.d22ap.im4p DIR
#   ipsw img4 im4p extract DIR/Firmware/all_flash/DeviceTree.d22ap.im4p -o d22ap.adt
D22AP_ADT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../research/ipsw-x/d22ap.adt')


def d22ap_product(path=D22AP_ADT):
    """/product properties of the real D22AP tree, without the syscfg
    placeholders iBoot would fill in (flag bit set) and the node bookkeeping."""
    if not os.path.exists(path):
        print(f'warning: {path} missing, no /product node', file=sys.stderr)
        return None
    root, _ = adt.parse(open(path, 'rb').read())
    for c in root.children:
        if dict((k, v) for k, f, v in c.props).get('name') == b'product\0':
            return [(k, v) for k, f, v in c.props if not f and k not in ('name', 'AAPL,phandle')]
    raise SystemExit(f'{path}: no /product node')

u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
cstr = lambda s: s.encode() + b'\0'


def node(name, props=(), children=()):
    n = adt.Node()
    n.props = [('name', 0, cstr(name))] + [(k, 0, v) for k, v in props]
    n.children = list(children)
    return n


def build(seed=None, qemu=False, highmem=False, device="topaz", memory=None):
    """qemu=True: same tree, but with QEMU virt's GIC addresses and CNTFRQ (tools/qemu-sweet.py)."""
    if device not in DEVICES:
        raise ValueError('unknown device')
    profile = DEVICES[device]
    phys_base, mem_size = (HIGH_PHYS_BASE, HIGH_MEM_SIZE) if highmem else (PHYS_BASE, MEM_SIZE)
    if profile['live_memory']:
        if highmem or qemu or memory is None:
            raise ValueError(f'{device} requires --memory-dtb from the live phone; no --highmem/--qemu')
        phys_base, mem_size = memory
    fb_base, fb_w, fb_h = profile['fb']
    fb_stride = fb_w * 4
    canvas_w, canvas_h = profile['canvas']
    gicd, gicr, timebase = (QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE) if qemu else (GICD, GICR, TIMEBASE)
    seed = seed if seed is not None else os.urandom(64)
    phandle = iter(range(1, 1000))
    ph = lambda: ('AAPL,phandle', u32(next(phandle)))

    chosen = node('chosen', [
        ph(),
        ('dram-base', u64(phys_base)),
        ('dram-size', u64(mem_size)),
        ('random-seed', seed),
        ('debug-enabled', u32(1)),
        ('firmware-version', cstr(device + '-shim')),
        ('system-firmware-version', cstr(device + '-shim')),
        # iBoot's SHA-384 of the boot manifest; /sbin/mount -P 1 exits unless
        # it exists (bind mounts /private/preboot/<hex>/usr/standalone/firmware,
        # tolerating a missing directory). Fixed stand-in value.
        ('boot-manifest-hash', hashlib.sha384((device + ' boot manifest').encode()).digest()),
        # libimg4 (cryptexd) aborts "failed to get crypto algorithm" without
        # it; real A11+ device trees say sha2-384.
        ('crypto-hash-method', cstr('sha2-384')),
        # MobileGestalt's screen class: display-scale (u32, default 0) comes
        # from /chosen, the pixel size from IOMobileFramebuffer. Scale 0 makes
        # SpringBoard's FBSDisplayMode "infxinf@0x" invalid. The ports report
        # the iPhone X class canvas at 3x (375x812 points).
        ('display-scale', u32(profile['display_scale'])),
        # XNU derives IOPlatformUUID (gethostuuid) from these on arm; without
        # them CFPreferences cannot use kCFPreferencesCurrentHost (no ByHost
        # files), so e.g. DataMigration never records LastSystemVersion and
        # migrates on every boot. Synthetic ECID (not the phone's); chip-id
        # of the A11 that the iPhone X userland expects.
        ('unique-chip-id', struct.pack('<Q', profile['chip_id'])),
        ('chip-id', u32(0x8015)),
        # Security status as on a dev-fused, undemoted board (tuple 0,0,1,1):
        # MobileGestalt reads these from /chosen, and mobileactivationd's
        # DeviceType then takes its native "Hactivation" branch (state
        # Activated without an activation record; no SEP, no baseband here).
        ('certificate-production-status', u32(0)),
        ('effective-production-status-ap', u32(0)),
        ('certificate-security-mode', u32(1)),
        ('effective-security-mode-sep', u32(1)),
    ], [node('memory-map', [ph()]),
        # Local boot policy (kern_csr.c): SIP relaxed like `csrutil disable`
        # (lp-sip0: untrusted kexts, unrestricted FS, task_for_pid, kernel
        # debugger, dtrace, nvram), lp-sip1: unauthenticated (unsealed) root.
        # The iOS shared cache is in no trust cache, so dyld can only map it
        # with CSR_ALLOW_UNRESTRICTED_FS (vm_unix.c shared region checks).
        node('asmb', [ph(), ('lp-sip0', u64(0x6f)), ('lp-sip1', u32(1))])])

    # Khaje SMP: only the four Cortex-A73 (gold) cores, MPIDR 0x100-0x103:
    # the Kryo Silver cores have no 16K granule, so the shim boots xnu
    # on gold CPU 0x100 and parks the silver cluster. One cluster. The kernel defaults to one
    # and uses cpus=N to select an initial prefix (N <= 8).
    # QEMU retains its original single-CPU tree: its MPIDRs differ from sweet.
    cpu_nodes = []
    for core in range(1 if qemu else 4):
        cpu_nodes.append(node(f'cpu{core}', [
            ph(),
            ('device_type', cstr('cpu')),
            ('compatible', cstr('qcom,kryo260') + cstr('qcom,kryo470') + cstr('ARM,v8')),
            ('reg', u32(core if qemu else 0x100 | core)),  # actual MPIDR Aff1:Aff0, NOT logical ID
            ('cpu-id', u32(core)),   # descriptive: XNU assigns IDs by DT order
            ('cluster-id', u32(0)),  # descriptive; see ml_parse_cpu_topology
            ('cluster-type', u32(0)),  # homogeneous CLUSTER_TYPE_SMP, not AMP
            ('die-cluster-id', u32(0)),
            ('cluster-core-id', u32(core)),
            ('l2-cache-id', u32(0)),  # gold L2
            ('l3-cache-id', u32(0)),
            ('state', cstr('running' if core == 0 else 'stopped')),
            ('timebase-frequency', u32(timebase)),
            ('clock-frequency', u32(profile['clock'])),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(1866000000)),
            ('peripheral-frequency', u32(timebase)),
            ('fixed-frequency', u32(timebase)),
        ]))
    cpus = node('cpus', [ph(), ('#address-cells', u32(1)),
                         ('#size-cells', u32(0))], cpu_nodes)

    gic = node('gic', [
        ph(),
        ('compatible', cstr('arm,gic-v3')),
        ('interrupt-controller', b''),
        ('virtual-timer-intid', u32(QEMU_VTIMER_INTID if qemu else VTIMER_INTID)),
        ('reg', u64(gicd - SOC_BASE, GICD_SIZE, gicr - SOC_BASE, GICR_SIZE)),
    ])
    arm_io = node('arm-io', [
        ph(),
        ('device_type', cstr('sweet-io')),
        ('compatible', cstr('sweet-io') + cstr('arm-io')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
        ('ranges', u64(0, SOC_BASE, 0x100000000 - SOC_BASE)),
    ], [gic,
        # No hardware: watchdogd checks IODeviceTree:/arm-io/wdt for no-pmu and
        # otherwise crashes trying to set the PMU boot stage (customer builds
        # ignore the -wdt_no_pmu boot-arg).
        node('wdt', [ph(), ('no-pmu', u32(1))]),
        # Main display: IOMobileFramebuffer.framework counts /arm-io children
        # with this device_type and reads the canvas size from the node
        # (the presented iPhone X size, see SweetFramebuffer.cpp);
        # the kernel's AppleCLCD matches the compatible string.
        node('disp0', [
            ph(),
            ('device_type', cstr('display-subsystem')),
            ('compatible', cstr('sweet,display')),
            ('canvas-width', u32(canvas_w)),
            ('canvas-height', u32(canvas_h)),
        ])])

    fbcon = node('sweet-fbcon', [
        ph(),
        ('reg', u64(fb_base, FB_SIZE)),
        ('width', u32(fb_w)),
        ('height', u32(fb_h)),
        ('stride', u32(fb_stride)),
    ])

    # bsd/dev/sweet_ufs.c: the UFS host ABL leaves running (absolute physical reg).
    ufs = node('sweet-ufs', [
        ph(),
        ('compatible', cstr('qcom,ufshc')),
        ('reg', u64(UFS, UFS_SIZE)),
    ])

    # pmap_compute_max_asids requires the node even when no overrides are set.
    # An absent pmap-max-asids property selects XNU's own MAX_ASIDS default.
    # No effaceable storage: keybagd then reads /private/var/keybags/systembag.kb
    # as a plain plist instead of decrypting it with the effaceable key.
    defaults = node('defaults', [ph(), ('no-effaceable-storage', u32(1))])

    # MobileGestalt HomeButtonType = IODeviceTree:/buttons home-button-type
    # (D22AP: 2, no Home button; absent = 0 = Home-button device).
    buttons = node('buttons', [
        ph(),
        ('button-names', cstr('volup') + cstr('voldown') + cstr('hold')),
        ('home-button-type', u32(2)),
        ('opposed-power-vol-buttons', u32(1)),
    ])

    product_props = d22ap_product()
    product = [node('product', [ph()] + product_props)] if product_props else []

    # Identity of the iPhone X whose userland runs here: compatible[0] is
    # hw.model/hw.target (D22AP), model is hw.machine/hw.product
    # (iPhone10,3). 'xiaomi,sweet' and qcom,kryo470 stay because the
    # SweetPlatformExpert and CPU IONameMatch still use them.
    return node('device-tree', [
        ph(),
        ('compatible', cstr('D22AP') + cstr('iPhone10,3') + cstr('xiaomi,' + device) + cstr('xiaomi,sweet') + cstr('qcom,khaje') + cstr('AppleARM')),
        ('model', cstr('iPhone10,3')),
        ('target-type', cstr('D22')),
        ('target-sub-type', cstr('D22AP')),
        ('manufacturer', cstr('Apple Inc.')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
    ], [chosen, defaults, cpus, arm_io, fbcon, buttons] + ([node(profile['platform'])] if profile['platform'] else []) + product + ([] if qemu else [ufs]))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('out')
    ap.add_argument('--device', choices=sorted(DEVICES), default='topaz')
    ap.add_argument('--memory-dtb', help='live /sys/firmware/fdt (stock images have no RAM map)')
    ap.add_argument('--dump', action='store_true')
    ap.add_argument('--qemu', action='store_true')
    ap.add_argument('--highmem', action='store_true')
    args = ap.parse_args()
    try:
        memory = None
        if args.memory_dtb:
            from spes_memory import select_memory
            memory = select_memory(open(args.memory_dtb, 'rb').read())
        root = build(qemu=args.qemu, highmem=args.highmem, device=args.device, memory=memory)
    except ValueError as e:
        ap.error(str(e))
    blob = adt.serialize(root)
    open(args.out, 'wb').write(blob)
    if args.dump:
        adt.dump(adt.parse(blob)[0])
    print(f'{args.out}: {len(blob)} bytes', file=sys.stderr)
