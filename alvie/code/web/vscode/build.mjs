// The extension, in out/: the extension (extension.js, for the extension host of VS Code for the Web), the webview of
// the preview (preview.js, preview.css), and, in ide/, what the IDE serves (alvie-web, the simulators and the files of a
// first visit: web/ide/public, made by web/ide/prepare.sh). The modules of the IDE come from web/ide/src, whose
// dependencies (npm ci in web/ide) esbuild resolves there.
import * as esbuild from 'esbuild';
import { cpSync, rmSync, existsSync } from 'node:fs';

const common = { bundle: true, minify: true, platform: 'browser', target: 'es2022', logLevel: 'info' };
await esbuild.build({ ...common, entryPoints: ['src/extension.js'], outfile: 'out/extension.js', format: 'cjs', external: ['vscode'] });
await esbuild.build({ ...common, entryPoints: ['src/selftest.js'], outfile: 'out/selftest.js', format: 'cjs', external: ['vscode'] });
await esbuild.build({ ...common, entryPoints: ['src/preview-view.js'], outfile: 'out/preview.js', format: 'iife' });
cpSync('media/preview.css', 'out/preview.css');
if (!existsSync('../ide/public/alvie/alvie-web.js')) throw new Error('web/ide/public is not prepared: run web/ide/prepare.sh first');
rmSync('ide', { recursive: true, force: true });
cpSync('../ide/public', 'ide', { recursive: true, dereference: true });
