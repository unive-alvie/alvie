// Starts VS Code for the Web (vscode/, built by build-workbench.sh) on the folder alvie:/, with the extension of ALVIE
// (alvie/) built in: the page code.html. A query ?folder=URI opens another folder, ?tutorial=ID a tutorial.
import { create, URI } from './vscode/out/vs/workbench/workbench.web.main.internal.js';

const here = new URL('.', window.location.href);
const query = new URL(window.location.href).searchParams;
const folder = query.get('folder') ?? 'alvie:/';
// ?tutorial=ID opens the tutorial alvie:/tutorials/ID.alvienb (see index.html); without it, an empty session
const tutorial = query.get('tutorial');
const defaultLayout = tutorial && /^[\w.-]+$/.test(tutorial)
  ? { force: true, editors: [{ uri: URI.from({ scheme: 'alvie', path: `/tutorials/${tutorial}.alvienb` }) }] }
  : undefined;
create(document.body, {
  workspaceProvider: {
    workspace: { folderUri: URI.parse(folder) },
    trusted: true,
    open: async (workspace) => {
      if (!workspace || !('folderUri' in workspace)) return false;
      window.location.href = `${here.href}code.html?folder=${encodeURIComponent(workspace.folderUri.toString(true))}`;
      return true;
    },
  },
  defaultLayout,
  configurationDefaults: { 'workbench.colorTheme': 'Default Dark Modern' },
  additionalBuiltinExtensions: [URI.parse(new URL('alvie', here).href)],
  productConfiguration: {
    nameShort: 'ALVIE', nameLong: 'ALVIE in your browser', applicationName: 'alvie', enableTelemetry: false,
    // The webviews (the preview of models) from this site, not from the CDN of Microsoft
    webviewContentExternalBaseUrlTemplate: new URL('vscode/out/vs/workbench/contrib/webview/browser/pre/', here).href,
  },
  windowIndicator: { label: '$(beaker) ALVIE', tooltip: 'ALVIE runs in your browser' },
});
