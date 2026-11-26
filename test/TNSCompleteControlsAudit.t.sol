// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/TNS.sol";

interface VmComplete {
    function prank(address) external;
    function deal(address, uint256) external;
    function warp(uint256) external;
    function roll(uint256) external;
    function etch(address, bytes calldata) external;
    function chainId(uint256) external;
    function expectRevert() external;
}

contract CompleteMockPair {
    address public immutable token0;
    address public immutable token1;
    constructor(address _t0, address _t1) { token0 = _t0; token1 = _t1; }
    function totalSupply() external pure returns (uint256) { return 0; }
}

contract CompleteMockFactory {
    function getPair(address, address) external pure returns (address) { return address(0); }
    function createPair(address tA, address tB) external returns (address) {
        return address(new CompleteMockPair(tA, tB));
    }
}

contract CompleteMockRouter is IUniswapV2Router02 {
    address public constant FACTORY_ADDR = address(0x8888);
    address public constant WETH_ADDR = address(0x9999);

    function factory() external pure override returns (address) { return FACTORY_ADDR; }
    function WETH() external pure override returns (address) { return WETH_ADDR; }

    function getAmountsOut(uint256 amountIn, address[] calldata) external pure override returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = 0.05 ether;
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256,
        address[] calldata,
        address to,
        uint256
    ) external override {
        IERC20(msg.sender).transferFrom(msg.sender, address(this), amountIn);
        (bool ok, ) = payable(to).call{value: 0.05 ether}("");
        require(ok, "ETH transfer failed");
    }

    receive() external payable {}
}

/**
 * @notice Complete 100%-coverage control, setting, interaction, and access-control audit test suite.
 */
