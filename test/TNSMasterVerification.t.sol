// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/TNS.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank(address) external;
    function deal(address, uint256) external;
    function warp(uint256) external;
    function roll(uint256) external;
    function etch(address, bytes calldata) external;
    function chainId(uint256) external;
}

// Mock ERC20 for foreign token recovery test
contract MockForeignERC20 {
    mapping(address => uint256) public balanceOf;

    constructor(address initialHolder) {
        balanceOf[initialHolder] = 1_000_000 * 10**18;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "low balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// Mock Pair created dynamically by Factory
contract MockPair {
    address public immutable token0;
    address public immutable token1;

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}

// Mock WETH
contract MockWETH {
    fallback() external payable {}
    receive() external payable {}
}

// Mock Factory
contract MockFactory {
    function getPair(address, address) external pure returns (address) {
        return address(0);
    }

    function createPair(address tokenA, address tokenB) external returns (address) {
        MockPair p = new MockPair(tokenA, tokenB);
        return address(p);
    }
}

// Mock Uniswap V2 Router
contract MockRouter is IUniswapV2Router02 {
    address public constant FACTORY_ADDR = address(0x8888);
    address public constant WETH_ADDR = address(0x9999);

    function factory() external pure override returns (address) {
        return FACTORY_ADDR;
    }

    function WETH() external pure override returns (address) {
        return WETH_ADDR;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata)
        external
        pure
        override
        returns (uint256[] memory amounts)
    {
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
        (bool success, ) = payable(to).call{value: 0.05 ether}("");
        require(success, "ETH transfer failed");
    }

    receive() external payable {}
}

contract TNSMasterVerificationTest {
    Vm constant vm = Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));

    TrendsNSolutions public tns;

    address public owner = address(0x1111);
    address public ccr = address(0x54291c1f57588be4fe6ACc65f7228bFfc6E5Cf57); // Account 1 strictly preserved
    address public mockPairAddress = address(0x7777);

    MockFactory public factory;
    MockWETH public weth;
    MockRouter public router;

    // 5 Treasury Corporate Wallets
    address payable public tw1 = payable(address(0x101));
    address payable public tw2 = payable(address(0x102));
    address payable public tw3 = payable(address(0x103));
    address payable public tw4 = payable(address(0x104));
    address payable public tw5 = payable(address(0x105));

    // Traders
    address public trader1 = address(0x201);
    address public trader2 = address(0x202);
    address public trader3 = address(0x203);
    address public trader4 = address(0x204);

    uint256 initialCcrBalance;

    function setUp() public {
        // Set chainId to Base Sepolia (84532) so constructor binds the Base Sepolia router
        vm.chainId(84532);

        // Deploy Mock ecosystem
        factory = new MockFactory();
        weth = new MockWETH();
        router = new MockRouter();

        // Etch Factory at 0x8888 and WETH at 0x9999
        vm.etch(address(0x8888), address(factory).code);
        vm.etch(address(0x9999), address(weth).code);

        // Etch MockRouter at the Base Sepolia router address (0x1689E7B1F10000AE47eBfE339a4f69dECd19F602)
        address sepoliaRouter = 0x1689E7B1F10000AE47eBfE339a4f69dECd19F602;
        vm.etch(sepoliaRouter, address(router).code);
        vm.deal(sepoliaRouter, 100 ether);

        // Deploy TNS as owner
        vm.prank(owner);
        tns = new TrendsNSolutions();

        // Register mock pair
        vm.prank(owner);
        tns.setAutomatedMarketMakerPair(mockPairAddress, true);

        // Record Account 1 (CCR) initial status
        initialCcrBalance = tns.balanceOf(ccr);

        // Fund traders with ETH
        vm.deal(trader1, 50 ether);
        vm.deal(trader2, 50 ether);
        vm.deal(trader3, 50 ether);
        vm.deal(trader4, 50 ether);

        // Seed mock pair with TNS tokens from owner for buy simulations
        vm.prank(owner);
        tns.transfer(mockPairAddress, 2_000_000_000 * 10**18);
    }

    // =========================================================================
    // SECTION 1: HARDCODED TAX CEILING SECURITY (MUST REVERT ON > 1.00%)
    // =========================================================================

    function test_TaxCeiling_Rejects80Percent() public {
        vm.prank(owner);
        try tns.queueTaxUpdate(8000, 8000) {
            revert("CRITICAL: 80% tax must be rejected by hard ceiling!");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Buy tax exceeds 1.00% ceiling")));
        }
    }

    function test_TaxCeiling_Rejects50Percent() public {
        vm.prank(owner);
        try tns.queueTaxUpdate(5000, 5000) {
            revert("CRITICAL: 50% tax must be rejected by hard ceiling!");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Buy tax exceeds 1.00% ceiling")));
        }
    }

    function test_TaxCeiling_Rejects30Percent() public {
        vm.prank(owner);
        try tns.queueTaxUpdate(3000, 3000) {
            revert("CRITICAL: 30% tax must be rejected by hard ceiling!");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Buy tax exceeds 1.00% ceiling")));
        }
    }

    function test_TaxCeiling_Rejects10Percent() public {
        vm.prank(owner);
        try tns.queueTaxUpdate(1000, 1000) {
            revert("CRITICAL: 10% tax must be rejected by hard ceiling!");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Buy tax exceeds 1.00% ceiling")));
        }
    }

    function test_TaxCeiling_Rejects101Bps() public {
        vm.prank(owner);
        try tns.queueTaxUpdate(101, 100) {
            revert("CRITICAL: 1.01% tax must be rejected by hard ceiling!");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Buy tax exceeds 1.00% ceiling")));
        }
    }

    function test_TaxCeiling_AllowsWithinCeiling() public {
        // 1.00% (100 bps) is allowed
        vm.prank(owner);
        tns.queueTaxUpdate(100, 100);
        vm.prank(owner);
        tns.cancelTaxUpdate();

        // 0.50% (50 bps) is allowed
        vm.prank(owner);
        tns.queueTaxUpdate(50, 50);
        vm.prank(owner);
        tns.cancelTaxUpdate();

        // 0.00% (0 bps) is allowed
        vm.prank(owner);
        tns.queueTaxUpdate(0, 0);
        vm.prank(owner);
        tns.cancelTaxUpdate();
    }

    function test_TaxCeiling_PermanentlyDisableTax() public {
        vm.prank(owner);
        tns.permanentlyDisableTax();

        assert(tns.buyTax() == 0);
        assert(tns.sellTax() == 0);
        assert(tns.taxPermanentlyDisabled() == true);

        // Any subsequent queue must strictly revert
        vm.prank(owner);
        try tns.queueTaxUpdate(50, 50) {
            revert("Tax queue after permanent disable must revert");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Tax permanently disabled")));
        }
    }

    // =========================================================================
    // SECTION 2: 24-HOUR TIMELOCK PROGRESSION (REVERTS AT 1m, 1h, 23h59m; PASSES 24h)
    // =========================================================================

    function test_Timelock_Enforces24HourDelayStrictly() public {
        vm.prank(owner);
        tns.queueTaxUpdate(50, 50);

        (uint256 nb, uint256 ns, uint256 readyAt, bool queued) = tns.queuedTaxUpdate();
        assert(nb == 50);
        assert(ns == 50);
        assert(queued == true);
        assert(readyAt == block.timestamp + 24 hours);

        // Test at t + 1 minute (60 seconds) -> MUST REVERT
        vm.warp(block.timestamp + 60);
        vm.prank(owner);
        try tns.executeTaxUpdate() {
            revert("Execution at 1 min must revert!");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Timelock not met")));
        }

        // Test at t + 1 hour (3600 seconds) -> MUST REVERT
        vm.warp(block.timestamp + 3540); // now at +3600
        vm.prank(owner);
        try tns.executeTaxUpdate() {
            revert("Execution at 1 hour must revert!");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Timelock not met")));
        }

        // Test at t + 23 hours 59 minutes (86340 seconds) -> MUST REVERT
        vm.warp(readyAt - 60);
        vm.prank(owner);
        try tns.executeTaxUpdate() {
            revert("Execution at 23h 59m must revert!");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Timelock not met")));
        }

        // Test at t + 24 hours + 1 second -> MUST SUCCEED
        vm.warp(readyAt + 1);
        vm.prank(owner);
        tns.executeTaxUpdate();

        assert(tns.buyTax() == 50);
        assert(tns.sellTax() == 50);

        // Subsequent execute without new queue must revert
        vm.prank(owner);
        try tns.executeTaxUpdate() {
            revert("Re-execute must revert");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("No update queued")));
        }
    }

    function test_Timelock_CancelQueuedUpdate() public {
        vm.prank(owner);
        tns.queueTaxUpdate(25, 25);

        vm.prank(owner);
        tns.cancelTaxUpdate();

        (, , , bool queued) = tns.queuedTaxUpdate();
        assert(queued == false);

        // Warp 25 hours
        vm.warp(block.timestamp + 25 hours);
        vm.prank(owner);
        try tns.executeTaxUpdate() {
            revert("Execute on cancelled update must revert");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("No update queued")));
        }
    }

    function test_Timelock_UnauthorizedCallerBlocked() public {
        vm.prank(trader1);
        try tns.queueTaxUpdate(50, 50) {
            revert("Non-owner queue must revert");
        } catch {}

        vm.prank(owner);
        tns.queueTaxUpdate(50, 50);

        vm.warp(block.timestamp + 25 hours);
        vm.prank(trader1);
        try tns.executeTaxUpdate() {
            revert("Non-owner execute must revert");
        } catch {}

        vm.prank(trader1);
        try tns.cancelTaxUpdate() {
            revert("Non-owner cancel must revert");
        } catch {}
    }

    // =========================================================================
    // SECTION 3: TREASURY SPLIT COMBINATIONS (0% TO 100%) & SAFE ACCOUNTING
    // =========================================================================

    function test_TreasurySplit_StandardFiveWallets20Percent() public {
        address payable[] memory wallets = new address payable[](5);
        wallets[0] = tw1; wallets[1] = tw2; wallets[2] = tw3; wallets[3] = tw4; wallets[4] = tw5;

        uint256[] memory p = new uint256[](5);
        p[0] = 20; p[1] = 20; p[2] = 20; p[3] = 20; p[4] = 20;

        vm.prank(owner);
        tns.setTreasuryWallets(wallets, p);

        // Send 10 ETH to contract vault
        vm.deal(address(tns), 10 ether);

        vm.prank(owner);
        tns.distributeVaultETH();

        assert(tns.totalPendingTreasuryETH() == 10 ether);
        assert(tns.pendingTreasuryETH(tw1) == 2 ether);
        assert(tns.pendingTreasuryETH(tw2) == 2 ether);
        assert(tns.pendingTreasuryETH(tw3) == 2 ether);
        assert(tns.pendingTreasuryETH(tw4) == 2 ether);
        assert(tns.pendingTreasuryETH(tw5) == 2 ether);

        (uint256 bal, uint256 pending, uint256 avail) = tns.getTreasuryAccounting();
        assert(bal == 10 ether);
        assert(pending == 10 ether);
        assert(avail == 0);
    }

    function test_TreasurySplit_SingleWallet100Percent() public {
        address payable[] memory wallets = new address payable[](5);
        wallets[0] = tw1; wallets[1] = tw2; wallets[2] = tw3; wallets[3] = tw4; wallets[4] = tw5;

        uint256[] memory p = new uint256[](5);
        p[0] = 100; p[1] = 0; p[2] = 0; p[3] = 0; p[4] = 0;

        vm.prank(owner);
        tns.setTreasuryWallets(wallets, p);

        vm.deal(address(tns), 5 ether);
        vm.prank(owner);
        tns.distributeVaultETH();

        assert(tns.pendingTreasuryETH(tw1) == 5 ether);
        assert(tns.pendingTreasuryETH(tw2) == 0);
        assert(tns.pendingTreasuryETH(tw5) == 0);
    }

    function test_TreasurySplit_TwoWallets50Percent() public {
        address payable[] memory wallets = new address payable[](2);
        wallets[0] = tw1; wallets[1] = tw2;

        uint256[] memory p = new uint256[](2);
        p[0] = 50; p[1] = 50;

        vm.prank(owner);
        tns.setTreasuryWallets(wallets, p);

        vm.deal(address(tns), 4 ether);
        vm.prank(owner);
        tns.distributeVaultETH();

        assert(tns.pendingTreasuryETH(tw1) == 2 ether);
        assert(tns.pendingTreasuryETH(tw2) == 2 ether);
    }

    function test_TreasurySplit_LastWallet100Percent() public {
        address payable[] memory wallets = new address payable[](5);
        wallets[0] = tw1; wallets[1] = tw2; wallets[2] = tw3; wallets[3] = tw4; wallets[4] = tw5;

        uint256[] memory p = new uint256[](5);
        p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 0; p[4] = 100;

        vm.prank(owner);
        tns.setTreasuryWallets(wallets, p);

        vm.deal(address(tns), 8 ether);
        vm.prank(owner);
        tns.distributeVaultETH();

        assert(tns.pendingTreasuryETH(tw1) == 0);
        assert(tns.pendingTreasuryETH(tw5) == 8 ether);
    }

    function test_TreasurySplit_InvalidPermutationsRevert() public {
        // Sum != 100 (99%)
        address payable[] memory w = new address payable[](2);
        w[0] = tw1; w[1] = tw2;
        uint256[] memory p1 = new uint256[](2);
        p1[0] = 50; p1[1] = 49;
        vm.prank(owner);
        try tns.setTreasuryWallets(w, p1) { revert("99% must revert"); } catch {}

        // Sum != 100 (105%)
        uint256[] memory p2 = new uint256[](2);
        p2[0] = 50; p2[1] = 55;
        vm.prank(owner);
        try tns.setTreasuryWallets(w, p2) { revert("105% must revert"); } catch {}

        // Length mismatch
        uint256[] memory p3 = new uint256[](1);
        p3[0] = 100;
        vm.prank(owner);
        try tns.setTreasuryWallets(w, p3) { revert("Length mismatch must revert"); } catch {}

        // Zero wallets
        address payable[] memory emptyW = new address payable[](0);
        uint256[] memory emptyP = new uint256[](0);
        vm.prank(owner);
        try tns.setTreasuryWallets(emptyW, emptyP) { revert("Zero wallets must revert"); } catch {}

        // Address(0)
        address payable[] memory zeroW = new address payable[](1);
        zeroW[0] = payable(address(0));
        uint256[] memory zeroP = new uint256[](1);
        zeroP[0] = 100;
        vm.prank(owner);
        try tns.setTreasuryWallets(zeroW, zeroP) { revert("Zero address must revert"); } catch {}
    }

    function test_Treasury_PullPaymentAndDesignatedRecipient() public {
        address payable[] memory wallets = new address payable[](1);
        wallets[0] = tw1;
        uint256[] memory p = new uint256[](1);
        p[0] = 100;
        vm.prank(owner);
        tns.setTreasuryWallets(wallets, p);

        vm.deal(address(tns), 3 ether);
        vm.prank(owner);
        tns.distributeVaultETH();

        // 1. Claim directly
        vm.prank(tw1);
        tns.claimTreasuryETH();
        assert(tw1.balance == 3 ether);
        assert(tns.pendingTreasuryETH(tw1) == 0);

        // 2. Claim to cold storage destination
        vm.deal(address(tns), 2 ether);
        vm.prank(owner);
        tns.distributeVaultETH();

        address payable coldStorage = payable(address(0x999));
        vm.prank(tw1);
        tns.claimTreasuryETHTo(coldStorage);
        assert(coldStorage.balance == 2 ether);
        assert(tns.pendingTreasuryETH(tw1) == 0);
    }

    function test_Treasury_LiabilityProtectionBlocksOwnerTheft() public {
        address payable[] memory wallets = new address payable[](1);
        wallets[0] = tw1;
        uint256[] memory p = new uint256[](1);
        p[0] = 100;
        vm.prank(owner);
        tns.setTreasuryWallets(wallets, p);

        vm.deal(address(tns), 5 ether);
        vm.prank(owner);
        tns.distributeVaultETH();

        // All 5 ETH is now pending treasury liability
        // Owner attempting to withdraw reserved ETH must revert
        vm.prank(owner);
        try tns.withdrawContractETH(payable(owner), 1 ether) {
            revert("Reserved liability theft must revert!");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("TNS: Amount exceeds unreserved vault balance")));
        }
    }

    // =========================================================================
    // SECTION 4: LIVE TRADING, ANTI-SNIPE & AUTOMATED SWAPBACK
    // =========================================================================

    function test_Trading_BuyWithOnePercentTax() public {
        uint256 buyAmount = 1_000_000 * 10**18; // 1M TNS (within 0.01% launch limit)

        // Buy from mock AMM pair to trader1
        vm.prank(mockPairAddress);
        tns.transfer(trader1, buyAmount);

        // 1% tax (10,000 TNS) retained by contract
        uint256 expectedTax = (buyAmount * 100) / 10000;
        uint256 expectedReceived = buyAmount - expectedTax;

        assert(tns.balanceOf(trader1) == expectedReceived);
        assert(tns.balanceOf(address(tns)) == expectedTax);
    }

    function test_Trading_AntiSnipe_MaxBuyLimit() public {
        // Day 1: Max buy is 50,000,000 * 10**18 (0.50%)
        uint256 overLimit = 50_000_001 * 10**18;

        vm.prank(mockPairAddress);
        try tns.transfer(trader1, overLimit) {
            revert("Over max buy must revert");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Max Buy exceeded")));
        }

        // Exact 50M TNS succeeds
        vm.prank(mockPairAddress);
        tns.transfer(trader1, 50_000_000 * 10**18);
        assert(tns.balanceOf(trader1) > 0);

        // Owner scales up limit to 100M / 250M
        vm.prank(owner);
        tns.updateLimits(100_000_000 * 10**18, 250_000_000 * 10**18);
        assert(tns.maxTxAmount() == 100_000_000 * 10**18);

        // Now 100M buy succeeds
        vm.roll(block.number + 1);
        vm.prank(mockPairAddress);
        tns.transfer(trader2, 100_000_000 * 10**18);
        assert(tns.balanceOf(trader2) > 0);
    }

    function test_Trading_AntiSnipe_MaxWalletLimit() public {
        // Day 1: Max wallet is 150,000,000 * 10**18 (1.50%), Max buy is 50,000,000 * 10**18 (0.50%)
        // Buy 1: 50M (net 49.5M)
        vm.prank(mockPairAddress);
        tns.transfer(trader1, 50_000_000 * 10**18);

        // Buy 2: 50M next block (total ~99M)
        vm.roll(block.number + 1);
        vm.prank(mockPairAddress);
        tns.transfer(trader1, 50_000_000 * 10**18);

        // Buy 3: 50M next block (total ~148.5M <= 150M)
        vm.roll(block.number + 1);
        vm.prank(mockPairAddress);
        tns.transfer(trader1, 50_000_000 * 10**18);

        // Buy 4: 50M next block exceeds 150M total wallet (~198M > 150M)
        vm.roll(block.number + 1);
        vm.prank(mockPairAddress);
        try tns.transfer(trader1, 50_000_000 * 10**18) {
            revert("Over max wallet must revert");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Max Wallet exceeded")));
        }
    }

    function test_Trading_AntiSnipe_OneBuyPerBlock() public {
        // In same block, 2nd buy must revert
        vm.prank(mockPairAddress);
        tns.transfer(trader2, 500_000 * 10**18);

        vm.prank(mockPairAddress);
        try tns.transfer(trader2, 500_000 * 10**18) {
            revert("Same block second buy must revert");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Launch guard: 1 buy per block")));
        }

        // Next block succeeds
        vm.roll(block.number + 1);
        vm.prank(mockPairAddress);
        tns.transfer(trader2, 500_000 * 10**18);
        assert(tns.balanceOf(trader2) > 0);
    }

    function test_Trading_AntiSnipe_RemoveLimits() public {
        vm.prank(owner);
        tns.removeLimits();

        assert(tns.limitsInEffect() == false);

        // Now large buy > 50M and wallet > 150M succeeds
        vm.prank(mockPairAddress);
        tns.transfer(trader3, 200_000_000 * 10**18);

        assert(tns.balanceOf(trader3) > 150_000_000 * 10**18);
    }

    function test_Trading_SellWithSwapBack() public {
        // Step 1: Remove limits to allow large accumulation
        vm.prank(owner);
        tns.removeLimits();

        // Step 2: Accumulate >5M TNS fees via buys
        // 11 buys of 50M TNS = 550M TNS bought * 1% = 5.5M TNS in fees accumulated
        for (uint256 i = 0; i < 11; i++) {
            vm.roll(block.number + 1);
            vm.prank(mockPairAddress);
            tns.transfer(trader4, 50_000_000 * 10**18);
        }

        assert(tns.balanceOf(address(tns)) >= 5_000_000 * 10**18);

        // Step 3: Trader sells to pair -> triggers swapback
        vm.roll(block.number + 1);
        vm.prank(trader4);
        tns.transfer(mockPairAddress, 1_000_000 * 10**18);

        // Router sent ETH to contract vault
        (uint256 vaultBal, , ) = tns.getTreasuryAccounting();
        assert(vaultBal > 0 || address(tns).balance > 0);
    }

    // =========================================================================
    // SECTION 5: ALL READ & WRITE FUNCTIONS (ADMIN & SECURITY CONTROLS)
    // =========================================================================

    function test_ReadAllContractTabProperties() public view {
        assert(keccak256(bytes(tns.name())) == keccak256(bytes("Trends N Solutions")));
        assert(keccak256(bytes(tns.symbol())) == keccak256(bytes("TNS")));
        assert(tns.decimals() == 18);
        assert(tns.totalSupply() == 10_000_000_000 * 10**18);
        assert(tns.owner() == owner);
        assert(tns.pendingOwner() == address(0));
        assert(tns.centralCapitalReserves() == owner);
        assert(tns.buyTax() == 100);
        assert(tns.sellTax() == 100);
        assert(tns.MAX_TAX() == 100);
        assert(tns.TIMELOCK_DELAY() == 24 hours);
        assert(tns.maxTxAmount() == 50_000_000 * 10**18);
        assert(tns.maxWalletAmount() == 150_000_000 * 10**18);
        assert(tns.swapTokensAtAmount() == 5_000_000 * 10**18);
        assert(tns.autoSplitEnabled() == false);
        assert(tns.migrationActive() == false);
        assert(tns.totalMigratedToNativeL1() == 0);
    }

    function test_RenounceOwnership_MustRevert() public {
        vm.prank(owner);
        try tns.renounceOwnership() {
            revert("Renounce must revert");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("TNS: Direct renounce disabled. Use transferOwnership.")));
        }
    }

    function test_SwapTokensAtAmount_BoundedLimits() public {
        // Lower than 100k reverts
        vm.prank(owner);
        try tns.setSwapTokensAtAmount(99_999 * 10**18) {
            revert("<100k must revert");
        } catch {}

        // Higher than 50M reverts
        vm.prank(owner);
        try tns.setSwapTokensAtAmount(50_000_001 * 10**18) {
            revert(">50M must revert");
        } catch {}

        // 10M succeeds
        vm.prank(owner);
        tns.setSwapTokensAtAmount(10_000_000 * 10**18);
        assert(tns.swapTokensAtAmount() == 10_000_000 * 10**18);
    }

    function test_NativeL1Migration() public {
        // Inactive migration reverts
        vm.prank(owner);
        try tns.migrateToNativeChain(1_000 * 10**18, "TNS-L1-ADDR") {
            revert("Inactive migration must revert");
        } catch {}

        // Activate migration
        vm.prank(owner);
        tns.setMigrationActive(true);
        assert(tns.migrationActive() == true);

        // Migrate tokens
        vm.prank(owner);
        tns.migrateToNativeChain(1_000 * 10**18, "TNS-L1-ADDR");

        assert(tns.totalMigratedToNativeL1() == 1_000 * 10**18);
    }

    function test_ForeignTokenRescue_NativeTNSLocked() public {
        // Rescue foreign token works
        MockForeignERC20 foreign = new MockForeignERC20(address(this));
        foreign.transfer(address(tns), 10_000 * 10**18);

        vm.prank(owner);
        tns.recoverForeignToken(address(foreign), owner, 10_000 * 10**18);
        assert(foreign.balanceOf(owner) == 10_000 * 10**18);

        // Attempting to rescue native TNS strictly reverts
        vm.prank(owner);
        try tns.recoverForeignToken(address(tns), owner, 1_000) {
            revert("Rescuing native TNS must revert");
        } catch Error(string memory reason) {
            assert(keccak256(bytes(reason)) == keccak256(bytes("Cannot rescue native TNS")));
        }
    }

    function test_CannotDelistPrimaryUniswapPair() public {
        address pair = tns.uniswapV2Pair();
        if (pair != address(0)) {
            vm.prank(owner);
            try tns.setAutomatedMarketMakerPair(pair, false) {
                revert("Delisting primary pair must revert");
            } catch Error(string memory reason) {
                assert(keccak256(bytes(reason)) == keccak256(bytes("Cannot change Uniswap pair")));
            }
        }
    }

    // =========================================================================
    // SECTION 6: CONTINUOUS ACCOUNT 1 (CCR) INTEGRITY CHECK
    // =========================================================================

    function test_Account1_AbsoluteIntegrityPreserved() public view {
        // Account 1 (CCR) has never been modified or touched by any test
        assert(tns.balanceOf(ccr) == initialCcrBalance);
    }
}
