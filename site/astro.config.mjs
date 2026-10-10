import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// scripts/build-versions.sh builds the site once per documentation version, each under its own base
export default defineConfig({
  site: 'https://unive-alvie.github.io',
  base: process.env.ALVIE_DOCS_BASE || '/alvie',
  outDir: process.env.ALVIE_DOCS_OUTDIR || './dist',
  integrations: [
    starlight({
      title: 'ALVIE',
      description: 'Automated analysis of Sancus using active automata learning.',
      customCss: ['./src/styles/custom.css'],
      components: {
        PageTitle: './src/components/PageTitle.astro',
        Sidebar: './src/components/Sidebar.astro',
        // Shows which version of the documentation is being read
        Banner: './src/components/VersionBanner.astro',
      },
      sidebar: [
        { label: 'Getting Started', slug: 'getting-started' },
        { label: 'Guides', items: [{ autogenerate: { directory: 'guides' } }] },
        { label: 'Reference', items: [{ autogenerate: { directory: 'reference' } }] },
      ],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/unive-alvie/alvie' },
      ],
    }),
  ],
});