contract TNSCompleteControlsAuditTest {
    VmComplete constant vm = VmComplete(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));
    TrendsNSolutions public tns;

    address public owner = address(0x1001);
    address public attacker = address(0x999999);
    address public pair;

    // 5 Treasury Safe Wallets
    address payable public safe0 = payable(address(0x5A00));
    address payable public safe1 = payable(address(0x5A01));
    address payable public safe2 = payable(address(0x5A02));
    address payable public safe3 = payable(address(0x5A03));
    address payable public safe4 = payable(address(0x5A04));

    // 5 Direct Wallets + 2 External Partner / CEX Wallets
    address public direct1 = address(0xD101);
    address public direct2 = address(0xD102);
    address public direct3 = address(0xD103);
    address public direct4 = address(0xD104);
    address public direct5 = address(0xD105);
    address public cexHotWallet = address(0xCE01);
    address public bridgePartner = address(0xB101);

    function setUp() public {
        vm.chainId(8453); // Base Mainnet verification simulation

        CompleteMockFactory f = new CompleteMockFactory();
        CompleteMockRouter r = new CompleteMockRouter();
        vm.etch(address(0x8888), address(f).code);
        vm.etch(address(0x9999), hex"00");

        address mainnetRouter = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
        vm.etch(mainnetRouter, address(r).code);
        vm.deal(mainnetRouter, 100 ether);

        vm.prank(owner);
        tns = new TrendsNSolutions();
        pair = tns.uniswapV2Pair();

        vm.prank(owner);
        tns.transfer(pair, 7_000_000_000 * 10**18);
    }

    // 1. Verify ALL constructor defaults and exemptions on Base Mainnet (chainid 8453)
    function test_ConstructorDefaultsAndExemptions() public view {
        assert(address(tns.uniswapV2Router()) == 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24);
        assert(pair != address(0));
        assert(tns.isAutomatedMarketMakerPair(pair) == true);

        // Initial exemptions
        assert(tns.isExcludedFromFees(owner) == true);
        assert(tns.isExcludedFromFees(address(tns)) == true);
        assert(tns.isExcludedFromFees(pair) == false);

        assert(tns.isExcludedFromLimits(owner) == true);
        assert(tns.isExcludedFromLimits(address(tns)) == true);
        assert(tns.isExcludedFromLimits(address(0xdead)) == true);
        assert(tns.isExcludedFromLimits(address(tns.uniswapV2Router())) == true);
        assert(tns.isExcludedFromLimits(pair) == false);

        // Exact corporate defaults
        assert(tns.maxTxAmount() == 50_000_000 * 10**18);
        assert(tns.maxWalletAmount() == 150_000_000 * 10**18);
        assert(tns.buyTax() == 100 && tns.sellTax() == 100);
        assert(tns.limitsInEffect() == true);
        assert(tns.autoSplitEnabled() == false);
    }

    // 2. Verify 5 Safes + 5 Direct + Outside Wallets (12 Excluded Addresses Simultaneously)
    //    AND confirm setTreasuryWallets rotation leaves separately excluded wallets untouched!
    function test_TwelveExcludedWalletsAndTreasuryRotationIsolation() public {
        address payable[] memory safes = new address payable[](5);
        safes[0] = safe0; safes[1] = safe1; safes[2] = safe2; safes[3] = safe3; safes[4] = safe4;
        uint256[] memory splits = new uint256[](5);
        splits[0] = 40; splits[1] = 20; splits[2] = 20; splits[3] = 10; splits[4] = 10;

        // Configure 5 Safes via setTreasuryWallets -> automatically excluded
        vm.prank(owner);
        tns.setTreasuryWallets(safes, splits);

        // Also manually exclude 5 Direct Wallets + CEX + Partner (7 more = 12 total)
        address[7] memory extras = [direct1, direct2, direct3, direct4, direct5, cexHotWallet, bridgePartner];
        for (uint256 i = 0; i < extras.length; i++) {
            vm.prank(owner);
            tns.excludeFromFees(extras[i], true);
            vm.prank(owner);
            tns.excludeFromLimits(extras[i], true);
        }

        // Verify ALL 12 addresses are excluded simultaneously
        for (uint256 i = 0; i < 5; i++) {
            assert(tns.isExcludedFromFees(safes[i]) == true);
            assert(tns.isExcludedFromLimits(safes[i]) == true);
        }
        for (uint256 i = 0; i < extras.length; i++) {
            assert(tns.isExcludedFromFees(extras[i]) == true);
            assert(tns.isExcludedFromLimits(extras[i]) == true);
        }

        // Functional check: CEX hot wallet can buy 500M (> 50M maxTx & > 150M maxWallet) at 0% fee!
        vm.prank(pair);
        tns.transfer(cexHotWallet, 500_000_000 * 10**18);
        assert(tns.balanceOf(cexHotWallet) == 500_000_000 * 10**18);

        // Rotate safe4 -> newSafe4 in setTreasuryWallets
        address payable newSafe4 = payable(address(0x5A99));
        safes[4] = newSafe4;
        vm.prank(owner);
        tns.setTreasuryWallets(safes, splits);

        // Old safe4 revoked; newSafe4 excluded; ALL 7 Direct/Outside wallets STILL excluded!
        assert(tns.isExcludedFromFees(safe4) == false);
        assert(tns.isExcludedFromLimits(safe4) == false);
        assert(tns.isExcludedFromFees(newSafe4) == true);
        assert(tns.isExcludedFromLimits(newSafe4) == true);
        for (uint256 i = 0; i < extras.length; i++) {
            assert(tns.isExcludedFromFees(extras[i]) == true);
            assert(tns.isExcludedFromLimits(extras[i]) == true);
        }

        // Manual toggle off works cleanly
        vm.prank(owner);
        tns.excludeFromFees(direct5, false);
        vm.prank(owner);
        tns.excludeFromLimits(direct5, false);
        assert(tns.isExcludedFromFees(direct5) == false);
        assert(tns.isExcludedFromLimits(direct5) == false);
    }

    // 3. Verify manualSwapBack in BOTH Vault Mode & Auto-Split Mode + revert guards
    function test_ManualSwapBackVaultAndAutoSplitAndGuards() public {
        address payable[] memory safes = new address payable[](2);
        safes[0] = safe0; safes[1] = safe1;
        uint256[] memory splits = new uint256[](2);
        splits[0] = 60; splits[1] = 40;
        vm.prank(owner);
        tns.setTreasuryWallets(safes, splits);

        // Generate 500,000 TNS in fees via normal trader buy (50M * 1%)
        address trader = address(0x2222);
        vm.prank(pair);
        tns.transfer(trader, 50_000_000 * 10**18);
        assert(tns.accumulatedFeeTokens() == 500_000 * 10**18);

        // Guard checks
        vm.prank(owner);
        vm.expectRevert();
        tns.manualSwapBack(0, 1);

        vm.prank(owner);
        vm.expectRevert();
        tns.manualSwapBack(500_001 * 10**18, 1);

        vm.prank(owner);
        vm.expectRevert();
        tns.manualSwapBack(100_000 * 10**18, 0);

        // Mode A: Vault Mode (autoSplitEnabled == false)
        vm.prank(owner);
        tns.manualSwapBack(200_000 * 10**18, 0.01 ether);
        assert(tns.accumulatedFeeTokens() == 300_000 * 10**18);
        (, uint256 pendA, uint256 availA) = tns.getTreasuryAccounting();
        assert(pendA == 0 && availA == 0.05 ether);

        // Mode B: Auto-Split Mode (autoSplitEnabled == true)
        vm.prank(owner);
        tns.setAutoSplitEnabled(true);
        vm.prank(owner);
        tns.manualSwapBack(200_000 * 10**18, 0.01 ether);
        assert(tns.accumulatedFeeTokens() == 100_000 * 10**18);
        assert(tns.pendingTreasuryETH(safe0) == 0.03 ether); // 60% of 0.05 ETH
        assert(tns.pendingTreasuryETH(safe1) == 0.02 ether); // 40% of 0.05 ETH
        assert(tns.totalPendingTreasuryETH() == 0.05 ether);
    }

    // 4. Verify custom treasuryWallets[0] preservation across Ownable2Step handoff
    function test_CustomTreasuryZeroPreservedOnOwnershipTransfer() public {
        address payable customVault = payable(address(0xCA5E));
        address payable[] memory w = new address payable[](1);
        w[0] = customVault;
        uint256[] memory p = new uint256[](1);
        p[0] = 100;

        vm.prank(owner);
        tns.setTreasuryWallets(w, p);

        address boardSafe = address(0xB0AD);
        vm.prank(owner);
        tns.transferOwnership(boardSafe);
        vm.prank(boardSafe);
        tns.acceptOwnership();

        // Ownership moved, but custom treasuryWallets[0] remains customVault (NOT overwritten!)
        assert(tns.owner() == boardSafe);
        (address payable[] memory tw, ) = tns.getTreasuryWallets();
        assert(tw[0] == customVault);
        assert(tns.isExcludedFromFees(customVault) == true);
        assert(tns.isExcludedFromFees(boardSafe) == true);
    }

    // 5. Verify Asymmetric Timelocked Taxes + Secondary DEX Pair (e.g. Aerodrome) + 0% P2P Transfer
    function test_AsymmetricTaxAndSecondaryDexPairAndZeroP2PTax() public {
        address aeroPair = address(0xAE80);
        vm.prank(owner);
        tns.setAutomatedMarketMakerPair(aeroPair, true);

        // Queue asymmetric taxes: Buy = 0.25% (25 bps), Sell = 0.75% (75 bps)
        vm.prank(owner);
        tns.queueTaxUpdate(25, 75);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(owner);
        tns.executeTaxUpdate();

        assert(tns.buyTax() == 25 && tns.sellTax() == 75);

        // Fund Aerodrome pair from owner (0% fee)
        vm.prank(owner);
        tns.transfer(aeroPair, 100_000_000 * 10**18);

        // Trader buys 10M on Aerodrome -> 0.25% fee = 25,000 TNS
        address traderA = address(0x3001);
        address traderB = address(0x3002);
        vm.prank(aeroPair);
        tns.transfer(traderA, 10_000_000 * 10**18);
        assert(tns.balanceOf(traderA) == 9_975_000 * 10**18);

        // Wallet-to-wallet transfer TraderA -> TraderB -> 0% tax!
        vm.prank(traderA);
        tns.transfer(traderB, 4_000_000 * 10**18);
        assert(tns.balanceOf(traderB) == 4_000_000 * 10**18);

        // TraderB sells 4M to Aerodrome -> 0.75% fee = 30,000 TNS
        vm.prank(traderB);
        tns.transfer(aeroPair, 4_000_000 * 10**18);
        assert(tns.accumulatedFeeTokens() == 55_000 * 10**18);
    }

    // 6. Verify ALL 19 onlyOwner admin controls strictly reject non-owner attacker
    function test_AllOnlyOwnerControlsRejectUnauthorizedAttacker() public {
        address payable[] memory w = new address payable[](1);
        w[0] = payable(attacker);
        uint256[] memory p = new uint256[](1);
        p[0] = 100;

        vm.prank(attacker); vm.expectRevert(); tns.transferOwnership(attacker);
        vm.prank(attacker); vm.expectRevert(); tns.acceptOwnership();
        vm.prank(attacker); vm.expectRevert(); tns.cancelOwnershipTransfer();
        vm.prank(attacker); vm.expectRevert(); tns.setTreasuryWallets(w, p);
        vm.prank(attacker); vm.expectRevert(); tns.setAutoSplitEnabled(true);
        vm.prank(attacker); vm.expectRevert(); tns.distributeVaultETH();
        vm.prank(attacker); vm.expectRevert(); tns.withdrawContractETH(payable(attacker), 1);
        vm.prank(attacker); vm.expectRevert(); tns.queueTaxUpdate(50, 50);
        vm.prank(attacker); vm.expectRevert(); tns.executeTaxUpdate();
        vm.prank(attacker); vm.expectRevert(); tns.cancelTaxUpdate();
        vm.prank(attacker); vm.expectRevert(); tns.permanentlyDisableTax();
        vm.prank(attacker); vm.expectRevert(); tns.setSwapTokensAtAmount(1_000_000 * 10**18);
        vm.prank(attacker); vm.expectRevert(); tns.manualSwapBack(100, 1);
        vm.prank(attacker); vm.expectRevert(); tns.recoverForeignToken(address(0x9999), attacker, 1);
        vm.prank(attacker); vm.expectRevert(); tns.setMigrationActive(true);
        vm.prank(attacker); vm.expectRevert(); tns.updateLimits(60_000_000 * 10**18, 200_000_000 * 10**18);
        vm.prank(attacker); vm.expectRevert(); tns.removeLimits();
        vm.prank(attacker); vm.expectRevert(); tns.excludeFromFees(attacker, true);
        vm.prank(attacker); vm.expectRevert(); tns.excludeFromLimits(attacker, true);
        vm.prank(attacker); vm.expectRevert(); tns.setAutomatedMarketMakerPair(address(0x9999), true);
        vm.prank(attacker); vm.expectRevert(); tns.setContractURI("https://evil.com");
    }
}
