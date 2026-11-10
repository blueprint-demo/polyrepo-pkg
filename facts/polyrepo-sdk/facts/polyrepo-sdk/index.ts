import type { FactsModule } from 'fact-kit'
import { describesOf } from '../../../_lib/describes.ts'

// No facts yet: the package exists so every unit has a place to put them.
const entry: FactsModule = {
  layer: 'implementation',
  describes: describesOf('polyrepo-sdk', 'packages/polyrepo-sdk'),
  publish: { target: 'npm', name: 'polyrepo-sdk' },
  facts: [],
}

export default entry
