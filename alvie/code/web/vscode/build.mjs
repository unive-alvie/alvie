// The extension, in out/: extension.js (for the extension host of VS Code for the Web), the webview of the preview
// (preview.js, preview.css), the renderer of models in tutorials (renderer.js), and the self-test (selftest.js).
// What it serves to the browser (alvie-web, the simulators, the files of a first visit) is in bundle/, made by
// prepare.sh.
import * as esbuild from 'esbuild';
import { cpSync, existsSync } from 'node:fs';

if (!existsSync('bundle/alvie/alvie-web.js')) throw new Error('bundle/ is not prepared: run prepare.sh WEB_DIR SIM_DIR first');
const common = { bundle: true, minify: true, platform: 'browser', target: 'es2022', logLevel: 'warning' };
const node = { ...common, format: 'cjs', external: ['vscode'] };
await esbuild.build({ ...node, entryPoints: ['src/extension.js'], outfile: 'out/extension.js' });
await esbuild.build({ ...node, entryPoints: ['src/selftest.js'], outfile: 'out/selftest.js' });
await esbuild.build({ ...common, entryPoints: ['src/preview-view.js'], outfile: 'out/preview.js', format: 'iife' });
await esbuild.build({ ...common, entryPoints: ['src/renderer.js'], outfile: 'out/renderer.js', format: 'esm' });
cpSync('media/preview.css', 'out/preview.css');
