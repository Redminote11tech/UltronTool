//! Application stylesheet (embedded; loaded once at startup).

pub const css =
    \\/* Ultron */
    \\.log-view {
    \\  font-family: monospace;
    \\  font-size: 12px;
    \\  line-height: 1.4;
    \\}
    \\
    \\.log-view text {
    \\  background: rgba(0, 0, 0, 0.25);
    \\}
    \\
    \\.device-badge {
    \\  font-weight: bold;
    \\  padding: 2px 10px;
    \\  border-radius: 999px;
    \\}
    \\
    \\.chip-grid {
    \\  font-family: monospace;
    \\  font-size: 12px;
    \\}
    \\
    \\.big-start {
    \\  padding: 10px 36px;
    \\  font-weight: bold;
    \\}
    \\
    \\.state-chip {
    \\  padding: 3px 12px;
    \\  border-radius: 999px;
    \\  font-weight: 700;
    \\}
    \\
    \\.state-chip.ok {
    \\  background: rgba(38, 162, 105, 0.22);
    \\  color: #2ec27e;
    \\}
    \\
    \\.state-chip.warn {
    \\  background: rgba(229, 165, 10, 0.20);
    \\  color: #e5a50a;
    \\}
    \\\\
    \\\\.state-chip.dim {
    \\\\  background: rgba(127, 127, 127, 0.15);
    \\\\}
    \\\\
    \\\\.ultron-progress trough {
    \\\\  border-radius: 999px;
    \\\\}
    \\\\
    \\\\.ultron-progress progress {
    \\\\  border-radius: 999px;
    \\\\  background: linear-gradient(to right, #3584e4, #1c71d8);
    \\\\  box-shadow: 0 0 8px rgba(53, 132, 228, 0.55);
    \\\\}
    ;
