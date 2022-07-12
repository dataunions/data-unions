import debug from 'debug'
import { utils } from 'ethers'
import { authFetch } from '../../../src/authFetch'
import { ConfigTest } from '../../../src/ConfigTest'
import type { DataUnion} from '../../../src/DataUnion'
import { JoinRequestState } from '../../../src/DataUnion'
import { DataUnionClient } from '../../../src/DataUnionClient'
import { getEndpointUrl } from '../../../src/utils'
import { createMockAddress, expectInvalidAddress } from '../../test-utils/utils'
import { dataUnionAdminPrivateKey, getTestWallet, tokenAdminWallet } from '../devEnvironment'

const { parseEther } = utils

const log = debug('DataUnionClient::DataUnion::integration-test-member')

describe('DataUnion member', () => {

    let dataUnion: DataUnion
    let secret: string

    beforeAll(async () => {
        log('clientOptions: %O', ConfigTest)
        const adminClient = new DataUnionClient({
            ...ConfigTest,
            auth: {
                privateKey: dataUnionAdminPrivateKey
            }
        })
        dataUnion = await adminClient.deployDataUnion()

        // product is needed for join requests to analyze the DU version
        const createProductUrl = getEndpointUrl(ConfigTest.restUrl, 'products')
        await authFetch(
            createProductUrl,
            {
                method: 'POST',
                body: JSON.stringify({
                    beneficiaryAddress: dataUnion.getAddress(),
                    type: 'DATAUNION',
                    dataUnionVersion: 2
                }),
                // @ts-expect-error
                session: adminClient.session,
            }
        )
        secret = await dataUnion.createSecret()

        // TODO: this should be unnecessary after test wallets are properly set up in smart-contracts-init
        // send some ETH to a test wallet
        const memberWallet = getTestWallet(3)
        const sendTx = await tokenAdminWallet.sendTransaction({
            to: memberWallet.address,
            value: parseEther('1')
        })
        await sendTx.wait()

    }, 60000)

    async function getMemberDuObject(memberWallet: Wallet): Promise<DataUnion> {
        const memberClient = new DataUnionClient({
            ...ConfigTest,
            auth: {
                privateKey: memberWallet.privateKey,
            }
        } as any)
        return memberClient.getDataUnion(dataUnion.getAddress())
    }

    it('random user is not a member', async () => {
        const userAddress = createMockAddress()
        const isMember = await dataUnion.isMember(userAddress)
        expect(isMember).toBe(false)
    }, 60000)

    it('join with valid secret', async () => {
        const memberWallet = getTestWallet(4)
        const memberDu = await getMemberDuObject(memberWallet)
        await memberDu.join(secret)
        const isMember = await dataUnion.isMember(memberWallet.address)
        expect(isMember).toBe(true)
    }, 60000)

    it('part after joining', async () => {
        const memberWallet = getTestWallet(5)
        const memberDu = await getMemberDuObject(memberWallet)
        await memberDu.join(secret)

        const isMemberBefore = await dataUnion.isMember(memberWallet.address)
        await memberDu.part()
        const isMemberAfter = await dataUnion.isMember(memberWallet.address)

        expect(isMemberBefore).toBe(true)
        expect(isMemberAfter).toBe(false)
    }, 60000)

    it('join with invalid secret', async () => {
        const memberWallet = getTestWallet(6)
        const memberDu = await getMemberDuObject(memberWallet)
        return expect(() => memberDu.join('invalid-secret')).rejects.toThrow('Incorrect data union secret')
    }, 60000)

    it('join without secret', async () => {
        const memberWallet = getTestWallet(7)
        const memberDu = await getMemberDuObject(memberWallet)
        const response = await memberDu.join()
        expect(response.id).toBeDefined()
        expect(response.state).toBe(JoinRequestState.PENDING)
    }, 60000)

    it('admin add', async () => {
        const userAddress = createMockAddress()
        await dataUnion.addMembers([userAddress])
        const isMember = await dataUnion.isMember(userAddress)
        expect(isMember).toBe(true)
    }, 60000)

    it('admin remove', async () => {
        const userAddress = createMockAddress()
        await dataUnion.addMembers([userAddress])
        await dataUnion.removeMembers([userAddress])
        const isMember = await dataUnion.isMember(userAddress)
        expect(isMember).toBe(false)
    }, 60000)

    it('invalid address', async () => {
        return Promise.all([
            expectInvalidAddress(() => dataUnion.addMembers(['invalid-address'])),
            expectInvalidAddress(() => dataUnion.removeMembers(['invalid-address'])),
            expectInvalidAddress(() => dataUnion.isMember('invalid-address'))
        ])
    })
})
