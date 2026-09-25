import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// clearScreen:false so native (Tauri) terminal output stays visible;
// strictPort because the Tauri shell pins devUrl to this port.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 5173, strictPort: true },
});
