// Starts VS Code for the Web (vscode/, built by build-workbench.sh) on the folder alvie:/, with the extension of ALVIE
// (alvie/) built in. A query ?folder=URI opens another folder.
import { create, URI } from './vscode/out/vs/workbench/workbench.web.main.internal.js';

const here = new URL('.', window.location.href);
const folder = new URL(window.location.href).searchParams.get('folder') ?? 'alvie:/';
create(document.body, {
  workspaceProvider: {
    workspace: { folderUri: URI.parse(folder) },
    trusted: true,
    open: async (workspace) => {
      if (!workspace || !('folderUri' in workspace)) return false;
      window.location.href = `${here.href}?folder=${encodeURIComponent(workspace.folderUri.toString(true))}`;
      return true;
    },
  },
  additionalBuiltinExtensions: [URI.parse(new URL('alvie', here).href)],
  productConfiguration: { nameShort: 'ALVIE', nameLong: 'ALVIE in your browser', applicationName: 'alvie', enableTelemetry: false },
  windowIndicator: { label: '$(beaker) ALVIE', tooltip: 'ALVIE runs in your browser' },
});
