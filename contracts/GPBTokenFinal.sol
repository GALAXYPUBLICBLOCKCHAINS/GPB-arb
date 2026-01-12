// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

abstract contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _transferOwnership(_msgSender());
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

contract GPBTokenFinal is Context, IERC20, Ownable {
    string private _name = "GPB Token";
    string private _symbol = "GPB";
    uint8 private _decimals = 18;
    uint256 private _totalSupply = 21_000_000 * 10 ** 18; 

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    address public marketingWallet;
    
    mapping(address => bool) public isExcludedFromFee;
    mapping(address => bool) public isExcludedFromLimits;
    mapping(address => bool) public isBlacklisted;

    mapping(address => bool) public automatedMarketMakerPairs;

    bool public tradingEnabled = false;
    uint256 public launchBlock;
    uint256 public deadBlocks;
    
    uint256 public buyTaxBp;
    uint256 public sellTaxBp;
    uint256 public transferTaxBp;
    uint256 public constant MAX_TAX_BP = 1000; 

    uint256 public maxBuyAmount;
    uint256 public maxSellAmount;
    uint256 public maxWalletAmount;
    
    uint256 public minTxAmount; 

    uint256 public timelockDelay = 180;

    struct PendingTaxChange {
        uint256 newBuyTax;
        uint256 newSellTax;
        uint256 newTransferTax;
        uint256 eta;
        bool active;
    }

    struct PendingLimitChange {
        uint256 newMaxBuy;
        uint256 newMaxSell;
        uint256 newMaxWallet;
        uint256 newMinTx;
        uint256 eta;
        bool active;
    }

    PendingTaxChange public pendingTaxChange;
    PendingLimitChange public pendingLimitChange;

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event TradingEnabled(uint256 indexed blockNumber);
    event TaxChangeQueued(uint256 buy, uint256 sell, uint256 transfer, uint256 eta);
    event TaxChangeExecuted(uint256 buy, uint256 sell, uint256 transfer);
    event LimitChangeQueued(uint256 maxBuy, uint256 maxSell, uint256 maxWallet, uint256 minTx, uint256 eta);
    event LimitChangeExecuted(uint256 maxBuy, uint256 maxSell, uint256 maxWallet, uint256 minTx);

    constructor(address _marketingWallet) {
        require(_marketingWallet != address(0), "Marketing wallet cannot be zero");
        marketingWallet = _marketingWallet;

        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);

        buyTaxBp = 100;
        sellTaxBp = 300;
        transferTaxBp = 0;

        minTxAmount = 100000000000000000; 
        
        maxBuyAmount = _totalSupply * 20 / 1000;    
        maxSellAmount = _totalSupply * 10 / 1000;   
        maxWalletAmount = _totalSupply * 30 / 1000; 

        excludeFromFeesAndLimits(owner(), true);
        excludeFromFeesAndLimits(address(this), true);
        excludeFromFeesAndLimits(marketingWallet, true);
        excludeFromFeesAndLimits(address(0xdead), true);
    }

    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public view returns (uint8) { return _decimals; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);
        _transfer(sender, recipient, amount);
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        
        require(!isBlacklisted[sender] && !isBlacklisted[recipient], "Address is blacklisted");

        bool excluded = isExcludedFromLimits[sender] || isExcludedFromLimits[recipient];

        bool isBuy = automatedMarketMakerPairs[sender];
        bool isSell = automatedMarketMakerPairs[recipient];

        if (!excluded) {
            require(tradingEnabled, "Trading not enabled yet");

            if (isBuy || isSell) {
                require(amount >= minTxAmount, "Swap amount too small (min 0.1 GPB)");
            }

            if (isBuy) {
                if (block.number <= launchBlock + deadBlocks) {
                    require(amount <= maxBuyAmount / 20, "Anti-bot: Limited during launch");
                }
                require(amount <= maxBuyAmount, "Buy amount exceeds limit");
            } 
            else if (isSell) {
                require(amount <= maxSellAmount, "Sell amount exceeds limit");
            } 
        }

        uint256 taxAmount = 0;
        
        if (!isExcludedFromFee[sender] && !isExcludedFromFee[recipient]) {
            if (isBuy) {
                taxAmount = amount * buyTaxBp / 10000; 
            } else if (isSell) {
                taxAmount = amount * sellTaxBp / 10000; 
            } else {
                taxAmount = amount * transferTaxBp / 10000; 
            }
        }

        uint256 sendAmount = amount - taxAmount;

        _balances[sender] -= amount;

        if (!excluded && !isSell && !automatedMarketMakerPairs[recipient] && maxWalletAmount > 0) {
            require(_balances[recipient] + sendAmount <= maxWalletAmount, "Recipient wallet limit exceeded");
        }

        _balances[recipient] += sendAmount;

        if (taxAmount > 0) {
            _balances[marketingWallet] += taxAmount;
            emit Transfer(sender, marketingWallet, taxAmount);
        }

        emit Transfer(sender, recipient, sendAmount);
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        require(owner_ != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }
    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        require(pair != address(0), "Zero address");
        automatedMarketMakerPairs[pair] = value;
        if (value) {
            isExcludedFromLimits[pair] = true;
        }
        emit SetAutomatedMarketMakerPair(pair, value);
    }
    function excludeFromFeesAndLimits(address account, bool excluded) public onlyOwner {
        isExcludedFromFee[account] = excluded;
        isExcludedFromLimits[account] = excluded;
    }

    function setBlacklist(address account, bool value) external onlyOwner {
        isBlacklisted[account] = value;
    }

    function enableTrading(uint256 _deadBlocks) external onlyOwner {
        require(!tradingEnabled, "Trading already enabled");
        tradingEnabled = true;
        launchBlock = block.number;
        deadBlocks = _deadBlocks;
        emit TradingEnabled(block.number);
    }

    function setMarketingWallet(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "Zero address");
        marketingWallet = _newWallet;
        excludeFromFeesAndLimits(_newWallet, true);
    }

    function setTimelockDelay(uint256 _newDelay) external onlyOwner {
        require(_newDelay >= 180 && _newDelay <= 7 days, "Invalid delay"); 
        require(_newDelay >= timelockDelay, "Cannot reduce delay"); 
        timelockDelay = _newDelay;
    }

    function queueTaxChange(uint256 _buy, uint256 _sell, uint256 _transferTax) external onlyOwner {
    require(_buy <= MAX_TAX_BP && _sell <= MAX_TAX_BP && _transferTax <= MAX_TAX_BP, "Tax too high");
    uint256 eta = block.timestamp + timelockDelay;
    pendingTaxChange = PendingTaxChange(_buy, _sell, _transferTax, eta, true);
    emit TaxChangeQueued(_buy, _sell, _transferTax, eta);
}

    function executeTaxChange() external onlyOwner {
        require(pendingTaxChange.active, "No pending change");
        require(block.timestamp >= pendingTaxChange.eta, "Timelock not expired");
        
        buyTaxBp = pendingTaxChange.newBuyTax;
        sellTaxBp = pendingTaxChange.newSellTax;
        transferTaxBp = pendingTaxChange.newTransferTax;
        
        pendingTaxChange.active = false;
        emit TaxChangeExecuted(buyTaxBp, sellTaxBp, transferTaxBp);
    }

    function queueLimitChange(uint256 _maxBuy, uint256 _maxSell, uint256 _maxWallet, uint256 _minTx) external onlyOwner {
        uint256 limitFloor = _totalSupply / 10000; // 0.01%
        require(_maxBuy >= limitFloor, "Max buy too low");
        require(_maxSell >= limitFloor, "Max sell too low");
        require(_maxWallet >= limitFloor, "Max wallet too low");

        uint256 eta = block.timestamp + timelockDelay;
        pendingLimitChange = PendingLimitChange(_maxBuy, _maxSell, _maxWallet, _minTx, eta, true);
        emit LimitChangeQueued(_maxBuy, _maxSell, _maxWallet, _minTx, eta);
    }

    function executeLimitChange() external onlyOwner {
        require(pendingLimitChange.active, "No pending change");
        require(block.timestamp >= pendingLimitChange.eta, "Timelock not expired");

        maxBuyAmount = pendingLimitChange.newMaxBuy;
        maxSellAmount = pendingLimitChange.newMaxSell;
        maxWalletAmount = pendingLimitChange.newMaxWallet;
        minTxAmount = pendingLimitChange.newMinTx;

        pendingLimitChange.active = false;
        emit LimitChangeExecuted(maxBuyAmount, maxSellAmount, maxWalletAmount, minTxAmount);
    }
}
