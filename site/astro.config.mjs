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
        {
          label: 'Guides',
          items: [
            { label: 'Getting started', slug: 'getting-started' },
            { label: 'Reproducing the experiments', slug: 'walkthrough-repro' },
            { label: 'TestDL tutorial', slug: 'spec-tutorial' },
            { label: 'TestDL actions', slug: 'testdl-action-reference' },
            { label: 'Extending TestDL', slug: 'spec-extending-actions' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Executables', slug: 'executables-reference' },
            { label: 'Logs and outputs', slug: 'log-output-reference' },
            { label: 'Code architecture', slug: 'code-architecture' },
          ],
        },
      ],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/unive-alvie/alvie' },
      ],
    }),
  ],
});
