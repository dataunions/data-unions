pragma solidity 0.6.6;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "./IERC677.sol";
import "./Ownable.sol"; // TODO: switch to "openzeppelin-solidity/contracts/access/Ownable.sol";
import "./ISidechainMigrationManager.sol";
import "./IERC20Receiver.sol";

contract DataUnionSidechain is Ownable, IERC20Receiver {
    using SafeMath for uint256;

    //used to describe members and join part agents
    enum ActiveStatus {NONE, ACTIVE, INACTIVE}

    //emitted by joins/parts
    event MemberJoined(address indexed member);
    event MemberParted(address indexed member);
    event JoinPartAgentAdded(address indexed agent);
    event JoinPartAgentRemoved(address indexed agent);

    //emitted when revenue received
    event RevenueReceived(uint256 amount);
    event NewEarnings(uint256 earningsPerMember, uint256 activeMemberCount);

    //emitted by withdrawal
    event EarningsWithdrawn(address indexed member, uint256 amount);

    //in-contract transfers
    event TransferWithinContract(address indexed from, address indexed to, uint amount);
    event TransferToAddressInContract(address indexed from, address indexed to, uint amount);

    //new member eth
    event UpdateNewMemberEth(uint value);
    event NewMemberEthSent(uint amountWei);

    //migrate token and mediator
    event MigrateToken(address indexed newToken, address indexed oldToken, uint amountMigrated);
    event MigrateMediator(address indexed newMediator, address indexed oldMediator);


    struct MemberInfo {
        ActiveStatus status;
        uint256 earningsBeforeLastJoin;
        uint256 lmeAtJoin;
        uint256 withdrawnEarnings;
    }

    IERC677 public token;
    address public tokenMediator;
    address public dataUnionMainnet;

    uint256 public totalEarnings;
    uint256 public totalEarningsWithdrawn;

    uint256 public activeMemberCount;
    uint256 public inactiveMemberCount;
    uint256 public lifetimeMemberEarnings;

    uint256 public joinPartAgentCount;

    uint256 public newMemberEth;

    ISidechainMigrationManager public migrationManager;

    mapping(address => MemberInfo) public memberData;
    mapping(address => ActiveStatus) public joinPartAgents;

    modifier onlyJoinPartAgent() {
        require(joinPartAgents[msg.sender] == ActiveStatus.ACTIVE, "error_onlyJoinPartAgent");
        _;
    }

    // owner will be set by initialize()
    constructor() public Ownable(address(0)) {}

    receive() external payable {}

    function initialize(
        address initialOwner,
        address _migrationManager,
        address[] memory initialJoinPartAgents,
        address mainnetDataUnionAddress,
        uint256 defaultNewMemberEth
    ) public {
        require(!isInitialized(), "error_alreadyInitialized");
        owner = msg.sender; // set real owner at the end. During initialize, addJoinPartAgents can be called by owner only
        migrationManager = ISidechainMigrationManager(_migrationManager);
        token = IERC677(migrationManager.currentToken());
        addJoinPartAgents(initialJoinPartAgents);
        tokenMediator = migrationManager.currentMediator();
        dataUnionMainnet = mainnetDataUnionAddress;
        setNewMemberEth(defaultNewMemberEth);
        owner = initialOwner;
    }

    function isInitialized() public view returns (bool){
        return address(token) != address(0);
    }

    /**
    ERC677 callback function
    see https://github.com/ethereum/EIPs/issues/677
    */
    function onTokenTransfer(address, uint256, bytes calldata) external returns (bool success) {
        if(msg.sender != address(token)){
            return false;
        }
        refreshRevenue();
        return true;
    }

    /*
        tokenbridge callback function
    */
    function onTokenBridged(address, uint256, bytes memory) override public {
        refreshRevenue();
    }


    /**
     * Atomic getter to get all state variables in one call
     * This alleviates the fact that JSON RPC batch requests aren't available in ethers.js
     */
    function getStats() public view returns (uint256[6] memory) {
        return [
            totalEarnings,
            totalEarningsWithdrawn,
            activeMemberCount,
            inactiveMemberCount,
            lifetimeMemberEarnings,
            joinPartAgentCount
        ];
    }

    function setNewMemberEth(uint val) public onlyOwner {
        if(val == newMemberEth) return;
        newMemberEth = val;
        emit UpdateNewMemberEth(val);
    }

    function getEarnings(address member) public view returns (uint256) {
        MemberInfo storage info = memberData[member];
        require(info.status != ActiveStatus.NONE, "error_notMember");
        return
            info.earningsBeforeLastJoin +
            (
                info.status == ActiveStatus.ACTIVE
                    ? lifetimeMemberEarnings.sub(info.lmeAtJoin)
                    : 0
            );
    }

    function getWithdrawn(address member) public view returns (uint256) {
        MemberInfo storage info = memberData[member];
        require(info.status != ActiveStatus.NONE, "error_notMember");
        return info.withdrawnEarnings;
    }

    function getWithdrawableEarnings(address member) public view returns (uint256) {
        return getEarnings(member).sub(getWithdrawn(member));
    }

    function totalWithdrawable() public view returns (uint256) {
        return totalEarnings.sub(totalEarningsWithdrawn);
    }

    function addJoinPartAgents(address[] memory agents) public onlyOwner {
        for (uint256 i = 0; i < agents.length; i++) {
            addJoinPartAgent(agents[i]);
        }
    }

    function addJoinPartAgent(address agent) public onlyOwner {
        require(joinPartAgents[agent] != ActiveStatus.ACTIVE, "error_alreadyActiveAgent");
        joinPartAgents[agent] = ActiveStatus.ACTIVE;
        emit JoinPartAgentAdded(agent);
        joinPartAgentCount = joinPartAgentCount.add(1);
    }

    function removeJoinPartAgent(address agent) public onlyOwner {
        require(joinPartAgents[agent] == ActiveStatus.ACTIVE, "error_notActiveAgent");
        joinPartAgents[agent] = ActiveStatus.INACTIVE;
        emit JoinPartAgentRemoved(agent);
        joinPartAgentCount = joinPartAgentCount.sub(1);
    }

    /**
     * Process unaccounted tokens that have been sent previously
     * Called by AMB (see DataUnionMainnet:sendTokensToBridge)
     */
    function refreshRevenue() public returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        uint256 revenue = balance.sub(totalWithdrawable()); // a.sub(b) errors if b > a
        if (revenue == 0 || activeMemberCount == 0) return 0;
        uint256 earningsPerMember = revenue.div(activeMemberCount);
        lifetimeMemberEarnings = lifetimeMemberEarnings.add(earningsPerMember);
        totalEarnings = totalEarnings.add(revenue);
        emit RevenueReceived(revenue);
        emit NewEarnings(earningsPerMember, activeMemberCount);
        return revenue;
    }

    function addMember(address payable member) public onlyJoinPartAgent {
        MemberInfo storage info = memberData[member];
        require(info.status != ActiveStatus.ACTIVE, "error_alreadyMember");
        if(info.status == ActiveStatus.INACTIVE){
            inactiveMemberCount = inactiveMemberCount.sub(1);
        }
        bool sendEth = info.status == ActiveStatus.NONE && newMemberEth != 0 && address(this).balance >= newMemberEth;
        info.status = ActiveStatus.ACTIVE;
        info.lmeAtJoin = lifetimeMemberEarnings;
        activeMemberCount = activeMemberCount.add(1);
        emit MemberJoined(member);

        // give new members ETH. continue even if transfer fails
        if (sendEth) {
            if (member.send(newMemberEth)) {
                NewMemberEthSent(newMemberEth);
            }
        }
    }

    function partMember(address member) public {
        require(msg.sender == member || joinPartAgents[msg.sender] == ActiveStatus.ACTIVE, "error_notPermitted");
        MemberInfo storage info = memberData[member];
        require(info.status == ActiveStatus.ACTIVE, "error_notActiveMember");
        info.earningsBeforeLastJoin = getEarnings(member);
        info.status = ActiveStatus.INACTIVE;
        activeMemberCount = activeMemberCount.sub(1);
        inactiveMemberCount = inactiveMemberCount.add(1);
        emit MemberParted(member);
    }

    function addMembers(address payable[] memory members) public onlyJoinPartAgent {
        for (uint256 i = 0; i < members.length; i++) {
            addMember(members[i]);
        }
    }

    //access checked in partMember
    function partMembers(address[] memory members) public {
        for (uint256 i = 0; i < members.length; i++) {
            partMember(members[i]);
        }
    }

    /**
     * Transfer tokens from outside contract, add to a recipient's in-contract balance
     */
    function transferToMemberInContract(address recipient, uint amount) public {
        uint balanceBefore = token.balanceOf(address(this));
        require(token.transferFrom(msg.sender, address(this), amount), "error_transfer");
        uint balanceAfter = token.balanceOf(address(this));
        require(balanceAfter.sub(balanceBefore) >= amount, "error_transfer");

        _increaseBalance(recipient, amount);
        totalEarnings = totalEarnings.add(amount);
        emit TransferToAddressInContract(msg.sender, recipient,  amount);
    }

    /**
     * Transfer tokens from sender's in-contract balance to recipient's in-contract balance
     * This is done by "withdrawing" sender's earnings and crediting them to recipient's unwithdrawn earnings,
     *   so withdrawnEarnings never decreases for anyone (within this function)
     * @param recipient whose withdrawable earnings will increase
     * @param amount how much withdrawable earnings is transferred
     */
    function transferWithinContract(address recipient, uint amount) public {
        require(getWithdrawableEarnings(msg.sender) >= amount, "error_insufficientBalance");    // reverts with "error_notMember" msg.sender not member
        MemberInfo storage info = memberData[msg.sender];
        info.withdrawnEarnings = info.withdrawnEarnings.add(amount);
        _increaseBalance(recipient, amount);
        emit TransferWithinContract(msg.sender, recipient, amount);
    }

    /**
     * Hack to add to single member's balance without affecting lmeAtJoin
     */
    function _increaseBalance(address member, uint amount) internal {
        MemberInfo storage info = memberData[member];
        info.earningsBeforeLastJoin = info.earningsBeforeLastJoin.add(amount);

        // allow seeing and withdrawing earnings
        if (info.status == ActiveStatus.NONE) {
            info.status = ActiveStatus.INACTIVE;
            inactiveMemberCount = inactiveMemberCount.add(1);
        }
    }

    function withdrawMembers(address[] memory members, bool sendToMainnet)
        public
        returns (uint256)
    {
        uint256 withdrawn = 0;
        for (uint256 i = 0; i < members.length; i++) {
            withdrawn = withdrawn.add(withdrawAll(members[i], sendToMainnet));
        }
        return withdrawn;
    }

    function withdrawAll(address member, bool sendToMainnet)
        public
        returns (uint256)
    {
        return withdraw(member, getWithdrawableEarnings(member), sendToMainnet);
    }

    function withdraw(address member, uint amount, bool sendToMainnet)
        public
        returns (uint256)
    {
        require(msg.sender == member || msg.sender == owner, "error_notPermitted");
        return _withdraw(member, member, amount, sendToMainnet);
    }

    function withdrawAllTo(address to, bool sendToMainnet)
        public
        returns (uint256)
    {
        return withdrawTo(to, getWithdrawableEarnings(msg.sender), sendToMainnet);
    }

    function withdrawTo(address to, uint amount, bool sendToMainnet)
        public
        returns (uint256)
    {
        return _withdraw(msg.sender, to, amount, sendToMainnet);
    }

    /**
     * Check signature from a member authorizing withdrawing its earnings to another account.
     * Throws if the signature is badly formatted or doesn't match the given signer and amount.
     * Signature has parts the act as replay protection:
     * 1) `address(this)`: signature can't be used for other contracts;
     * 2) `withdrawn[signer]`: signature only works once (for unspecified amount), and can be "cancelled" by sending a withdraw tx.
     * Generated in Javascript with: `web3.eth.accounts.sign(recipientAddress + amount.toString(16, 64) + contractAddress.slice(2) + withdrawnTokens.toString(16, 64), signerPrivateKey)`,
     * or for unlimited amount: `web3.eth.accounts.sign(recipientAddress + "0".repeat(64) + contractAddress.slice(2) + withdrawnTokens.toString(16, 64), signerPrivateKey)`.
     * @param signer whose earnings are being withdrawn
     * @param recipient of the tokens
     * @param amount how much is authorized for withdraw, or zero for unlimited (withdrawAll)
     * @param signature byte array from `web3.eth.accounts.sign`
     * @return isValid true iff signer of the authorization (member whose earnings are going to be withdrawn) matches the signature
     */
    function signatureIsValid(
        address signer,
        address recipient,
        uint amount,
        bytes memory signature
    )
        public view
        returns (bool isValid)
    {
        require(signature.length == 65, "error_badSignatureLength");

        bytes32 r; bytes32 s; uint8 v;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) {
            v += 27;
        }
        require(v == 27 || v == 28, "error_badSignatureVersion");

        // When changing the message, remember to double-check that message length is correct!
        bytes32 messageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n104", recipient, amount, address(this), getWithdrawn(signer)));
        address calculatedSigner = ecrecover(messageHash, v, r, s);

        return calculatedSigner == signer;
    }

    /**
     * Do an "unlimited donate withdraw" on behalf of someone else, to an address they've specified.
     * Sponsored withdraw is paid by admin, but target account could be whatever the member specifies.
     * The signature gives a "blank cheque" for admin to withdraw all tokens to `recipient` in the future,
     *   and it's valid until next withdraw (and so can be nullified by withdrawing any amount).
     * A new signature needs to be obtained for each subsequent future withdraw.
     * @param fromSigner whose earnings are being withdrawn
     * @param to the address the tokens will be sent to (instead of `msg.sender`)
     * @param sendToMainnet if the tokens should be sent to mainnet or only withdrawn into sidechain address
     * @param signature from the member, see `signatureIsValid` how signature generated for unlimited amount
     */
    function withdrawAllToSigned(
        address fromSigner,
        address to,
        bool sendToMainnet,
        bytes memory signature
    )
        public
        returns (uint withdrawn)
    {
        require(signatureIsValid(fromSigner, to, 0, signature), "error_badSignature");
        return _withdraw(fromSigner, to, getWithdrawableEarnings(fromSigner), sendToMainnet);
    }

    /**
     * Do a "donate withdraw" on behalf of someone else, to an address they've specified.
     * Sponsored withdraw is paid by admin, but target account could be whatever the member specifies.
     * The signature is valid only for given amount of tokens that may be different from maximum withdrawable tokens.
     * @param fromSigner whose earnings are being withdrawn
     * @param to the address the tokens will be sent to (instead of `msg.sender`)
     * @param amount of tokens to withdraw
     * @param sendToMainnet if the tokens should be sent to mainnet or only withdrawn into sidechain address
     * @param signature from the member, see `signatureIsValid` how signature generated for unlimited amount
     */
    function withdrawToSigned(
        address fromSigner,
        address to,
        uint amount,
        bool sendToMainnet,
        bytes memory signature
    )
        public
        returns (uint withdrawn)
    {
        require(signatureIsValid(fromSigner, to, amount, signature), "error_badSignature");
        return _withdraw(fromSigner, to, amount, sendToMainnet);
    }

    function toBytes(address a) public pure returns (bytes memory b) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let m := mload(0x40)
            a := and(a, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            mstore(
                add(m, 20),
                xor(0x140000000000000000000000000000000000000000, a)
            )
            mstore(0x40, add(m, 52))
            b := m
        }
    }

    /**
     * Internal function common to all withdraw methods.
     * Does NOT check proper access, so all callers must do that first.
     */
    function _withdraw(address from, address to, uint amount, bool sendToMainnet)
        internal
        returns (uint256)
    {
        if (amount == 0) return 0;
        require(amount <= getWithdrawableEarnings(from), "error_insufficientBalance");
        MemberInfo storage info = memberData[from];
        info.withdrawnEarnings = info.withdrawnEarnings.add(amount);
        totalEarningsWithdrawn = totalEarningsWithdrawn.add(amount);
        if (sendToMainnet)
            require(
                token.transferAndCall(
                    tokenMediator,
                    amount,
                    toBytes(to)
                ),
                "error_transfer"
            );
        /*
            transferAndCall enables transfers to another tokenbridge. 
            in this case to = bridge, and the recipient on other chain is from
        */
        else require(token.transferAndCall(to, amount, toBytes(from)), "error_transfer");
        emit EarningsWithdrawn(from, amount);
        return amount;
    }

    function migrate() public onlyOwner {
        address newMediator = migrationManager.currentMediator();
        if(newMediator != address(0) && newMediator != address(tokenMediator)) {
            emit MigrateMediator(newMediator, address(tokenMediator));
            tokenMediator = newMediator;
        }
        IERC677 newToken = IERC677(migrationManager.currentToken());
        if(address(newToken) != address(0) && address(newToken) != address(token) &&
            migrationManager.oldToken() == address(token)) {
            refreshRevenue();
            uint oldBalance = token.balanceOf(address(this));
            uint newBalance = newToken.balanceOf(address(this));
            if(oldBalance != 0) {
                token.approve(address(migrationManager), oldBalance);
                migrationManager.swap(oldBalance);
                require(token.balanceOf(address(this)) == 0, "tokens_not_sent");
                //require at least oldBalance more new tokens
                require(newToken.balanceOf(address(this)).sub(newBalance) >= oldBalance, "tokens_not_received");
            }
            emit MigrateToken(address(newToken), address(token), oldBalance);
            token = newToken;
        }
    }
}
