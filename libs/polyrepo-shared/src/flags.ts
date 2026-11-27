import { OpenFeature, type Provider } from '@openfeature/server-sdk'
import { FlagshipServerProvider } from '@cloudflare/flagship/server'

// For a program that does not run in a Worker. It reads a flag only through OpenFeature (blueprint-shared.flags.interface), and the provider is set
// up in this one place. The flag service is reached with its HTTP evaluation endpoint, so the program needs three values of config: the app id and the
// account id, which the deploy flow fills in from the output of the iac step of the environment (the same source as the app_id of a Worker), and the
// evaluation token, which the product declares as a secret.

export interface FlagsConfig {
  appId: string
  accountId: string
  authToken: string
}

type CreateProvider = (config: FlagsConfig) => Provider
const flagshipProvider: CreateProvider = (config) => new FlagshipServerProvider({ appId: config.appId, accountId: config.accountId, authToken: config.authToken })

/**
 * Sets up the provider and waits for it, but not without a limit (blueprint-shared.flags.defaults). Resolves true when the provider is ready,
 * false when it failed or was not ready within `timeoutMs`: the program starts anyway, and a flag it cannot read gives its default.
 */
export async function initFlags(config: FlagsConfig, options: { createProvider?: CreateProvider; timeoutMs?: number } = {}): Promise<boolean> {
  const { createProvider = flagshipProvider, timeoutMs = 2000 } = options
  let timer: ReturnType<typeof setTimeout> | undefined
  const limit = new Promise<false>((resolve) => { timer = setTimeout(() => resolve(false), timeoutMs) })
  const ready = OpenFeature.setProviderAndWait(createProvider(config)).then(() => true as const, (error: unknown) => {
    console.error('flag provider did not start', error)
    return false as const
  })
  try {
    return await Promise.race([ready, limit])
  } finally {
    clearTimeout(timer)
  }
}

/**
 * `polyrepo-shared-new-greeting` (blueprint-shared.flags.key-naming). A flag declared with OpenTofu is a string flag (blueprint-shared.flags-flagship.iac),
 * so it is read as a string and its variations are "on" and "off". The default is "off", the safe value: the old greeting.
 */
export async function newGreetingEnabled(): Promise<boolean> {
  const details = await OpenFeature.getClient().getStringDetails('polyrepo-shared-new-greeting', 'off')
  if (details.reason === 'ERROR') console.error('flag evaluation failed', details.flagKey, details.errorCode)
  return details.value === 'on'
}
