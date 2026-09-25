/** Vendor identities, per-vendor flash-page file slots, and the simulated
 * flash scenarios. Mirrors ModeTag from the Zig core's protocol registry. */

export type Mode =
  | "none"
  | "qualcomm_edl"
  | "qualcomm_crash"
  | "samsung"
  | "lg"
  | "mtk"
  | "spd";

export interface VendorMeta {
  name: string;
  modeLabel: string;
  color: string;
}

export const VENDORS: Record<Exclude<Mode, "none">, VendorMeta> = {
  qualcomm_edl: { name: "Qualcomm", modeLabel: "EDL 9008", color: "var(--v-qualcomm)" },
  qualcomm_crash: { name: "Qualcomm", modeLabel: "Crash dump", color: "var(--v-crash)" },
  samsung: { name: "Samsung", modeLabel: "Odin · Loke", color: "var(--v-samsung)" },
  lg: { name: "LG", modeLabel: "LAF", color: "var(--v-lg)" },
  mtk: { name: "MediaTek", modeLabel: "BROM", color: "var(--v-mtk)" },
  spd: { name: "Unisoc", modeLabel: "BSL · FDL", color: "var(--v-spd)" },
};

export const SIM_DEVICES: { id: Mode; label: string }[] = [
  { id: "none", label: "No device" },
  { id: "qualcomm_edl", label: "Qualcomm · EDL (05c6:9008)" },
  { id: "qualcomm_crash", label: "Qualcomm · crash dump (05c6:900e)" },
  { id: "samsung", label: "Samsung · download mode (04e8:685d)" },
  { id: "lg", label: "LG · LAF (1004:633e)" },
  { id: "mtk", label: "MediaTek · BROM (0e8d:0003)" },
  { id: "spd", label: "Unisoc · BSL (1782:*)" },
];

export interface SlotCfg {
  id: string;
  label: string;
  hint: string;
  required: boolean;
  /** simulated file that "lands" in the slot when clicked in sim mode */
  fake: string;
  fakeSize: number;
  /** present but non-functional; value explains why (shown locked) */
  disabledNote?: string;
}

/** Slot layouts mirror what each vendor module actually consumes today. */
export const SLOTS: Record<Exclude<Mode, "none">, SlotCfg[]> = {
  qualcomm_edl: [
    { id: "programmer", label: "Firehose programmer", hint: ".mbn / .elf — vendor-signed, user-supplied", required: true, fake: "firehose_SM8250_v2.mbn", fakeSize: 3_210_000 },
    { id: "rawprogram", label: "rawprogram XML", hint: "rawprogram*.xml — flash plan", required: true, fake: "rawprogram0.xml", fakeSize: 84_000 },
    { id: "patch", label: "patch XML", hint: "patch*.xml — partition table patches", required: false, fake: "patch0.xml", fakeSize: 12_000 },
  ],
  qualcomm_crash: [
    { id: "programmer", label: "Firehose programmer", hint: ".mbn / .elf — vendor-signed, user-supplied", required: true, fake: "firehose_SM8250_v2.mbn", fakeSize: 3_210_000 },
    { id: "rawprogram", label: "rawprogram XML", hint: "rawprogram*.xml — flash plan", required: true, fake: "rawprogram0.xml", fakeSize: 84_000 },
    { id: "patch", label: "patch XML", hint: "patch*.xml — partition table patches", required: false, fake: "patch0.xml", fakeSize: 12_000 },
  ],
  samsung: [
    { id: "bl", label: "BL", hint: "*.tar.md5 — bootloader", required: false, fake: "BL_G991B.tar.md5", fakeSize: 18_000_000 },
    { id: "ap", label: "AP", hint: "*.tar.md5 — system + kernel", required: true, fake: "AP_G991B.tar.md5", fakeSize: 4_700_000_000 },
    { id: "cp", label: "CP", hint: "*.tar.md5 — modem", required: false, fake: "CP_G991B.tar.md5", fakeSize: 42_000_000 },
    { id: "csc", label: "CSC", hint: "*.tar.md5 — consumer software customization", required: false, fake: "CSC_OMC_ODM_G991B.tar.md5", fakeSize: 120_000_000 },
    { id: "pit", label: "PIT", hint: "partition table — re-partition", required: false, fake: "G991B.pit", fakeSize: 8_400 },
  ],
  lg: [
    { id: "img", label: "Partition images", hint: "*.img written at sector offsets via LAF", required: true, fake: "boot.img + 3 more", fakeSize: 860_000_000 },
  ],
  mtk: [
    { id: "da", label: "Download agent", hint: "*.bin — user-supplied DA (SLA/DAA auth out of scope)", required: true, fake: "DA_SWSEC_v6.bin", fakeSize: 920_000 },
    { id: "images", label: "Firmware images", hint: "legacy-DA flash — partition name + file", required: true, fake: "boot.img + 5 more", fakeSize: 1_800_000_000 },
  ],
  spd: [
    { id: "fdl1", label: "FDL1", hint: "*.bin — user-supplied, loaded by bootrom BSL", required: true, fake: "fdl1.bin", fakeSize: 44_000 },
    { id: "fdl2", label: "FDL2", hint: "*.bin — loaded by FDL1, drives the flash ops", required: true, fake: "fdl2.bin", fakeSize: 182_000 },
    { id: "images", label: "Partition images", hint: "written by FDL2 by partition name", required: true, fake: "l-boot.img + 4 more", fakeSize: 2_100_000_000 },
    { id: "pac", label: "PAC archive", hint: "spreadtrum_flash .pac", required: false, fake: "", fakeSize: 0, disabledNote: "PAC parser — roadmap" },
  ],
};

