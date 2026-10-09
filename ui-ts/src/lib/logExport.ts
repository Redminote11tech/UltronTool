export function formatLog(lines: readonly { at: number; level: string; text: string }[]): string {
  return lines.map(line => `${new Date(line.at).toISOString()} [${line.level.toUpperCase()}] ${line.text}`).join("\n") + "\n";
}
