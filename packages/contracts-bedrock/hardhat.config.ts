import { HardhatUserConfig, subtask } from 'hardhat/config'
import '@nomiclabs/hardhat-ethers'
import {
  TASK_COMPILE_GET_REMAPPINGS,
  TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS,
} from 'hardhat/builtin-tasks/task-names'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'

const EXCLUDED_SOURCE_DIRS = [
  'contracts/forge-std',
  'contracts/openzeppelin-contracts',
  'contracts/openzeppelin-contracts-upgradeable',
  'contracts/safe-contracts',
  'contracts/solady',
  'contracts/solmate',
]

subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS, async (args, _, runSuper) => {
  const sourcePaths: string[] = await runSuper(args)
  const excludedRoots = EXCLUDED_SOURCE_DIRS.map((dir) =>
    path.resolve(__dirname, dir)
  )

  return sourcePaths.filter((filePath) => {
    const absolutePath = path.resolve(filePath)
    return !excludedRoots.some((root) =>
      absolutePath === root || absolutePath.startsWith(`${root}${path.sep}`)
    )
  })
})

subtask(TASK_COMPILE_GET_REMAPPINGS, async (_, __, runSuper) => {
  const base = await runSuper<Record<string, string>>()
  const remappingsFile = path.join(__dirname, 'remappings.txt')

  if (!existsSync(remappingsFile)) {
    return base
  }

  const extraEntries = readFileSync(remappingsFile, 'utf8')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith('//'))
    .map((line) => {
      const separatorIndex = line.indexOf('=')
      if (separatorIndex === -1) {
        return ['', ''] as const
      }

      const prefix = line.slice(0, separatorIndex).trim()
      const target = line.slice(separatorIndex + 1).trim()
      return [prefix, target] as const
    })
    .filter((entry): entry is readonly [string, string] => Boolean(entry[0] && entry[1]))

  if (extraEntries.length === 0) {
    return base
  }

  const extra: Record<string, string> = {}
  for (const [prefix, target] of extraEntries) {
    extra[prefix] = target
  }

  return {
    ...base,
    ...extra,
  }
})

const mnemonic =
  process.env.AGENTS_L3_MNEMONIC ??
  'test test test test test test test test test test test junk'

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.20',
    settings: {
      optimizer: {
        enabled: true,
        runs: 1_000_000,
      },
      viaIR: true,
    },
  },
  paths: {
    sources: './contracts',
    tests: './test/hardhat',
    cache: './hardhat-cache',
    artifacts: './hardhat-artifacts',
  },
  networks: {
    hardhat: {
      chainId: Number(process.env.AGENTS_L3_CHAIN_ID ?? 84532),
    },
    agentsL3: {
      url: process.env.AGENTS_L3_RPC_URL ?? 'http://127.0.0.1:9545',
      chainId: Number(process.env.AGENTS_L3_CHAIN_ID ?? 84532),
      accounts: {
        mnemonic,
      },
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_RPC_URL ?? 'https://sepolia.base.org',
      chainId: 84532,
      accounts: process.env.BASE_SEPOLIA_PRIVATE_KEY
        ? [process.env.BASE_SEPOLIA_PRIVATE_KEY]
        : [],
    },
  },
  mocha: {
    timeout: 120_000,
  },
}

export default config
