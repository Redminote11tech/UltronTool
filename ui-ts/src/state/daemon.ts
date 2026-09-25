/** Wire contract with the Zig IPC daemon (src/ipc/codec.zig). One JSON
 * object per line: requests out via daemonSend, events in via daemonListen.
 * Keep in sync with the Zig side — both files name each other. */

import { daemonListen, daemonSend } from "../lib/tauri";
import type { Level } from "./bus";

export interface DaemonDevice {
  path: string;
  vid: number;
  pid: number;
  bus: number;
  devnum: number;
  mode: string;
  label: string;
  manufacturer: string;
  product: string;
  serial: string;
}

export type SessionState =
  | "disconnected"
  | "needs_loader"
  | "firehose_ready"
  | "samsung_ready"
  | "lg_ready"
  | "spd_ready";

export type DaemonEvent =
  | { ev: "hello"; protocol: string; version: number }
  | { ev: "log"; level: Level | "debug"; text: string }
  | { ev: "device_added" } & DaemonDevice
  | { ev: "device_removed"; path: string }
  | { ev: "progress"; fraction: number; done: number; total: number; label: string }
  | { ev: "state"; state: SessionState }
  | { ev: "finished"; success: boolean; message: string }
  | {
      ev: "chip_info";
      protocol_version: number;
      serial: number | null;
      hwid: string | null;
      msm_id: number;
      oem_id: number;
      model_id: number;
      pkhash: string;
    }
  | {
      ev: "partitions";
      lun: number;
      sector_size: number;
      luns: number;
      vip: boolean;
      parts: { name: string; first_lba: number; last_lba: number }[];
    }
  | { ev: "huawei_app"; gen: number; entries: unknown[] }
  | { ev: "daemon_gone"; reason?: string };

export function parseDaemonLine(line: string): DaemonEvent | null {
  try {
    return JSON.parse(line) as DaemonEvent;
  } catch {
    return null;
  }
}

export function sendDaemon(cmd: unknown): void {
  void daemonSend(cmd).catch(() => {});
}

/** Subscribe with a callback per parsed event; returns the unsubscribe fn. */
export function onDaemonEvent(cb: (e: DaemonEvent) => void): () => void {
  return daemonListen((line) => {
    const parsed = parseDaemonLine(line);
    if (parsed) cb(parsed);
  });
}
