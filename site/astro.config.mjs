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
        { label: 'Guides', items: [{ autogenerate: { directory: 'guides' } }] },
        { label: 'Reference', items: [{ autogenerate: { directory: 'reference' } }] },
      ],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/unive-alvie/alvie' },
      ],
    }),
  ],
});
