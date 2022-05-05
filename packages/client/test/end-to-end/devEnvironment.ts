import { Wallet } from 'ethers'
import { JsonRpcProvider } from '@ethersproject/providers'
import { id } from 'ethers/lib/utils'
import { ConfigTest } from '../../src/ConfigTest'

export const provider = new JsonRpcProvider(ConfigTest.network.rpcs[0])
// can mint mainnet DATA tokens
export const tokenAdminPrivateKey = '0x5e98cce00cff5dea6b454889f359a4ec06b9fa6b88e9d69b86de8e1c81887da0'
export const tokenAdminWallet = new Wallet(tokenAdminPrivateKey, provider)

export const dataUnionAdminPrivateKey = '0xe5af7834455b7239881b85be89d905d6881dcb4751063897f12be1b0dd546bdb'

afterAll(() => {
    provider.removeAllListeners()
})

export function getTestWallet(index: number, testProvider: JsonRpcProvider = provider) {
    // TODO: change to 'streamr-client-javascript' once https://github.com/streamr-dev/smart-contracts-init/pull/36 is in docker
    const hash = id(`marketplace-contracts${index}`)
    return new Wallet(hash, testProvider)
}
