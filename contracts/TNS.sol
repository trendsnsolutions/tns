// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Trends N Solutions ($TNS)
 * @notice Enterprise-grade ERC-20 smart contract on Base (Coinbase Layer-2).
 * Includes a fixed total supply of 10 Billion TNS, hardcoded 1.00% maximum tax ceiling,
 * 24-hour governance timelock for tax rate adjustments, universal dynamic treasury router
 * with pull-payment pending ledgers, two-step ownership management (Ownable2Step),
 * and EIP-2612 gasless permits.
 */

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address tokenOwner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IERC2612 {
    function permit(
        address tokenOwner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    function nonces(address tokenOwner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

/**
 * @notice Two-step ownership transfer mechanism based on OpenZeppelin Ownable2Step.
 * Guards against permanent loss of contract control due to address typos.
 */
abstract contract Ownable2Step is Context {
    address private _owner;
    address private _pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _transferOwnership(_msgSender());
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not owner");
        _;
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is zero address");
        require(newOwner != owner(), "Ownable: new owner is current owner");
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    function acceptOwnership() public virtual {
        require(pendingOwner() == _msgSender(), "Ownable2Step: caller is not pending owner");
        _transferOwnership(_msgSender());
    }

    function cancelOwnershipTransfer() public virtual onlyOwner {
        require(_pendingOwner != address(0), "Ownable2Step: no pending transfer");
        _pendingOwner = address(0);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        _pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() public view virtual onlyOwner {
        revert("TNS: Direct renounce disabled. Use transferOwnership.");
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract TrendsNSolutions is IERC20Metadata, IERC2612, Ownable2Step, ReentrancyGuard {
    string private constant _name = "Trends N Solutions";
    string private constant _symbol = "TNS";
    uint8 private constant _decimals = 18;

    // Fixed total supply of 10 Billion TNS (zero minting, zero burning)
    uint256 private constant _totalSupply = 10_000_000_000 * 10**18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ==========================================
    // EIP-2612 GASLESS PERMIT STATE
    // ==========================================
    mapping(address => uint256) private _nonces;
    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    // ==========================================
    // FEE STRUCTURE & HARDCODED SAFETY CEILING
    // ==========================================
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant MAX_TAX = 100; // Permanently hardcoded 1.00% ceiling (100 basis points)

    uint256 public buyTax = 100;  // 1.00% (100 basis points)
    uint256 public sellTax = 100; // 1.00% (100 basis points)

    // Dedicated accounting for trading fees to prevent collision with escrowed tokens
    uint256 public accumulatedFeeTokens;

    // Master switch to permanently renounce taxes
    bool public taxPermanentlyDisabled = false;
    event TaxPermanentlyDisabled();

    // ==========================================
    // 24-HOUR GOVERNANCE TIMELOCK CONTROLLER (TAX)
    // ==========================================
    uint256 public constant TIMELOCK_DELAY = 24 hours;

    struct QueuedTaxUpdate {
        uint256 newBuyTax;
        uint256 newSellTax;
        uint256 readyTimestamp;
        bool isQueued;
    }

    QueuedTaxUpdate public queuedTaxUpdate;

    event TaxUpdateQueued(uint256 newBuyTax, uint256 newSellTax, uint256 readyTimestamp);
    event TaxUpdateExecuted(uint256 newBuyTax, uint256 newSellTax);
    event TaxUpdateCancelled();

    // ==========================================
    // UNIVERSAL DYNAMIC TREASURY ROUTER (5 WALLETS)
    // ==========================================
    // treasuryWallets[0] ⟹ Central Capital Reserves (Supreme Owner & Master Operating Vault)
    // treasuryWallets[1] ⟹ Engineering Development
    // treasuryWallets[2] ⟹ Marketing & Expansion
    // treasuryWallets[3] ⟹ Assets & Capital
    // treasuryWallets[4] ⟹ Founder Equity

    bool public autoSplitEnabled = false;

    struct TreasuryWallet {
        address payable wallet;
        uint256 percentage;
    }

    TreasuryWallet[5] public treasuryWallets;
    uint256 public treasuryWalletCount = 0;

    // Pull-payment pending ledger protecting individual wallet allocations
    mapping(address => uint256) public pendingTreasuryETH;
    uint256 public totalPendingTreasuryETH;

    event AutoSplitToggled(bool enabled);
    event TreasuryWalletsConfigured(address payable[] wallets, uint256[] percentages);
    event TreasuryDistributionExecuted(uint256 tokensSwapped, uint256 totalETH, uint256 distributedETH);
    event TreasuryPaymentClaimed(address indexed wallet, address indexed recipient, uint256 amount);
    event VaultAccumulationRecorded(uint256 tokensSwapped, uint256 ethAmount, uint256 newVaultBalance);
    event VaultETHWithdrawn(address indexed recipient, uint256 amount);
    event VaultETHDistributed(uint256 totalETH, uint256 distributedETH);

    // ==========================================
    // SOVEREIGN L1 ESCROW HOOK
    // ==========================================
    bool public migrationActive = false;
    uint256 public totalMigratedToNativeL1 = 0;
    uint256 public migrationNonce = 0;

    event MigrationStateUpdated(bool active);
    event TokensMigratedToNativeL1(
        uint256 indexed migrationId,
        address indexed account,
        uint256 amount,
        string destinationAddress,
        uint256 timestamp
    );

    // ==========================================
    // ANTI-SNIPE LAUNCH GUARDS (REMOVABLE & EXPANDABLE)
    // ==========================================
    bool public limitsInEffect = true;
    uint256 public maxTxAmount = 50_000_000 * 10**18;     // 0.50% (50M TNS initial launch buy limit)
    uint256 public maxWalletAmount = 150_000_000 * 10**18; // 1.50% (150M TNS initial launch wallet limit)

    mapping(address => uint256) private _lastTxBlock;

    // ==========================================
    // AUTOMATED SWAPBACK SETTINGS
    // ==========================================
    uint256 public swapTokensAtAmount = 5_000_000 * 10**18; // 0.05% default trigger

    IUniswapV2Router02 public immutable uniswapV2Router;
    address public uniswapV2Pair;

    mapping(address => bool) public isExcludedFromFees;
    mapping(address => bool) public isExcludedFromLimits;
    mapping(address => bool) private _automatedMarketMakerPairs;

    bool private _inSwap = false;

    modifier lockTheSwap() {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    event LimitsRemoved();
    event LimitsUpdated(uint256 newMaxTx, uint256 newMaxWallet);
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeFromLimits(address indexed account, bool isExcluded);
    event SwapThresholdUpdated(uint256 newThreshold);
    event ForeignTokenRecovered(address indexed token, address indexed to, uint256 amount);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    // ==========================================
    // ERC-7572: OFFICIAL CONTRACT-LEVEL METADATA & DOMAIN
    // ==========================================
    string private _contractURI;

    event ContractURIUpdated();

    /// @notice Address of Central Capital Reserves (Supreme Owner & Master Operating Vault)
    address payable public centralCapitalReserves;

    /**
     * @notice Constructor: Initializes token supply, assigns 10B TNS to Central Capital Reserves (msg.sender),
     * sets up Uniswap router integration on Base, and establishes initial corporate treasury parameters.
     */
    constructor() payable {
        address payable _ccr = payable(owner());
        centralCapitalReserves = _ccr;

        // 1. Initial Genesis Allocation: 100% of supply minted to Central Capital Reserves
        _balances[_ccr] = _totalSupply;
        emit Transfer(address(0), _ccr, _totalSupply);

        // Pre-configure treasuryWallets[0] to Central Capital Reserves
        treasuryWallets[0] = TreasuryWallet(_ccr, 100);
        treasuryWalletCount = 1;

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(_name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );

        address routerAddress = address(0);
        if (block.chainid == 8453) {
            routerAddress = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24; // Base Mainnet
        } else if (block.chainid == 84532) {
            routerAddress = 0x1689E7B1F10000AE47eBfE339a4f69dECd19F602; // Base Sepolia Testnet
        } else if (block.chainid == 31337 || block.chainid == 1337) {
            routerAddress = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; // Local Testnets (Foundry / Hardhat)
        } else {
            revert("TNS: Unsupported network. Deployment restricted to Base.");
        }

        require(routerAddress.code.length > 0 || block.chainid == 31337 || block.chainid == 1337, "TNS: Router has no code");
        IUniswapV2Router02 _router = IUniswapV2Router02(routerAddress);
        uniswapV2Router = _router;

        _excludeFromFees(_ccr, true);
        _excludeFromFees(address(this), true);

        _excludeFromLimits(_ccr, true);
        _excludeFromLimits(address(this), true);
        _excludeFromLimits(address(0xdead), true);
        _excludeFromLimits(address(_router), true);

        // 2. Validate factory, WETH, and pair creation
        if (routerAddress.code.length > 0) {
            _initUniswapPair(_router);
        }
    }

    function _initUniswapPair(IUniswapV2Router02 _router) internal {
        address factory = _router.factory();
        require(factory.code.length > 0, "TNS: Factory has no code");
        address weth = _router.WETH();
        require(weth.code.length > 0, "TNS: WETH has no code");

        address pair;
        address existingPair = IUniswapV2Factory(factory).getPair(address(this), weth);
        if (existingPair != address(0)) {
            require(existingPair.code.length > 0, "TNS: Existing pair is not a contract");
            require(IUniswapV2Pair(existingPair).totalSupply() == 0, "TNS: Existing pair already has liquidity");
            pair = existingPair;
        } else {
            pair = IUniswapV2Factory(factory).createPair(address(this), weth);
            require(pair != address(0) && pair.code.length > 0, "TNS: Pair creation failed");
        }

        address t0 = IUniswapV2Pair(pair).token0();
        address t1 = IUniswapV2Pair(pair).token1();
        require(
            (t0 == address(this) && t1 == weth) || (t0 == weth && t1 == address(this)),
            "TNS: Invalid pair tokens"
        );
        uniswapV2Pair = pair;
    }

    receive() external payable {}

    /**
     * @notice Synchronizes Central Capital Reserves, treasuryWallets[0], and exemptions upon ownership handoff.
     */
    function _transferOwnership(address newOwner) internal override {
        address oldOwner = owner();
        super._transferOwnership(newOwner);

        if (newOwner != address(0)) {
            if (oldOwner != address(0) && oldOwner != address(this)) {
                _excludeFromFees(oldOwner, false);
                _excludeFromLimits(oldOwner, false);
            }
            _excludeFromFees(newOwner, true);
            _excludeFromLimits(newOwner, true);

            centralCapitalReserves = payable(newOwner);

            if (treasuryWalletCount > 0 && treasuryWallets[0].wallet == payable(oldOwner)) {
                treasuryWallets[0].wallet = payable(newOwner);

                address payable[] memory currentWallets = new address payable[](treasuryWalletCount);
                uint256[] memory currentPercentages = new uint256[](treasuryWalletCount);
                for (uint256 i = 0; i < treasuryWalletCount; i++) {
                    currentWallets[i] = treasuryWallets[i].wallet;
                    currentPercentages[i] = treasuryWallets[i].percentage;
                }
                emit TreasuryWalletsConfigured(currentWallets, currentPercentages);
            }
        }
    }

    // ==========================================
    // ERC-20 STANDARD FUNCTIONS
    // ==========================================

    function name() public pure override returns (string memory) { return _name; }
    function symbol() public pure override returns (string memory) { return _symbol; }
    function decimals() public pure override returns (uint8) { return _decimals; }
    function totalSupply() public pure override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address tokenOwner, address spender) public view override returns (uint256) {
        return _allowances[tokenOwner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[sender][_msgSender()];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: allowance exceeded");
            unchecked {
                _approve(sender, _msgSender(), currentAllowance - amount);
            }
        }
        _transfer(sender, recipient, amount);
        return true;
    }

    function _approve(address tokenOwner, address spender, uint256 amount) internal {
        require(tokenOwner != address(0), "ERC20: approve from zero");
        require(spender != address(0), "ERC20: approve to zero");
        _allowances[tokenOwner][spender] = amount;
        emit Approval(tokenOwner, spender, amount);
    }

    // ==========================================
    // EIP-2612 GASLESS PERMIT
    // ==========================================

    function nonces(address tokenOwner) external view override returns (uint256) {
        return _nonces[tokenOwner];
    }

    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(_name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function permit(
        address tokenOwner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        require(block.timestamp <= deadline, "ERC20Permit: expired");
        require(uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "ERC20Permit: invalid s");
        require(v == 27 || v == 28, "ERC20Permit: invalid v");

        bytes32 structHash = keccak256(
            abi.encode(_PERMIT_TYPEHASH, tokenOwner, spender, value, _nonces[tokenOwner]++, deadline)
        );

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        address signer = ecrecover(hash, v, r, s);
        require(signer != address(0) && signer == tokenOwner, "ERC20Permit: invalid signature");

        _approve(tokenOwner, spender, value);
    }

    // ==========================================
    // TRANSFER & TAX LOGIC (CHECKS-EFFECTS-INTERACTIONS STRICT)
    // ==========================================

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from zero");
        require(to != address(0), "ERC20: transfer to zero");

        // Protect users against accidental permanent locking of tokens
        require(to != address(this), "TNS: Direct deposit forbidden. Use migrateToNativeChain");

        // ERC-20 standard: 0-value transfers must execute cleanly
        if (amount == 0) {
            emit Transfer(from, to, 0);
            return;
        }

        // 1. Calculate Fees to determine net transfer amount
        bool takeFee = true;
        if (isExcludedFromFees[from] || isExcludedFromFees[to] || taxPermanentlyDisabled) {
            takeFee = false;
        }

        uint256 fees = 0;
        if (takeFee) {
            if (isAutomatedMarketMakerPair(from) && buyTax > 0) {
                fees = (amount * buyTax) / FEE_DENOMINATOR;
            } else if (isAutomatedMarketMakerPair(to) && sellTax > 0) {
                fees = (amount * sellTax) / FEE_DENOMINATOR;
            }
        }

        uint256 amountAfterFee = amount - fees;

        // 2. Anti-Snipe guards: check net tokens received, excluding exempt addresses
        if (limitsInEffect) {
            if (from != owner() && to != owner() && to != address(0xdead) && !_inSwap) {
                if (isAutomatedMarketMakerPair(from) && !isExcludedFromLimits[to]) {
                    require(_lastTxBlock[to] < block.number, "Launch guard: 1 buy per block");
                    _lastTxBlock[to] = block.number;
                    require(amount <= maxTxAmount, "Max Buy exceeded");
                    require(_balances[to] + amountAfterFee <= maxWalletAmount, "Max Wallet exceeded");
                } else if (!isAutomatedMarketMakerPair(to) && !isExcludedFromLimits[to]) {
                    require(_balances[to] + amountAfterFee <= maxWalletAmount, "Max Wallet exceeded");
                }
            }
        }

        // 3. EFFECTS: Update all balances before external calls
        require(_balances[from] >= amount, "ERC20: transfer exceeds balance");
        _balances[from] -= amount;
        _balances[to] += amountAfterFee;

        if (fees > 0) {
            _balances[address(this)] += fees;
            accumulatedFeeTokens += fees;
            emit Transfer(from, address(this), fees);
        }
        emit Transfer(from, to, amountAfterFee);

        // 4. INTERACTIONS: Automated swapBack strictly on sells to AMM pool
        uint256 contractFeeBalance = accumulatedFeeTokens;
        bool canSwap = contractFeeBalance >= swapTokensAtAmount;

        if (
            canSwap &&
            !_inSwap &&
            isAutomatedMarketMakerPair(to) &&
            !isExcludedFromFees[from] &&
            !isExcludedFromFees[to]
        ) {
            _swapBack(contractFeeBalance);
        }
    }

    // ==========================================
    // TREASURY ROUTER & SWAPBACK LOGIC
    // ==========================================

    function _swapBack(uint256 tokenAmount) internal lockTheSwap {
        uint256 maxSwap = swapTokensAtAmount * 5;
        uint256 swapAmount = tokenAmount > maxSwap ? maxSwap : tokenAmount;

        if (swapAmount > accumulatedFeeTokens) {
            swapAmount = accumulatedFeeTokens;
        }

        if (swapAmount == 0) return;

        accumulatedFeeTokens -= swapAmount;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        // Require reliable quote with 5% slippage tolerance
        uint256 amountOutMin = 0;
        try uniswapV2Router.getAmountsOut(swapAmount, path) returns (uint256[] memory amounts) {
            if (amounts.length >= 2 && amounts[1] > 0) {
                amountOutMin = (amounts[1] * 95) / 100;
            }
        } catch {
            accumulatedFeeTokens += swapAmount;
            return;
        }

        if (amountOutMin == 0) {
            accumulatedFeeTokens += swapAmount;
            return;
        }

        // Approve router strictly after quote succeeds to avoid residual allowance
        _approve(address(this), address(uniswapV2Router), swapAmount);

        uint256 initialETH = address(this).balance;

        try uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapAmount,
            amountOutMin,
            path,
            address(this),
            block.timestamp
        ) {
            uint256 ethReceived = address(this).balance - initialETH;

            if (ethReceived > 0) {
                if (autoSplitEnabled && treasuryWalletCount > 0) {
                    // Pull-based allocation: directly credits ledgers without external calls during user transfers
                    uint256 allocatedETH = _allocateTreasuryShares(ethReceived);
                    emit TreasuryDistributionExecuted(swapAmount, ethReceived, allocatedETH);
                } else {
                    emit VaultAccumulationRecorded(swapAmount, ethReceived, address(this).balance);
                }
            }
        } catch {
            accumulatedFeeTokens += swapAmount;
        }
    }

    /**
     * @notice Pull-based allocation: updates internal ledger with zero external calls during token transfers.
     */
    function _allocateTreasuryShares(uint256 ethAmount) internal returns (uint256 allocatedETH) {
        for (uint256 i = 0; i < treasuryWalletCount; i++) {
            if (treasuryWallets[i].percentage > 0) {
                uint256 share = (ethAmount * treasuryWallets[i].percentage) / 100;
                if (share > 0) {
                    pendingTreasuryETH[treasuryWallets[i].wallet] += share;
                    allocatedETH += share;
                }
            }
        }
        totalPendingTreasuryETH += allocatedETH;
    }

    /**
     * @notice Pull-payment claim function for treasury wallets to withdraw pending ETH.
     */
    function claimTreasuryETH() external nonReentrant {
        _claimTreasuryETHInternal(payable(_msgSender()));
    }

    /**
     * @notice Pull-payment claim function allowing treasury wallets to send pending ETH to a designated recipient.
     */
    function claimTreasuryETHTo(address payable recipient) external nonReentrant {
        require(recipient != address(0), "Zero recipient address");
        require(recipient != address(this), "Cannot claim to contract");
        _claimTreasuryETHInternal(recipient);
    }

    function _claimTreasuryETHInternal(address payable recipient) internal {
        uint256 pending = pendingTreasuryETH[_msgSender()];
        require(pending > 0, "No pending ETH to claim");

        // EFFECTS: Update state and emit event before external call
        pendingTreasuryETH[_msgSender()] = 0;
        totalPendingTreasuryETH -= pending;
        emit TreasuryPaymentClaimed(_msgSender(), recipient, pending);

        // INTERACTIONS: External call is the final statement
        (bool success, ) = recipient.call{value: pending}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice Returns comprehensive treasury accounting metrics for real-time monitoring.
     */
    function getTreasuryAccounting() external view returns (
        uint256 contractETHBalance,
        uint256 totalPendingETH,
        uint256 availableUnreservedETH
    ) {
        contractETHBalance = address(this).balance;
        totalPendingETH = totalPendingTreasuryETH;
        availableUnreservedETH = contractETHBalance > totalPendingETH ? contractETHBalance - totalPendingETH : 0;
    }

    // ==========================================
    // 1-TO-5 TREASURY CONFIGURATION FUNCTIONS
    // ==========================================

    function setTreasuryWallets(
        address payable[] calldata wallets,
        uint256[] calldata percentages
    ) external onlyOwner {
        require(wallets.length == percentages.length, "Mismatched arrays");
        require(wallets.length >= 1 && wallets.length <= 5, "Must specify 1 to 5 wallets");

        // Revoke fee and limit exemptions from previous treasury wallets
        for (uint256 i = 0; i < treasuryWalletCount; i++) {
            address prev = treasuryWallets[i].wallet;
            if (prev != owner() && prev != address(this)) {
                isExcludedFromFees[prev] = false;
                isExcludedFromLimits[prev] = false;
                emit ExcludeFromFees(prev, false);
                emit ExcludeFromLimits(prev, false);
            }
        }

        uint256 total = 0;
        treasuryWalletCount = wallets.length;

        for (uint256 i = 0; i < wallets.length; i++) {
            require(wallets[i] != address(0), "Zero address");
            for (uint256 j = 0; j < i; j++) {
                require(wallets[i] != wallets[j], "Duplicate treasury wallet");
            }

            total += percentages[i];
            treasuryWallets[i] = TreasuryWallet(wallets[i], percentages[i]);

            _excludeFromFees(wallets[i], true);
            _excludeFromLimits(wallets[i], true);
        }

        require(total == 100, "Must total 100%");
        emit TreasuryWalletsConfigured(wallets, percentages);
    }

    function setAutoSplitEnabled(bool _enabled) external onlyOwner {
        autoSplitEnabled = _enabled;
        emit AutoSplitToggled(_enabled);
    }

    function distributeVaultETH() external nonReentrant onlyOwner {
        uint256 availableVaultETH = address(this).balance > totalPendingTreasuryETH
            ? address(this).balance - totalPendingTreasuryETH
            : 0;
        require(availableVaultETH > 0, "No unreserved ETH in vault");
        require(treasuryWalletCount > 0, "Treasury wallets not configured");

        uint256 allocatedETH = _allocateTreasuryShares(availableVaultETH);
        emit VaultETHDistributed(availableVaultETH, allocatedETH);
    }

    function withdrawContractETH(address payable recipient, uint256 amount) external nonReentrant onlyOwner {
        require(recipient != address(0), "Zero address");
        uint256 availableVaultETH = address(this).balance > totalPendingTreasuryETH
            ? address(this).balance - totalPendingTreasuryETH
            : 0;
        require(amount > 0, "TNS: Amount must be > 0");
        require(amount <= availableVaultETH, "TNS: Amount exceeds unreserved vault balance");

        // EFFECTS before INTERACTIONS
        emit VaultETHWithdrawn(recipient, amount);

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Withdraw failed");
    }

    function getTreasuryWallets() external view returns (address payable[] memory wallets, uint256[] memory percentages) {
        wallets = new address payable[](treasuryWalletCount);
        percentages = new uint256[](treasuryWalletCount);
        for (uint256 i = 0; i < treasuryWalletCount; i++) {
            wallets[i] = treasuryWallets[i].wallet;
            percentages[i] = treasuryWallets[i].percentage;
        }
    }

    // ==========================================
    // 24-HOUR TIMELOCK GOVERNANCE CONTROLS (TAX)
    // ==========================================

    function queueTaxUpdate(uint256 _newBuyTax, uint256 _newSellTax) external onlyOwner {
        require(!taxPermanentlyDisabled, "Tax permanently disabled");
        require(_newBuyTax <= MAX_TAX, "Buy tax exceeds 1.00% ceiling");
        require(_newSellTax <= MAX_TAX, "Sell tax exceeds 1.00% ceiling");

        uint256 readyAt = block.timestamp + TIMELOCK_DELAY;
        queuedTaxUpdate = QueuedTaxUpdate(_newBuyTax, _newSellTax, readyAt, true);

        emit TaxUpdateQueued(_newBuyTax, _newSellTax, readyAt);
    }

    function executeTaxUpdate() external onlyOwner {
        require(!taxPermanentlyDisabled, "Tax permanently disabled");
        require(queuedTaxUpdate.isQueued, "No update queued");
        require(block.timestamp >= queuedTaxUpdate.readyTimestamp, "Timelock not met");

        buyTax = queuedTaxUpdate.newBuyTax;
        sellTax = queuedTaxUpdate.newSellTax;
        queuedTaxUpdate.isQueued = false;

        emit TaxUpdateExecuted(buyTax, sellTax);
    }

    function cancelTaxUpdate() external onlyOwner {
        require(queuedTaxUpdate.isQueued, "No update to cancel");
        queuedTaxUpdate.isQueued = false;
        emit TaxUpdateCancelled();
    }

    function permanentlyDisableTax() external onlyOwner {
        require(!taxPermanentlyDisabled, "Tax already disabled");
        buyTax = 0;
        sellTax = 0;
        taxPermanentlyDisabled = true;
        if (queuedTaxUpdate.isQueued) {
            queuedTaxUpdate.isQueued = false;
        }
        emit TaxPermanentlyDisabled();
    }

    // ==========================================
    // ADJUSTABLE SWAP THRESHOLD & MANUAL SWAP
    // ==========================================

    function setSwapTokensAtAmount(uint256 newAmount) external onlyOwner {
        require(newAmount >= 100_000 * 10**18, "Threshold too low");
        require(newAmount <= 50_000_000 * 10**18, "Cannot exceed 0.5% supply");
        swapTokensAtAmount = newAmount;
        emit SwapThresholdUpdated(newAmount);
    }

    function manualSwapBack(uint256 tokenAmount, uint256 minAmountOut) external nonReentrant lockTheSwap onlyOwner {
        require(tokenAmount > 0, "Amount must be > 0");
        require(tokenAmount <= accumulatedFeeTokens, "Amount exceeds fee balance");
        require(minAmountOut > 0, "Must specify minimum output");

        accumulatedFeeTokens -= tokenAmount;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uint256 initialETH = address(this).balance;

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            minAmountOut,
            path,
            address(this),
            block.timestamp
        );

        uint256 ethReceived = address(this).balance - initialETH;

        if (ethReceived > 0) {
            if (autoSplitEnabled && treasuryWalletCount > 0) {
                uint256 allocatedETH = _allocateTreasuryShares(ethReceived);
                emit TreasuryDistributionExecuted(tokenAmount, ethReceived, allocatedETH);
            } else {
                emit VaultAccumulationRecorded(tokenAmount, ethReceived, address(this).balance);
            }
        }
    }

    // ==========================================
    // FOREIGN TOKEN RECOVERY
    // ==========================================

    function recoverForeignToken(address tokenAddress, address recipient, uint256 amount) external nonReentrant onlyOwner {
        require(tokenAddress != address(0), "Zero token address");
        require(tokenAddress.code.length > 0, "Target is not a contract");
        require(tokenAddress != address(this), "Cannot rescue native TNS");
        require(recipient != address(0), "Zero recipient address");
        emit ForeignTokenRecovered(tokenAddress, recipient, amount);

        (bool success, bytes memory data) = tokenAddress.call(
            abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Rescue failed");
    }

    // ==========================================
    // SOVEREIGN L1 ESCROW HOOK
    // ==========================================

    function setMigrationActive(bool active) external onlyOwner {
        migrationActive = active;
        emit MigrationStateUpdated(active);
    }

    function migrateToNativeChain(uint256 amount, string calldata destinationAddress) external nonReentrant {
        require(migrationActive, "L1 bridge not active");
        require(amount > 0, "Amount must be > 0");
        require(bytes(destinationAddress).length > 0, "Invalid destination");
        require(_balances[_msgSender()] >= amount, "Insufficient balance");

        _balances[_msgSender()] -= amount;
        _balances[address(this)] += amount;
        totalMigratedToNativeL1 += amount;
        migrationNonce++;

        emit Transfer(_msgSender(), address(this), amount);
        emit TokensMigratedToNativeL1(migrationNonce, _msgSender(), amount, destinationAddress, block.timestamp);
    }

    // ==========================================
    // OWNER CONTROLS (SAFETY & LIMITS)
    // ==========================================

    /// @notice Allows owner to gradually increase limits day-by-day as trading volume scales.
    /// @dev Limits can ONLY be increased, never decreased, to mathematically prevent honeypot classification.
    /// @param newMaxTx The new maximum transaction amount (must be >= current maxTxAmount)
    /// @param newMaxWallet The new maximum wallet amount (must be >= current maxWalletAmount)
    function updateLimits(uint256 newMaxTx, uint256 newMaxWallet) external onlyOwner {
        require(limitsInEffect, "TNS: Limits permanently removed");
        require(newMaxTx >= maxTxAmount, "TNS: Cannot reduce maxTxAmount");
        require(newMaxWallet >= maxWalletAmount, "TNS: Cannot reduce maxWalletAmount");
        require(newMaxWallet <= _totalSupply, "TNS: Exceeds total supply");

        maxTxAmount = newMaxTx;
        maxWalletAmount = newMaxWallet;
        emit LimitsUpdated(newMaxTx, newMaxWallet);
    }

    function removeLimits() external onlyOwner {
        limitsInEffect = false;
        emit LimitsRemoved();
    }

    function excludeFromFees(address account, bool excluded) external onlyOwner {
        _excludeFromFees(account, excluded);
    }

    function _excludeFromFees(address account, bool excluded) internal {
        isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    function excludeFromLimits(address account, bool excluded) external onlyOwner {
        _excludeFromLimits(account, excluded);
    }

    function _excludeFromLimits(address account, bool excluded) internal {
        isExcludedFromLimits[account] = excluded;
        emit ExcludeFromLimits(account, excluded);
    }

    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        require(pair != uniswapV2Pair, "Cannot change Uniswap pair");
        _automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function isAutomatedMarketMakerPair(address pair) public view returns (bool) {
        return pair == uniswapV2Pair || _automatedMarketMakerPairs[pair];
    }

    // ==========================================
    // ERC-7572: CONTRACT-LEVEL METADATA & DOMAIN LINK
    // ==========================================

    /// @notice Returns the official corporate metadata URI linking to the company domain and branding
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Updates or clears the official company domain URI (can be updated or cleared to "" at any time)
    /// @param newURI The new metadata URL (e.g. "https://trendsnsolutions.com/api/metadata.json" or "")
    function setContractURI(string calldata newURI) external onlyOwner {
        _contractURI = newURI;
        emit ContractURIUpdated();
    }
}
