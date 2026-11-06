import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { existsSync } from 'node:fs';

// The pages that moved when the documentation was reorganized by reader (after 2026.10): their old addresses
// lead to the new ones. Astro adds the base to the old address, not to the new one
const base = process.env.ALVIE_DOCS_BASE || '/alvie';
const moved = Object.fromEntries(Object.entries({
    '/guides/concepts/': '/core/concepts/',
    '/guides/tiny-tutorial/': '/core/tiny-tutorial/',
    '/guides/learning-settings/': '/core/learning-settings/',
    '/guides/interpreting-results/': '/core/interpreting-results/',
    '/guides/plugin-author-guide/': '/plugin-authors/plugin-author-guide/',
    '/reference/plugin-files/': '/plugin-authors/plugin-files/',
    '/reference/protocol/': '/plugin-authors/protocol/',
    '/guides/walkthrough-repro/': '/sancus/walkthrough-repro/',
    '/guides/writing-specifications/': '/sancus/writing-specifications/',
    '/guides/testdl-tutorial-vb1/': '/sancus/testdl-tutorial-vb1/',
    '/guides/spec-extending-actions/': '/sancus/spec-extending-actions/',
    '/reference/attack-catalogue/': '/sancus/attack-catalogue/',
    '/reference/testdl-specification-reference/': '/sancus/testdl-specification-reference/',
    '/reference/testdl-action-reference/': '/sancus/testdl-action-reference/',
    '/reference/log-output-reference/': '/sancus/log-output-reference/',
    '/guides/testing-alvie/': '/development/testing-alvie/',
    '/reference/code-architecture/': '/development/code-architecture/',
})
  // the documentation of an earlier version (scripts/build-versions.sh) still has its pages there: no redirect then
  .filter(([from]) => !existsSync(`./src/content/docs${from.replace(/\/$/, '')}.md`))
  .map(([from, to]) => [from, base + to]));

// The documentation by reader (after 2026.10); the documentation of an earlier version keeps its own layout
const sidebar = existsSync('./src/content/docs/core')
  ? [
      { label: 'Getting Started', slug: 'getting-started' },
      { label: 'ALVIE/Core', items: [{ autogenerate: { directory: 'core' } }] },
      { label: 'ALVIE/Sancus', items: [{ autogenerate: { directory: 'sancus' } }] },
      { label: 'Writing Plugins', items: [{ autogenerate: { directory: 'plugin-authors' } }] },
      { label: 'Reference', items: [{ autogenerate: { directory: 'reference' } }] },
      { label: 'Developing ALVIE', collapsed: true, items: [{ autogenerate: { directory: 'development' } }] },
    ]
  : [
      { label: 'Getting Started', slug: 'getting-started' },
      { label: 'Guides', items: [{ autogenerate: { directory: 'guides' } }] },
      { label: 'Reference', items: [{ autogenerate: { directory: 'reference' } }] },
    ];

// scripts/build-versions.sh builds the site once per documentation version, each under its own base
export default defineConfig({
  site: 'https://unive-alvie.github.io',
  base,
  outDir: process.env.ALVIE_DOCS_OUTDIR || './dist',
  redirects: moved,
  integrations: [
    starlight({
      title: 'ALVIE',
      description: 'Find information leaks by learning models of a system and comparing them: ALVIE/Core and its plugins, ALVIE/Sancus among them.',
      customCss: ['./src/styles/custom.css'],
      components: {
        PageTitle: './src/components/PageTitle.astro',
        Sidebar: './src/components/Sidebar.astro',
        // Shows which version of the documentation is being read
        Banner: './src/components/VersionBanner.astro',
      },
      sidebar,
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/unive-alvie/alvie' },
      ],
    }),
  ],
});
