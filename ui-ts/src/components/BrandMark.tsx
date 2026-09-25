/** Ultron brand mark — a hexagonal "eye". Cyan chrome; the red identity is
 * deliberately reserved for destructive states. */
export function BrandMark({ size = 24 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <defs>
        <linearGradient id="bm-g" x1="6" y1="4" x2="26" y2="28" gradientUnits="userSpaceOnUse">
          <stop stopColor="#7dedfb" />
          <stop offset="1" stopColor="#0ea5c4" />
        </linearGradient>
      </defs>
      <path
        d="M16 3 27 9.5v13L16 29 5 22.5v-13Z"
        stroke="url(#bm-g)"
        strokeWidth="2.2"
        strokeLinejoin="round"
      />
      <circle cx="16" cy="16" r="4.4" fill="url(#bm-g)" />
      <circle cx="16" cy="16" r="7.4" stroke="url(#bm-g)" strokeOpacity="0.35" strokeWidth="1.4" />
    </svg>
  );
}
