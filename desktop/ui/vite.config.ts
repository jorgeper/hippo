// Vite for the desk page: `npm run dev` serves it on http://localhost:5173 (the origin `hippo ui --dev` allows) and proxies
// /api and /media to the local server; `npm run build` writes ui/dist, which `hippo ui` serves.
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';

const api = { target: 'http://127.0.0.1:4477', changeOrigin: true };

export default defineConfig({
  root: fileURLToPath(new URL('.', import.meta.url)),
  build: { outDir: 'dist', emptyOutDir: true, modulePreload: { polyfill: false } },
  // strictPort: the server allows exactly this origin, so another port would only be refused.
  server: { port: 5173, strictPort: true, proxy: { '/api': api, '/media': api } },
});
