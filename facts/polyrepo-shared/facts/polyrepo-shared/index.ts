import type { FactsModule } from 'fact-kit'
import { describesOf } from '../../../_lib/describes.ts'

// No facts yet: the package exists so every unit has a place to put them.
const entry: FactsModule = {
  layer: 'implementation',
  describes: describesOf('polyrepo-shared', 'libs/polyrepo-shared'),
  publish: { target: 'npm', name: '@blueprint-demo/polyrepo-shared' },
  facts: [],
}

export default entry
