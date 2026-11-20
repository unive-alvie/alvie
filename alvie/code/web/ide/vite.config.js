// The IDE is a static site: relative paths, so that it works under any directory (e.g. /alvie/ide/ on GitHub Pages)
import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  build: { target: 'es2022', outDir: 'dist', chunkSizeWarningLimit: 4096 },
  worker: { format: 'es' },
});
