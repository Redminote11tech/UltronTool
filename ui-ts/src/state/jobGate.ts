/** Synchronous command admission; React rendering is deliberately not the lock. */
export class JobGate {
  private sequence = 0;
  active: number | null = null;
  target: string | null = null;
  begin(target: string | null): number | null {
    if (this.active !== null) return null;
    this.target = target;
    this.active = ++this.sequence;
    return this.active;
  }
  finish(id: number): boolean {
    if (id !== this.active) return false;
    this.active = null;
    return true;
  }
  get busy(): boolean { return this.active !== null; }
}

export function canSelectDevice(current: string | null, next: string | null, session: string, busy: boolean): boolean {
  return current === next || (!busy && session === "disconnected");
}
