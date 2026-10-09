export interface Sample { at: number; done: number; total: number; label: string }
export function progressSample(previous: Sample | null, event: { done: number; total: number; fraction: number; label: string }, at: number) {
  const comparable = previous && previous.label === event.label && previous.total === event.total && event.done >= previous.done && at > previous.at;
  const rate = comparable ? (event.done - previous.done) * 1000 / (at - previous.at) : 0;
  return {
    fraction: Number.isFinite(event.fraction) && event.fraction >= 0 ? Math.min(1, event.fraction) : null,
    rate, eta: rate > 0 ? Math.max(0, Math.round((event.total - event.done) / rate)) : 0,
    sample: { at, done: event.done, total: event.total, label: event.label },
  };
}
