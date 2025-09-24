import { expect } from 'chai'
import { ethers } from 'hardhat'

async function deployProxy(contractName: string, args: unknown[], signer: any) {
  const implFactory = await ethers.getContractFactory(contractName, signer)
  const implementation = await implFactory.deploy()
  await implementation.waitForDeployment()
  const initData = implFactory.interface.encodeFunctionData('initialize', args)
  const proxyFactory = await ethers.getContractFactory('ERC1967Proxy', signer)
  const proxy = await proxyFactory.deploy(await implementation.getAddress(), initData)
  await proxy.waitForDeployment()
  const instance = implFactory.attach(await proxy.getAddress())
  return { implementation, proxy, instance }
}

describe('Nexis Agents stack', () => {
  async function deployStack() {
    const [admin] = await ethers.getSigners()

    const treasuryDeployment = await deployProxy('Treasury', [admin.address, admin.address], admin)
    const treasury = treasuryDeployment.instance

    const agentsDeployment = await deployProxy('Agents', [admin.address, await treasury.getAddress()], admin)
    const agents = agentsDeployment.instance

    await treasury.setAgents(await agents.getAddress())
    await treasury.grantRole(await treasury.INFLOW_ROLE(), await agents.getAddress())

    const tasksDeployment = await deployProxy('Tasks', [admin.address, await agents.getAddress(), await treasury.getAddress()], admin)
    const tasks = tasksDeployment.instance

    const subscriptionsDeployment = await deployProxy('Subscriptions', [admin.address, await agents.getAddress()], admin)
    const subscriptions = subscriptionsDeployment.instance

    await agents.setTasksContract(await tasks.getAddress())
    await agents.grantRole(await agents.TASK_MODULE_ROLE(), await tasks.getAddress())
    await agents.grantRole(await agents.SLASHER_ROLE(), await tasks.getAddress())
    await agents.grantRole(await agents.VERIFIER_ROLE(), admin.address)
    await agents.setEarlyExitPenalty(ethers.ZeroAddress, 500)

    return { agents, treasury, tasks, subscriptions, admin }
  }

  it('registers agents via proxy and exposes discovery metadata', async () => {
    const { agents } = await deployStack()
    await agents.register(1, 'ipfs://bootstrap.json', 'https://agents.nexis/bootstrap')

    const list = await agents.listAgents(0, 10)
    expect(list.length).to.equal(1)
    expect(list[0].agentId).to.equal(1n)
    expect(list[0].metadata).to.equal('ipfs://bootstrap.json')
    expect(list[0].serviceURI).to.equal('https://agents.nexis/bootstrap')
  })

  it('tracks staking balances and aggregated stats across assets', async () => {
    const { agents } = await deployStack()
    await agents.register(7, 'ipfs://7', 'https://agent/7')

    await agents.stakeETH(7, { value: ethers.parseEther('5') })

    const stats = await agents.aggregatedStats()
    expect(stats.totalAgents).to.equal(1n)
    expect(stats.assets.length).to.equal(1)
    expect(stats.assets[0]).to.equal(ethers.ZeroAddress)
    expect(stats.totalStakedPerAsset[0]).to.equal(ethers.parseEther('5'))
  })

  it('records inferences and verifier attestations', async () => {
    const { agents } = await deployStack()
    await agents.register(11, 'meta', 'service')

    const tx = await agents.recordInference(
      11,
      ethers.keccak256(ethers.toUtf8Bytes('input')),
      ethers.keccak256(ethers.toUtf8Bytes('output')),
      ethers.keccak256(ethers.toUtf8Bytes('model:v1')),
      0,
      'ipfs://proof'
    )
    const receipt = await tx.wait()
    const inferenceId = receipt!.logs
      .map((log) => {
        try {
          return agents.interface.parseLog(log)
        } catch (err) {
          return undefined
        }
      })
      .find((parsed) => parsed?.name === 'InferenceRecorded')?.args?.inferenceId

    expect(inferenceId, 'inferenceId').to.not.be.undefined

    const deltas = [{ dimension: ethers.keccak256(ethers.toUtf8Bytes('accuracy')), delta: 5, reason: 'verified' }]
    await agents.attestInference(inferenceId, true, 'ipfs://attestation', deltas)

    const [, attestation] = await agents.getInference(inferenceId)
    expect(attestation.success).to.equal(true)
  })
})
