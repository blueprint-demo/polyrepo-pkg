import type { FactsModule } from 'fact-kit'
import { describesOf } from '../../../_lib/describes.ts'

// No facts yet: the package exists so every unit has a place to put them.
const entry: FactsModule = {
  layer: 'implementation',
  describes: describesOf('polyrepo-sdk-py', 'packages/polyrepo-sdk-py'),
  publish: { target: 'pypi', name: 'polyrepo-sdk-py' },
  facts: [],
}

export default entry
