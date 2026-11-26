// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank(address) external;
    function deal(address, uint256) external;
    function warp(uint256) external;
}

import "../contracts/TNS.sol";

contract MockUSDT {
    mapping(address => uint256) public balanceOf;

    constructor() {
        balanceOf[msg.sender] = 1000 * 10**6;
    }

    // Non-standard ERC20: Does not return bool!
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "low balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract RevertingWallet {
    fallback() external payable {
        revert("Revert on receive");
    }
}

contract TNSTest {
    Vm constant vm = Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));
    TrendsNSolutions public tns;

    address public owner = address(0x1111);
    address public user1 = address(0x2222);
    address public user2 = address(0x3333);

    function setUp() public {
        vm.prank(owner);
        tns = new TrendsNSolutions();
    }

    function test_InitialState() public view {
        assert(tns.totalSupply() == 10_000_000_000 * 10**18);
        assert(tns.balanceOf(owner) == 10_000_000_000 * 10**18);
        assert(tns.owner() == owner);
        assert(tns.centralCapitalReserves() == owner);
        assert(tns.buyTax() == 100);
        assert(tns.sellTax() == 100);
        assert(tns.limitsInEffect() == true);
    }

    function test_TwoStepOwnershipWithFullSync() public {
        vm.prank(owner);
        tns.transferOwnership(user1);

        assert(tns.owner() == owner);
        assert(tns.pendingOwner() == user1);

        vm.prank(user1);
        tns.acceptOwnership();

        // Verify full synchronization (N-8 fix)
        assert(tns.owner() == user1);
        assert(tns.pendingOwner() == address(0));
        assert(tns.centralCapitalReserves() == user1);

        // Verify old owner lost exemptions and new owner gained exemptions
        assert(tns.isExcludedFromFees(owner) == false);
        assert(tns.isExcludedFromFees(user1) == true);
        assert(tns.isExcludedFromLimits(user1) == true);

        // Verify treasuryWallets[0] moved to new owner
        (address payable[] memory wallets, ) = tns.getTreasuryWallets();
        assert(wallets[0] == payable(user1));
    }

    function test_PendingTreasuryLiabilityProtectionAndAccountingView() public {
        address payable walletA = payable(address(0x100));
        address payable walletB = payable(address(0x200));

        address payable[] memory wallets = new address payable[](2);
        wallets[0] = walletA;
        wallets[1] = walletB;

        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 50;
        percentages[1] = 50;

        vm.prank(owner);
        tns.setTreasuryWallets(wallets, percentages);

        vm.deal(address(tns), 10 ether);

        vm.prank(owner);
        tns.distributeVaultETH();

        // Pure pull-based distribution: 100% of liabilities tracked in pending ledger
        assert(tns.totalPendingTreasuryETH() == 10 ether);
        assert(tns.pendingTreasuryETH(walletA) == 5 ether);
        assert(tns.pendingTreasuryETH(walletB) == 5 ether);

        // Verify public accounting view
        (uint256 contractBal, uint256 pending, uint256 available) = tns.getTreasuryAccounting();
        assert(contractBal == 10 ether);
        assert(pending == 10 ether);
        assert(available == 0);

        // Owner withdrawal of reserved funds must revert
        vm.prank(owner);
        try tns.withdrawContractETH(payable(owner), 1 ether) {
            revert("Should have reverted reserved withdraw");
        } catch {}

        // Wallet A claims their 5 ETH
        vm.prank(walletA);
        tns.claimTreasuryETH();

        assert(walletA.balance == 5 ether);
        assert(tns.totalPendingTreasuryETH() == 5 ether);
        assert(tns.pendingTreasuryETH(walletA) == 0);
    }

    function test_ClaimTreasuryETHToAlternativeAddress() public {
        address payable walletA = payable(address(0x100));

        address payable[] memory wallets = new address payable[](1);
        wallets[0] = walletA;

        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 100;

        vm.prank(owner);
        tns.setTreasuryWallets(wallets, percentages);

        vm.deal(address(tns), 2 ether);

        vm.prank(owner);
        tns.distributeVaultETH();

        assert(tns.pendingTreasuryETH(walletA) == 2 ether);

        // Claim to alternative cold storage address (N-21 fix)
        address payable coldStorage = payable(address(0x9999));
        vm.prank(walletA);
        tns.claimTreasuryETHTo(coldStorage);

        assert(coldStorage.balance == 2 ether);
        assert(tns.totalPendingTreasuryETH() == 0);
        assert(tns.pendingTreasuryETH(walletA) == 0);
    }

    function test_DuplicateTreasuryWalletRejected() public {
        address payable[] memory wallets = new address payable[](2);
        wallets[0] = payable(address(0x100));
        wallets[1] = payable(address(0x100));

        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 50;
        percentages[1] = 50;

        vm.prank(owner);
        try tns.setTreasuryWallets(wallets, percentages) {
            revert("Duplicate should have reverted");
        } catch {}
    }

    function test_DirectTransferToContractProhibited() public {
        vm.prank(owner);
        try tns.transfer(address(tns), 1000 * 10**18) {
            revert("Should have failed direct deposit");
        } catch {}
    }

    function test_ZeroTransferAllowed() public {
        vm.prank(owner);
        bool success = tns.transfer(user1, 0);
        assert(success);
        assert(tns.balanceOf(user1) == 0);
    }

    function test_InfiniteAllowanceOptimization() public {
        vm.prank(owner);
        tns.transfer(user1, 1_000 * 10**18);

        vm.prank(user1);
        tns.approve(user2, type(uint256).max);

        vm.prank(user2);
        tns.transferFrom(user1, user2, 500 * 10**18);

        assert(tns.allowance(user1, user2) == type(uint256).max);
        assert(tns.balanceOf(user2) == 500 * 10**18);
    }

    function test_SafeERC20ForeignTokenRecovery() public {
        MockUSDT usdt = new MockUSDT();
        usdt.transfer(address(tns), 500 * 10**6);

        assert(usdt.balanceOf(address(tns)) == 500 * 10**6);

        vm.prank(owner);
        tns.recoverForeignToken(address(usdt), owner, 500 * 10**6);

        assert(usdt.balanceOf(owner) == 500 * 10**6);
        assert(usdt.balanceOf(address(tns)) == 0);
    }

    function test_TimelockTaxGovernance() public {
        vm.prank(owner);
        tns.queueTaxUpdate(50, 50);

        (uint256 newBuy, uint256 newSell, uint256 readyAt, bool queued) = tns.queuedTaxUpdate();
        assert(newBuy == 50);
        assert(newSell == 50);
        assert(queued == true);

        vm.warp(readyAt + 1);

        vm.prank(owner);
        tns.executeTaxUpdate();

        assert(tns.buyTax() == 50);
        assert(tns.sellTax() == 50);
    }

    function test_TreasuryExemptionRevocationOnUpdate() public {
        address payable[] memory wallets = new address payable[](2);
        wallets[0] = payable(address(0x100));
        wallets[1] = payable(address(0x200));

        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 50;
        percentages[1] = 50;

        vm.prank(owner);
        tns.setTreasuryWallets(wallets, percentages);

        assert(tns.isExcludedFromFees(address(0x100)) == true);
        assert(tns.isExcludedFromFees(address(0x200)) == true);

        address payable[] memory newWallets = new address payable[](1);
        newWallets[0] = payable(address(0x300));

        uint256[] memory newPercentages = new uint256[](1);
        newPercentages[0] = 100;

        vm.prank(owner);
        tns.setTreasuryWallets(newWallets, newPercentages);

        assert(tns.isExcludedFromFees(address(0x100)) == false);
        assert(tns.isExcludedFromFees(address(0x200)) == false);
        assert(tns.isExcludedFromFees(address(0x300)) == true);
    }

    function test_RemoveLimits() public {
        vm.prank(owner);
        tns.removeLimits();
        assert(tns.limitsInEffect() == false);
    }
}
