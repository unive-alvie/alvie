# ALVIE in the browser

A web extension of VS Code that runs ALVIE in the browser, and the static site around it: a first page with the
tutorials (notebooks of commands of ALVIE, `tutorials/*.alvienb`) and an empty session (VS Code with the folder
`alvie:/`, ALVIE terminals, the languages of the specs, their problems, and a preview of models). See
`docs/core/alvie-ide.md` (users) and `docs/development/alvie-in-the-browser.md` (developers).

    bash prepare.sh WEB_DIR SIM_DIR                             # alvie-web, the simulators, the files: bundle/
    npm ci && npm run build                                     # out/
    bash test.sh                                                # the self-test, in VS Code for the Web
    bash build-workbench.sh /tmp/vscode-web                     # VS Code for the Web from Code - OSS (once)
    bash make-site.sh /tmp/vscode-web /tmp/alvie-site           # the static site
    python3 serve.py /tmp/alvie-site 8766                       # serve it, compressed
