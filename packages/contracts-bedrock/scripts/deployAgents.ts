import fs from 'fs'
import path from 'path'
import { ethers } from 'hardhat'

const BOOTSTRAP_AGENT_ID = 1
const BOOTSTRAP_METADATA = 'ipfs://bootstrap-agent.json'
const BOOTSTRAP_SERVICE_URI = 'https://agents.nexis.dev/bootstrap'

async function deployProxy(
  contractName: string,
  initArgs: unknown[],
  signer: any
) {
  const implementationFactory = await ethers.getContractFactory(contractName, signer)
  const implementation = await implementationFactory.deploy()
  await implementation.waitForDeployment()

  const initData = implementationFactory.interface.encodeFunctionData('initialize', initArgs)
  const proxyFactory = await ethers.getContractFactory('ERC1967Proxy', signer)
  const proxy = await proxyFactory.deploy(await implementation.getAddress(), initData)
  await proxy.waitForDeployment()

  const instance = implementationFactory.attach(await proxy.getAddress())
  return { implementation, proxy, instance }
}

async function main() {
  const [deployer] = await ethers.getSigners()
  const admin = deployer.address

  console.log(`Deploying Nexis agent stack with admin ${admin}`)

  // Deploy Treasury (agents registry is set after Agents proxy deployed)
  const treasuryDeployment = await deployProxy('Treasury', [admin, admin], deployer)
  const treasury = treasuryDeployment.instance
  console.log(`Treasury deployed at ${await treasury.getAddress()}`)

  // Deploy Agents (requires treasury address)
  const agentsDeployment = await deployProxy('Agents', [admin, await treasury.getAddress()], deployer)
  const agents = agentsDeployment.instance
  console.log(`Agents deployed at ${await agents.getAddress()}`)

  // Wire Treasury -> Agents now that Agents exists
  const setAgentsTx = await treasury.setAgents(await agents.getAddress())
  await setAgentsTx.wait()

  const grantInflow = await treasury.grantRole(await treasury.INFLOW_ROLE(), await agents.getAddress())
  await grantInflow.wait()

  // Deploy Tasks marketplace
  const tasksDeployment = await deployProxy('Tasks', [admin, await agents.getAddress(), await treasury.getAddress()], deployer)
  const tasks = tasksDeployment.instance
  console.log(`Tasks deployed at ${await tasks.getAddress()}`)

  // Deploy Subscriptions manager
  const subscriptionsDeployment = await deployProxy('Subscriptions', [admin, await agents.getAddress()], deployer)
  const subscriptions = subscriptionsDeployment.instance
  console.log(`Subscriptions deployed at ${await subscriptions.getAddress()}`)

  // Cross module wiring
  const taskModuleRole = await agents.TASK_MODULE_ROLE()
  const slasherRole = await agents.SLASHER_ROLE()
  const verifierRole = await agents.VERIFIER_ROLE()

  const grantTaskModule = await agents.grantRole(taskModuleRole, await tasks.getAddress())
  await grantTaskModule.wait()
  const grantSlasher = await agents.grantRole(slasherRole, await tasks.getAddress())
  await grantSlasher.wait()
  const grantVerifier = await agents.grantRole(verifierRole, admin)
  await grantVerifier.wait()

  const setTasksTx2 = await agents.setTasksContract(await tasks.getAddress())
  await setTasksTx2.wait()

  const setPenalty = await agents.setEarlyExitPenalty(ethers.ZeroAddress, 500)
  await setPenalty.wait()

  // Bootstrap registration
  const registerTx = await agents.register(BOOTSTRAP_AGENT_ID, BOOTSTRAP_METADATA, BOOTSTRAP_SERVICE_URI)
  await registerTx.wait()

  // Manifest output
  const root = path.resolve(__dirname, '../../..')
  const stateDir = process.env.AGENTS_STATE_DIR
    ? path.resolve(root, process.env.AGENTS_STATE_DIR)
    : path.join(root, '.agents-devnet')
  fs.mkdirSync(stateDir, { recursive: true })

  const statePath = path.join(stateDir, 'agents-deployment.json')
  const network = await ethers.provider.getNetwork()
  const existing = fs.existsSync(statePath)
    ? JSON.parse(fs.readFileSync(statePath, 'utf8'))
    : {}

  const payload = {
    ...existing,
    chainId: Number(network.chainId),
    admin,
    treasury: await treasury.getAddress(),
    treasuryImplementation: await treasuryDeployment.implementation.getAddress(),
    agents: await agents.getAddress(),
    agentsImplementation: await agentsDeployment.implementation.getAddress(),
    tasks: await tasks.getAddress(),
    tasksImplementation: await tasksDeployment.implementation.getAddress(),
    subscriptions: await subscriptions.getAddress(),
    subscriptionsImplementation: await subscriptionsDeployment.implementation.getAddress(),
    bootstrapAgentId: BOOTSTRAP_AGENT_ID,
    updatedAt: new Date().toISOString(),
  }

  fs.writeFileSync(statePath, JSON.stringify(payload, null, 2))
  console.log(`Deployment manifest written to ${statePath}`)
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
