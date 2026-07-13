import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://unive-alvie.github.io',
  base: '/alvie',
  integrations: [
    starlight({
      title: 'ALVIE',
      description: 'Automated analysis of Sancus using active automata learning.',
      customCss: ['./src/styles/custom.css'],
      sidebar: [
        { label: 'Getting Started', slug: 'getting-started' },
        {
          label: 'Guides',
          items: [
            { label: 'Reproducing the Simulation Experiments', slug: 'walkthrough-repro' },
            { label: 'TestDL Tutorial: Fast V-B1', slug: 'testdl-tutorial-vb1' },
            { label: 'TestDL Language Reference', slug: 'spec-tutorial' },
            { label: 'TestDL Action Reference', slug: 'testdl-action-reference' },
            { label: 'Extending TestDL Actions', slug: 'spec-extending-actions' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Executables Reference', slug: 'executables-reference' },
            { label: 'Logs and Outputs Reference', slug: 'log-output-reference' },
            { label: 'Code Architecture', slug: 'code-architecture' },
          ],
        },
      ],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/unive-alvie/alvie' },
      ],
    }),
  ],
});
