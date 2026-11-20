# ALVIE in VS Code for the Web

A web extension of VS Code that runs ALVIE in the browser, on the modules of the IDE (`../ide/src`): the folder
`alvie:/` (the files of the IDE, in IndexedDB), ALVIE terminals, the languages of the specs, their problems, and the
preview of models. See `docs/core/alvie-ide.md`.

    (cd ../ide && bash prepare.sh WEB_DIR SIM_DIR && npm ci)   # alvie-web and the simulators, as for the IDE
    npm ci && npm run build                                     # out/ and ide/
    bash test.sh                                                # the self-test, in VS Code for the Web
    bash build-workbench.sh /tmp/vscode-web                     # VS Code for the Web from Code - OSS (once)
    bash make-site.sh /tmp/vscode-web /tmp/alvie-vscode-site    # the static site