export interface Step {
  label: string;
  /** share of the overall job's byte total */
  share: number;
  logs: string[];
}

export interface Scenario {
  title: string;
  totalBytes: number;
  steps: Step[];
}

const qc: Scenario = {
  title: "Flashing Qualcomm EDL plan",
  totalBytes: 2_830_000_000,
  steps: [
    { label: "Uploading firehose programmer", share: 0.02, logs: ["sahara: HELLO version 2.1, mode image-tx", "sahara: programmer 3.1 MB — streaming…", "sahara: DONE, status complete"] },
    { label: "Configuring firehose", share: 0.005, logs: ["firehose: configure MemoryName=ufs, ZlpAwareHost=1", "firehose: ACK — max payload 1048576", "firehose: sector size 4096"] },
    { label: "Programming rawprogram0.xml", share: 0.93, logs: ["firehose: program xbl 20+128 @ 0x…", "firehose: program abl @ 0x…", "firehose: program boot, dtbo, vendor"] },
    { label: "Applying patch0.xml", share: 0.02, logs: ["firehose: patch primarygpt", "firehose: patch backupgpt"] },
    { label: "Resetting device", share: 0.005, logs: ["firehose: power reset DelayInSeconds=1", "firehose: ACK"] },
  ],
};

const samsung: Scenario = {
  title: "Flashing Samsung bundle",
  totalBytes: 4_880_000_000,
  steps: [
    { label: "Handshaking with Loke", share: 0.002, logs: ["odin: request OK — protocol v2", "odin: begin session, total 4.88 GB"] },
    { label: "Dumping PIT", share: 0.003, logs: ["odin: dump PIT — 47 partitions", "odin: PIT dump complete (4.7 KB)"] },
    { label: "Flashing AP sequence", share: 0.9, logs: ["odin: sending sequence 3/31 — modem_debug", "odin: flashing sequence 7/31 onto boot", "odin: flashing sequence 19/31 onto system"] },
    { label: "Flashing BL + CSC", share: 0.08, logs: ["odin: flashing BL onto sbl1", "odin: flashing CSC onto omr"] },
    { label: "Rebooting device", share: 0.005, logs: ["odin: reset — device reboots"] },
  ],
};

const lg: Scenario = {
  title: "Flashing LG LAF images",
  totalBytes: 860_000_000,
  steps: [
    { label: "Opening /dev/block/mmcblk0", share: 0.002, logs: ["laf: HELO — protocol 1.1, device min 0.128", "laf: open fd=4 rw"] },
    { label: "Writing boot + system images", share: 0.95, logs: ["laf: WRTE boot @ sector 526336 (16.0 MiB chunks)", "laf: WRTE system @ sector 1310720"] },
    { label: "Verifying writes", share: 0.04, logs: ["laf: READ-echo ok — boot", "laf: READ-echo ok — system"] },
    { label: "Rebooting", share: 0.002, logs: ["laf: CTRL RSET — rebooting"] },
  ],
};

const mtk: Scenario = {
  title: "Flashing MediaTek legacy-DA plan",
  totalBytes: 1_800_000_000,
  steps: [
    { label: "Syncing with BROM", share: 0.001, logs: ["brom: echo sync ok — hw_code 0x0717 (MT6785)", "brom: SEND_DA 0x92000 bytes @ 0x40020000"] },
    { label: "Booting download agent", share: 0.004, logs: ["brom: checksum ok — JUMP_DA", "da: version v6, host speed ok"] },
    { label: "Writing images", share: 0.95, logs: ["da: switch to EMMC_PART_USER", "da: write boot @ 0x… (1 MiB packets)", "da: write vendor, system, product"] },
    { label: "Finishing", share: 0.004, logs: ["da: finish — device reboots"] },
  ],
};

const spd: Scenario = {
  title: "Flashing Unisoc FDL plan",
  totalBytes: 2_100_000_000,
  steps: [
    { label: "Connecting bootrom BSL", share: 0.001, logs: ["bsl: CHECK_BAUD ok — v1.0.0"] },
    { label: "Uploading FDL1 → FDL2", share: 0.004, logs: ["bsl: START/MIDST/END — fdl1 43 KB", "bsl: EXEC ok", "fdl2: handshake — mode64 select"] },
    { label: "Writing partitions", share: 0.99, logs: ["fdl2: erase prodnv", "fdl2: write l-boot @ 0x… (512 KiB frames)", "fdl2: write l-system, l-vendor"] },
    { label: "Rebooting", share: 0.001, logs: ["fdl2: reset"] },
  ],
};

export const SCENARIOS: Record<"qualcomm_edl" | "samsung" | "lg" | "mtk" | "spd", Scenario> = {
  qualcomm_edl: qc,
  samsung,
  lg,
  mtk,
  spd,
};
