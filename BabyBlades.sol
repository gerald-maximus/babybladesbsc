// SPDX-License-Identifier: MIT License

import "./BabyBladesDividendTracker.sol";
import "./DividendPayingToken.sol";
import "./IUniswapV2Pair.sol";
import "./IUniswapRouter.sol";
import "./IUniswapV2Factory.sol";
import "./ERC20.sol";

pragma solidity ^0.7.6;

contract BabyBlades is ERC20, Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    address public immutable uniswapV2Pair;

    bool private swapping;
    bool public swapAndLiquifyEnabled = true;

    BabyBladesDividendTracker public dividendTracker;
    
    // Constraints for changing various buy/sell thresholds and max wallet holdings - in practice
    // actual values should be reasonable
    uint256 public immutable MIN_BUY_TRANSACTION_AMOUNT = 2500000000 * (10**18); // 0.5% of supply
    uint256 public immutable MAX_BUY_TRANSACTION_AMOUNT = 25000000000 * (10**18); // 5% of supply
    uint256 public immutable MIN_SELL_TRANSACTION_AMOUNT = 5000000000 * (10**18); // 1% of total supply
    uint256 public immutable MAX_SELL_TRANSACTION_AMOUNT = 25000000000 * (10**18); // 5% of total supply
    uint256 public immutable MIN_SWAP_TOKENS_AT_AMOUNT = 100000000 * (10**18); // 0.02% of total supply
    uint256 public immutable MAX_SWAP_TOKENS_AT_AMOUNT = 10000000000 * (10**18); // 2% of total supply
    
    uint256 public maxBuyTransactionAmount = 5000000000 * (10**18); // 1% of supply
    uint256 public maxSellTransactionAmount = 5000000000 * (10**18); // 1% of supply
    uint256 public swapTokensAtAmount = 100000000 * (10**18); // 0.02 % of supply

    // Max fees to avoid owner hanky panky - in practice the actual fees should be much lower
    uint256 public immutable MAX_MARKETING_FEE = 10;
    uint256 public immutable MAX_BUYBACK_FEE = 5;
    uint256 public immutable MAX_REWARDS_FEE = 10;
    uint256 public immutable MAX_LIQUIDITY_FEE = 5;
    uint256 public immutable MAX_TOTAL_FEES = 30;
    uint256 public immutable MAX_SELL_FEE = 5;

    uint256 public marketingFee = 4;
    uint256 public buybackFee = 2;
    uint256 public rewardsFee = 5;
    uint256 public liquidityFee = 3;
    uint256 public sellFee = 4; // fees are increased by 4% for sells

    // Trading can only be enabled, not disabled. Used so that contract can be deployed / liq added
    // without bots interfering.
    bool internal tradingEnabled = false;

    address payable public marketingWallet = 0xB3294d75837226319cFFe971b4612F4755D41B8d;
    address payable public buybackWallet = 0x604C906F7D21688AaD6C5266660A00cCC5e238Df;
    address payable public privateSaleWallet = 0x62338b7C7df8C3B15C83194068372FC9c527E07b;

    // Cryptoblades (SKILL)
    address public rewardToken = 0x154A9F9cbd3449AD22FDaE23044319D6eF2a1Fab;

    // use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 300000;

    // Absolute max gas amount for processing dividends
    uint256 public immutable MAX_GAS_FOR_PROCESSING = 5000000;

    // exclude from fees and max transaction amount
    mapping (address => bool) private _isExcludedFromFees;

    // Can add LP before trading is enabled
    mapping (address => bool) public isWhitelisted;

    uint256 public totalFeesCollected;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping (address => bool) public automatedMarketMakerPairs;

    event EnableTrading(uint indexed blockNumber);

    event UpdateDividendTracker(address indexed newAddress, address indexed oldAddress);
    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);
    event UpdateMarketingWallet(address indexed newWallet, address indexed oldWallet);
    event UpdateBuybackWallet(address indexed newWallet, address indexed oldWallet);
    event UpdatePrivateSaleWallet(address indexed newWallet, address indexed oldWallet);
    event UpdateGasForProcessing(uint256 indexed newValue, uint256 indexed oldValue);

    event UpdateMarketingFee(uint256 indexed newValue, uint256 indexed oldValue);
    event UpdateBuybackFee(uint256 indexed newValue, uint256 indexed oldValue);
    event UpdateLiquidityFee(uint256 indexed newValue, uint256 indexed oldValue);
    event UpdateRewardsFee(uint256 indexed newValue, uint256 indexed oldValue);
    event UpdateSellFee(uint256 indexed newValue, uint256 indexed oldValue);

    event UpdateMaxBuyTransactionAmount(uint256 indexed newValue, uint256 indexed oldValue);
    event UpdateMaxSellTransactionAmount(uint256 indexed newValue, uint256 indexed oldValue);
    event UpdateSwapTokensAtAmount(uint256 indexed newValue, uint256 indexed oldValue);
    event UpdateSwapAndLiquify(bool enabled);

    event WhitelistAccount(address indexed account, bool isWhitelisted);
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    event SendDividends(
    	uint256 tokensSwapped,
    	uint256 amount
    );

    event ProcessedDividendTracker(
    	uint256 iterations,
    	uint256 claims,
        uint256 lastProcessedIndex,
    	bool indexed automatic,
    	uint256 gas,
    	address indexed processor
    );

    event TransferETHToMarketingWallet(
        address indexed wallet,
        uint256 amount
    );
    event TransferTokensToMarketingWallet(
        address indexed wallet,
        uint256 amount
    );
    event TransferETHToBuybackWallet(
        address indexed wallet,
        uint256 amount
    );
    event TransferTokensToBuybackWallet(
        address indexed wallet,
        uint256 amount
    );
    event ExcludeAccountFromDividends(
        address indexed account
    );

    constructor() public ERC20("BABYBLADES", "BBLD") {

    	dividendTracker = new BabyBladesDividendTracker();
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

         // Create a uniswap pair for this new token
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());

        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        // exclude from receiving dividends. We purposely don't exclude
        // the marketing wallet from dividends since we're going to use
        // those dividends for things like giveaways and marketing. These
        // dividends are more useful than tokens in some cases since selling
        // them doesnt impact token price.
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(address(_uniswapV2Router));
        dividendTracker.excludeFromDividends(address(0xdEaD));
        dividendTracker.excludeFromDividends(address(0));
        dividendTracker.excludeFromDividends(owner());
        dividendTracker.excludeFromDividends(buybackWallet);
        dividendTracker.excludeFromDividends(privateSaleWallet);

        // exclude from paying fees or having max transaction amount
        excludeFromFees(address(this), true);
        excludeFromFees(marketingWallet, true);
        excludeFromFees(buybackWallet, true);
        excludeFromFees(privateSaleWallet, true);
        excludeFromFees(owner(), true);
        excludeFromFees(address(0xdEaD), true);
        excludeFromFees(address(0), true);

        // Whitelist accounts so they can transfer tokens before trading is enabled
        whitelistAccount(address(this), true);
        whitelistAccount(owner(), true);
        whitelistAccount(address(uniswapV2Router), true);
        whitelistAccount(privateSaleWallet, true);

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), 500000000000 * (10**18));
    }

    receive() external payable {

  	}

    function updateSwapAndLiquify(bool enabled) external onlyOwner {
        swapAndLiquifyEnabled = enabled;
        emit UpdateSwapAndLiquify(enabled);
    }

    function isTradingEnabled() public view returns (bool) {
        return tradingEnabled;
    }

    function whitelistAccount(address account, bool whitelisted) public onlyOwner {
        isWhitelisted[account] = whitelisted;
        emit WhitelistAccount(account, whitelisted);
    }

    function isWhitelistedAccount(address account) public view returns (bool) {
        return isWhitelisted[account];
    }

    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "trading is already enabled");
        tradingEnabled = true;
        emit EnableTrading(block.number);
    }
  	
    function getTotalFees() public view returns (uint256) {
        return marketingFee.add(buybackFee).add(liquidityFee).add(rewardsFee);
    }

    function updateMarketingWallet(address payable newAddress) external onlyOwner {
        require(marketingWallet != newAddress, "new address required");
        address oldWallet = marketingWallet;
        marketingWallet = newAddress;
        excludeFromFees(newAddress, true);
        emit UpdateMarketingWallet(marketingWallet, oldWallet);
    }

    function updateBuybackWallet(address payable newAddress) external onlyOwner {
        require(buybackWallet != newAddress, "new address required");
        address oldWallet = buybackWallet;
        buybackWallet = newAddress;
        excludeFromFees(newAddress, true);
        emit UpdateBuybackWallet(buybackWallet, oldWallet);
    }

    function updatePrivateSaleWallet(address payable newAddress) external onlyOwner {
        require(privateSaleWallet != newAddress, "new address required");
        address oldWallet = privateSaleWallet;
        privateSaleWallet = newAddress;
        excludeFromFees(newAddress, true);
        emit UpdatePrivateSaleWallet(newAddress, oldWallet);
    }

    function updateDividendTracker(address newAddress) public onlyOwner {
        require(newAddress != address(dividendTracker), "BabyBlades: The dividend tracker already has that address");

        BabyBladesDividendTracker newDividendTracker = BabyBladesDividendTracker(payable(newAddress));

        require(newDividendTracker.owner() == address(this), "BabyBlades: The new dividend tracker must be owned by the BabyBlades token contract");

        newDividendTracker.excludeFromDividends(address(newDividendTracker));
        newDividendTracker.excludeFromDividends(address(this));
        newDividendTracker.excludeFromDividends(address(uniswapV2Router));
        newDividendTracker.excludeFromDividends(address(0xdEaD));
        newDividendTracker.excludeFromDividends(address(0));
        newDividendTracker.excludeFromDividends(owner());
        newDividendTracker.excludeFromDividends(buybackWallet);
        newDividendTracker.excludeFromDividends(privateSaleWallet);

        emit UpdateDividendTracker(newAddress, address(dividendTracker));

        dividendTracker = newDividendTracker;
    }

    function updateUniswapV2Router(address newAddress) public onlyOwner {
        require(newAddress != address(uniswapV2Router), "BabyBlades: The router already has that address");
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newAddress);
    }

    function excludeAccountFromDividends(address account) public onlyOwner {
        dividendTracker.excludeFromDividends(account);
        emit ExcludeAccountFromDividends(account);
    }

    function isExcludedFromDividends(address account) public view returns (bool) {
        return dividendTracker.isExcludedFromDividends(account);
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(address[] calldata accounts, bool excluded) public onlyOwner {
        for(uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        require(pair != uniswapV2Pair, "BabyBlades: The PancakeSwap pair cannot be removed from automatedMarketMakerPairs");

        _setAutomatedMarketMakerPair(pair, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(automatedMarketMakerPairs[pair] != value, "BabyBlades: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[pair] = value;

        if(value) {
            dividendTracker.excludeFromDividends(pair);
        }

        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function _validateFees() private view {
        require(getTotalFees() <= MAX_TOTAL_FEES, "total fees too high");
    }

    function updateMarketingFee(uint256 newFee) external onlyOwner {
        require(marketingFee != newFee, "new fee required");
        require(newFee <= MAX_MARKETING_FEE, "new fee too high");
        uint256 oldFee = marketingFee;
        marketingFee = newFee;
        _validateFees();
        emit UpdateMarketingFee(newFee, oldFee);
    }

    function updateBuybackFee(uint256 newFee) external onlyOwner {
        require(buybackFee != newFee, "new fee required");
        require(newFee <= MAX_BUYBACK_FEE, "new fee too high");
        uint256 oldFee = buybackFee;
        buybackFee = newFee;
        _validateFees();
        emit UpdateBuybackFee(newFee, oldFee);
    }

    function updateLiquidityFee(uint256 newFee) external onlyOwner {
        require(liquidityFee != newFee, "new fee required");
        require(newFee <= MAX_LIQUIDITY_FEE, "new fee too high");
        uint256 oldFee = liquidityFee;
        liquidityFee = newFee;
        _validateFees();
        emit UpdateLiquidityFee(newFee, oldFee);
    }

    function updateRewardsFee(uint256 newFee) external onlyOwner {
        require(rewardsFee != newFee, "new fee required");
        require(newFee <= MAX_REWARDS_FEE, "new fee too high");
        uint256 oldFee = rewardsFee;
        rewardsFee = newFee;
        _validateFees();
        emit UpdateRewardsFee(newFee, oldFee);
    }

    function updateSellFee(uint256 newFee) external onlyOwner {
        require(sellFee != newFee, "new fee required");
        require(newFee <= MAX_SELL_FEE, "new fee too high");
        uint256 oldFee = sellFee;
        sellFee = newFee;
        emit UpdateSellFee(newFee, oldFee);
    }

    function updateMaxBuyTransactionAmount(uint256 newValue) external onlyOwner {
        require(maxBuyTransactionAmount != newValue, "new value required");
        require(newValue >= MIN_BUY_TRANSACTION_AMOUNT && newValue <= MAX_BUY_TRANSACTION_AMOUNT, "new value must be >= MIN_BUY_TRANSACTION_AMOUNT and <= MAX_BUY_TRANSACTION_AMOUNT");
        uint256 oldValue = maxBuyTransactionAmount;
        maxBuyTransactionAmount = newValue;
        emit UpdateMaxBuyTransactionAmount(newValue, oldValue);
    }

    function updateMaxSellTransactionAmount(uint256 newValue) external onlyOwner {
        require(maxSellTransactionAmount != newValue, "new value required");
        require(newValue >= MIN_SELL_TRANSACTION_AMOUNT && newValue <= MAX_SELL_TRANSACTION_AMOUNT, "new value must be >= MIN_SELL_TRANSACTION_AMOUNT and <= MAX_SELL_TRANSACTION_AMOUNT");
        uint256 oldValue = maxSellTransactionAmount;
        maxSellTransactionAmount = newValue;
        emit UpdateMaxSellTransactionAmount(newValue, oldValue);
    }

    function updateSwapTokensAtAmount(uint256 newValue) external onlyOwner {
        require(swapTokensAtAmount != newValue, "new value required");
        require(newValue >= MIN_SWAP_TOKENS_AT_AMOUNT && newValue <= MAX_SWAP_TOKENS_AT_AMOUNT, "new value must be >= MIN_SWAP_TOKENS_AT_AMOUNT and <= MAX_SWAP_TOKENS_AT_AMOUNT");
        uint256 oldValue = swapTokensAtAmount;
        swapTokensAtAmount = newValue;
        emit UpdateSwapTokensAtAmount(newValue, oldValue);
    }

    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(newValue >= 200000 && newValue <= MAX_GAS_FOR_PROCESSING, "BabyBlades: gasForProcessing must be between 200,000 and MAX_GAS_FOR_PROCESSING");
        require(newValue != gasForProcessing, "BabyBlades: Cannot update gasForProcessing to same value");
        emit UpdateGasForProcessing(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function getClaimWait() external view returns(uint256) {
        return dividendTracker.claimWait();
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) public view returns(bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account) public view returns(uint256) {
    	return dividendTracker.withdrawableDividendOf(account);
  	}

	function dividendTokenBalanceOf(address account) public view returns (uint256) {
		return dividendTracker.balanceOf(account);
	}

    function getAccountDividendsInfo(address account)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
        return dividendTracker.getAccount(account);
    }

	function getAccountDividendsInfoAtIndex(uint256 index)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
    	return dividendTracker.getAccountAtIndex(index);
    }

	function processDividendTracker(uint256 gas) external onlyOwner {
		(uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(gas);
		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, false, gas, tx.origin);
    }

    function claim() external {
		dividendTracker.processAccount(msg.sender, false);
    }

    function getLastProcessedIndex() external view returns(uint256) {
    	return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns(uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        // Prohibit buys/sells before trading is enabled. This is useful for fair launches for obvious reasons
        if (from == uniswapV2Pair) {
            require(tradingEnabled || isWhitelisted[to], "trading isnt enabled or account isnt whitelisted");
        } else if (to == uniswapV2Pair) {
            require(tradingEnabled || isWhitelisted[from], "trading isnt enabled or account isnt whitelisted");
        }
        
        // Enforce max buy
        if (automatedMarketMakerPairs[from] &&
            // No max buy when removing liq
            to != address(uniswapV2Router)) {
             require(
                amount <= maxBuyTransactionAmount,
                "Transfer amount exceeds the maxTxAmount."
            );
        }

        if(amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        // Enforce max sell
        if( 
        	!swapping &&
            automatedMarketMakerPairs[to] && // sells only by detecting transfer to automated market maker pair
            tradingEnabled // we need to be able to add liq before trading is enabled
        ) {
            require(amount <= maxSellTransactionAmount, "Sell transfer amount exceeds the maxSellTransactionAmount.");
        }

		uint256 contractTokenBalance = balanceOf(address(this));
        bool canSwap = (contractTokenBalance >= swapTokensAtAmount) && swapAndLiquifyEnabled;
        uint256 totalFees = getTotalFees();

        // Swap and liq for sells
        if(
            canSwap &&
            !swapping &&
            automatedMarketMakerPairs[to]
        ) {
            swapping = true;
            uint256 liquidityAndTeamTokens = contractTokenBalance.mul(liquidityFee.add(marketingFee).add(buybackFee)).div(totalFees);
            swapAndLiquifyAndFundTeam(liquidityAndTeamTokens);

            uint256 rewardTokens = balanceOf(address(this));
            swapAndSendDividends(rewardTokens);

            swapping = false;
        }

        // Only take taxes for buys/sells (and obviously dont take taxes during swap and liquify)
        bool takeFee = !swapping && (automatedMarketMakerPairs[from] || automatedMarketMakerPairs[to]);

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if(takeFee) {
        	uint256 fees = amount.mul(totalFees).div(100);

            // If sell, add extra fee
            if(automatedMarketMakerPairs[to]) {
                fees += amount.mul(sellFee).div(100);
            }

            totalFeesCollected += fees;

        	amount = amount.sub(fees);

            super._transfer(from, address(this), fees);
        }

        super._transfer(from, to, amount);

        // Trigger dividends to be paid out
        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if(!swapping) {
	    	uint256 gas = gasForProcessing;

	    	try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
	    		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
	    	}
	    	catch {

	    	}
        }
    }

    function swapAndLiquifyAndFundTeam(uint256 tokens) private {
       // split the contract balance into halves
        uint256 half = tokens.div(2);
        uint256 otherHalf = tokens.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForEth(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // All fees except rewards fee
        uint256 totalFees = marketingFee.add(buybackFee).add(liquidityFee);
        
        uint256 liquidityTokens = otherHalf.mul(liquidityFee).div(totalFees);
        uint256 liquidityETH = newBalance.mul(liquidityFee).div(totalFees);
        uint256 marketingTokens = otherHalf.mul(marketingFee).div(totalFees);
        uint256 marketingETH = newBalance.mul(marketingFee).div(totalFees);
        uint256 buybackTokens = otherHalf.mul(buybackFee).div(totalFees);
        uint256 buybackETH = newBalance.mul(buybackFee).div(totalFees);
        
        // add liquidity to uniswap (really PCS, duh)
        addLiquidity(liquidityTokens, liquidityETH);
        emit SwapAndLiquify(half, newBalance, otherHalf);

        // Transfer tokens and ETH to marketing wallet
        _safeTransfer(address(this), marketingWallet, marketingTokens);
        emit TransferTokensToMarketingWallet(marketingWallet, marketingTokens);
        marketingWallet.transfer(marketingETH);
        emit TransferETHToMarketingWallet(marketingWallet, marketingETH);

        // Transfer tokens and ETH to dev wallet
        _safeTransfer(address(this), buybackWallet, buybackTokens);
        emit TransferTokensToBuybackWallet(buybackWallet, buybackTokens);
        buybackWallet.transfer(buybackETH);
        emit TransferETHToBuybackWallet(buybackWallet, buybackETH);
    }

    function swapTokensForEth(uint256 tokenAmount) private {

        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
        
    }

    function swapTokensForETH(uint256 tokenAmount, address recipient) private {
        // generate the uniswap pair path of tokens -> WETH
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETH(
            tokenAmount,
            0, // accept any amount of the reward token
            path,
            recipient,
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
       uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(this), // lock LP tokens in this contract forever - no rugpull, SAFU!!
            block.timestamp
        );
        
    }

    function swapTokensForRewards(uint256 tokenAmount, address recipient) private {
       
        // generate the uniswap pair path of weth -> reward token
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        path[2] = rewardToken;

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of the reward token
            path,
            recipient,
            block.timestamp
        );
    }

  function sendDividends() private returns (bool, uint256) {
        uint256 dividends = IERC20(rewardToken).balanceOf(address(this));
        bool success = IERC20(rewardToken).transfer(address(dividendTracker), dividends);
        
        if (success) {
            dividendTracker.distributeRewardTokenDividends(dividends);
        }
        
        return (success, dividends);
    }

    function swapAndSendDividends(uint256 tokens) private {
        // Locks the LP tokens in this contract forever
        swapTokensForRewards(tokens, address(this));
        (bool success, uint256 dividends) = sendDividends();
        if (success) {
            emit SendDividends(tokens, dividends);
        }
    }

    // For withdrawing ETH accidentally sent to the contract so senders can be refunded
    function getETHBalance() public view returns(uint) {
        return address(this).balance;
    }

    function withdrawOverFlowETH() external onlyOwner {
        address payable to = payable(msg.sender);
        to.transfer(getETHBalance());
    }

    function _safeTransfer(address token, address to, uint value) private {
        bytes4 SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TRANSFER_FAILED');
    }
}