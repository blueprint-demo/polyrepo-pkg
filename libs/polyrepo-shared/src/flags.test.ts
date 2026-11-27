import assert from 'node:assert/strict'
import { afterEach, test } from 'node:test'
import { InMemoryProvider, OpenFeature, type Provider } from '@openfeature/server-sdk'
import { initFlags, newGreetingEnabled, type FlagsConfig } from './flags.ts'

const KEY = 'polyrepo-shared-new-greeting'
const config: FlagsConfig = { appId: 'app-id-of-the-environment', accountId: 'account-id', authToken: 'token-of-the-product' }

// the provider of OpenFeature that keeps its values in memory: the flag is on or off by its default variant, or is not defined at all
const memory = (defaultVariant?: 'on' | 'off'): Provider =>
  new InMemoryProvider(defaultVariant ? { [KEY]: { disabled: false, variants: { on: 'on', off: 'off' }, defaultVariant } } : {})

afterEach(() => OpenFeature.clearProviders())

test('the value of the flag decides the result: on gives true, off gives false, and the provider is built from the config of the unit', async () => {
  let seen: FlagsConfig | undefined
  assert.equal(await initFlags(config, { createProvider: (c) => ((seen = c), memory('on')) }), true)
  assert.deepEqual(seen, config)
  assert.equal(await newGreetingEnabled(), true)
  assert.equal(await initFlags(config, { createProvider: () => memory('off') }), true)
  assert.equal(await newGreetingEnabled(), false)
})

test('a flag the service does not have gives the default in the code, which is the conservative one (false)', async () => {
  await initFlags(config, { createProvider: () => memory() })
  assert.equal(await newGreetingEnabled(), false)
})

test('no provider set up yet gives the default', async () => {
  assert.equal(await newGreetingEnabled(), false)
})

test('a provider that does not become ready within the limit does not hold the start: initFlags ends false, and the flag gives the default', async () => {
  const slow: Provider = { metadata: { name: 'slow' }, runsOn: 'server', hooks: [], initialize: () => new Promise(() => {}) } as unknown as Provider
  const started = Date.now()
  assert.equal(await initFlags(config, { createProvider: () => slow, timeoutMs: 50 }), false)
  assert.ok(Date.now() - started < 1000, 'the start did not wait without a limit')
  assert.equal(await newGreetingEnabled(), false)
})

test('a provider that fails to start ends false and leaves the default', async () => {
  const broken: Provider = { metadata: { name: 'broken' }, runsOn: 'server', hooks: [], initialize: () => Promise.reject(new Error('service down')) } as unknown as Provider
  assert.equal(await initFlags(config, { createProvider: () => broken }), false)
  assert.equal(await newGreetingEnabled(), false)
})
