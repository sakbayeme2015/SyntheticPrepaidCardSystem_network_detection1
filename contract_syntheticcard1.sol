// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// -------------------- Minimal ERC20 interface --------------------
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// -------------------- Chainlink Aggregator interface --------------------
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}

/// -------------------- Ownable --------------------
abstract contract Ownable {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    modifier onlyOwner() {
        require(msg.sender == _owner, "Ownable: caller is not owner");
        _;
    }
    constructor(address initialOwner) {
        require(initialOwner != address(0), "zero owner");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }
    function owner() public view returns (address) { return _owner; }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero new owner");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/// -------------------- ReentrancyGuard --------------------
abstract contract ReentrancyGuard {
    uint256 private _status;
    constructor() { _status = 1; }
    modifier nonReentrant() {
        require(_status == 1, "reentrant");
        _status = 2;
        _;
        _status = 1;
    }
}

/// -------------------- Address Helpers --------------------
library AddressHelpers {
    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}

/// -------------------- Uniswap V3 Interfaces --------------------
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

library TransferHelper {
    function safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20(token).approve.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }
}

/// -------------------- Synthetic Prepaid Card System --------------------
contract SyntheticPrepaidCardSystem is Ownable, ReentrancyGuard {
    using AddressHelpers for address;

    IERC20 public immutable ETH_TOKEN;
    AggregatorV3Interface public ethUsdFeed;
    ISwapRouter public immutable swapRouter;

    mapping(address => bool) public whitelisted;

    uint256 public constant ETH_DECIMALS = 18;
    uint256 public constant ETH_UNIT = 10 ** ETH_DECIMALS;
    uint256 public constant MAX_LEVERAGE = 100000;

    struct PaymentCard {
        string cardNumber;
        string expiration;
        uint32 expirationTs;
        string securityCode;
        string cardType;
        string country;
        string issuer;
        string binRange;
        string cardholder;
        uint256 ethBalance;
        uint256 ethTokenBalance;
        uint256 reservedETH;
        uint256 ethDebt;
        string paypalVerificationCode;
        uint40 lastBorrowTs;
        uint40 repayDueTs;
    }

    PaymentCard[] public cards;

    /// ---------------- Events ----------------
    event ContractETHDeposited(address indexed from, uint256 amount, uint256 newContractBalance);
    event ETHDepositedToCard(uint256 indexed cardIndex, address indexed from, uint256 amountWei);
    event BorrowedETHToCard(uint256 indexed cardIndex, uint256 borrowAmountETH, uint256 collateralETHWei, uint256 borrowTs, string cardNumber);
    event PayPalTransferRequestedETH(uint256 indexed cardIndex, uint256 amountETH, string merchantIdentifier, string paypalAccount, string cardNumber, uint256 ts);
    event PayPalSettlementConfirmedETH(uint256 indexed cardIndex, uint256 amountETH, address indexed merchantAddress, bool success, string cardNumber, uint256 ts);
    event CardCreated(uint256 indexed cardIndex, string cardType, string cardNumber, string securityCode, string cardholder);
    event SwapExecuted(uint256 indexed cardIndex, address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOut, address recipient);
    event SpendExecuted(uint256 indexed cardIndex, string merchant, string asset, uint256 amount);
    event Liquidated(uint256 indexed cardIndex, string asset, uint256 repaidAmount, uint256 collateralETH);

    /// ---------------- Constructor ----------------
    constructor(address _eth, address _ethUsdFeed, address _swapRouter) Ownable(msg.sender) {
        require(_eth != address(0), "eth=0");
        require(_swapRouter != address(0), "swapRouter=0");

        ETH_TOKEN = IERC20(_eth);
        swapRouter = ISwapRouter(_swapRouter);
        if (_ethUsdFeed != address(0)) ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);

        whitelisted[msg.sender] = true;

        // Hardcoded initial cards to 50
        generateSyntheticCards(30);
    }

    /* ---------------------- Card generation ---------------------- */
    function generateSyntheticCards(uint256 count) public onlyOwner {
        require(count <= 1000, "count too big");
        for (uint i = 0; i < count; ++i) {
            uint seed = uint(keccak256(abi.encodePacked(block.timestamp, i, address(this))));
            uint variant = seed % 2; // Only Visa (0) or MasterCard (1), remove Amex

            PaymentCard memory pc;
            if (variant == 0) pc = _generateCardByType("4", 16, "Visa", seed, i);
            else pc = _generateCardByType("5", 16, "MasterCard", seed, i);

            cards.push(pc);
            emit CardCreated(cards.length - 1, pc.cardType, pc.cardNumber, pc.securityCode, pc.cardholder);
        }
    }

    function _generateCardByType(string memory prefix, uint fullLen, string memory cardType, uint seed, uint idx) internal pure returns (PaymentCard memory) {
        (string memory country, string memory issuer, string memory binRange) = _binMetadata(prefix, cardType);

        uint prefixLen = bytes(prefix).length;
        uint coreLen = fullLen - prefixLen - 1;
        string memory core = _numericString(seed, 1001, coreLen);
        string memory withoutCheck = string(abi.encodePacked(prefix, core));
        string memory checkDigit = _luhnCheckDigitString(withoutCheck);
        string memory finalPan = string(abi.encodePacked(withoutCheck, checkDigit));

        uint cvvLen = 3; // Only Visa and MasterCard, always 3 digits
        string memory cvv = _numericString(seed, 2002, cvvLen);

        (string memory expStr, uint32 expTs) = _generateExpiration(seed);

        string memory ppCode = _numericString(seed, 3003, 6);

        string memory cardholder = string(abi.encodePacked("Cardholder", _uintToString(idx + 1)));

        return PaymentCard({
            cardNumber: finalPan,
            expiration: expStr,
            expirationTs: expTs,
            securityCode: cvv,
            cardType: cardType,
            country: country,
            issuer: issuer,
            binRange: binRange,
            cardholder: cardholder,
            ethBalance: 0,
            ethTokenBalance: 0,
            reservedETH: 0,
            ethDebt: 0,
            paypalVerificationCode: ppCode,
            lastBorrowTs: 0,
            repayDueTs: 0
        });
    }

    function _binMetadata(string memory, string memory cardType) internal pure returns (string memory country, string memory issuer, string memory binRange) {
        if (keccak256(bytes(cardType)) == keccak256(bytes("Visa"))) return ("Various", "Visa Inc", "4000-4999");
        if (keccak256(bytes(cardType)) == keccak256(bytes("MasterCard"))) return ("Various", "MasterCard Inc", "5100-5599");
        return ("Unknown", "Unknown", cardType);
    }

    function _numericString(uint seed, uint nonce, uint len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint i = 0; i < len; ++i) {
            uint v = uint(keccak256(abi.encodePacked(seed, nonce, i))) % 10;
            b[i] = bytes1(uint8(48 + v));
        }
        return string(b);
    }

    function _generateExpiration(uint seed) internal pure returns (string memory, uint32) {
        uint month = 1 + (uint(keccak256(abi.encodePacked(seed, "expm"))) % 12);
        uint year = 2026 + (uint(keccak256(abi.encodePacked(seed, "expy"))) % 9);
        string memory mm = month < 10 ? string(abi.encodePacked("0", _uintToString(month))) : _uintToString(month);
        string memory yyyy = _uintToString(year);
        uint32 ts = uint32(((year - 1970) * 365 days + month * 30 days) % type(uint32).max);
        return (string(abi.encodePacked(mm, "/", yyyy)), ts);
    }

    function _luhnCheckDigitString(string memory noCheck) internal pure returns (string memory) {
        bytes memory digits = bytes(noCheck);
        uint sum = 0;
        bool dbl = true;
        for (uint i = digits.length; i > 0; --i) {
            uint8 d = uint8(digits[i - 1]) - 48;
            if (dbl) { uint dd = uint(d) * 2; if (dd > 9) dd -= 9; sum += dd; } else { sum += d; }
            dbl = !dbl;
        }
        uint check = (10 - (sum % 10)) % 10;
        return _uintToString(check);
    }

    function _uintToString(uint v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint temp = v; uint len;
        while (temp != 0) { ++len; temp /= 10; }
        bytes memory b = new bytes(len);
        uint k = len; temp = v;
        while (temp != 0) { k--; b[k] = bytes1(uint8(48 + temp % 10)); temp /= 10; }
        return string(b);
    }

    /* ------------------- PayPal verification ------------------- */
    function getPaypalCode(uint256 cardIndex) external view returns (string memory) {
        return cards[cardIndex].paypalVerificationCode;
    }

    function verifyPaypalCode(uint256 cardIndex, string calldata code) external view returns (bool) {
        return (keccak256(bytes(cards[cardIndex].paypalVerificationCode)) == keccak256(bytes(code)));
    }

    function rotatePaypalCode(uint256 cardIndex) external onlyOwner returns (string memory) {
        PaymentCard storage c = cards[cardIndex];
        string memory newCode = _numericString(uint(keccak256(abi.encodePacked(block.timestamp, cardIndex, "pprot"))), 7777, 6);
        c.paypalVerificationCode = newCode;
        return newCode;
    }

    /* ------------------- Deposit / Withdraw ------------------- */
    function depositETHToken(uint256 cardIndex, uint256 amount) external {
        PaymentCard storage c = cards[cardIndex];
        require(amount > 0, "amount>0");
        require(ETH_TOKEN.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        c.ethTokenBalance += amount;
        emit ETHDepositedToCard(cardIndex, msg.sender, amount);
    }

    function depositETHToCard(uint256 cardIndex) external payable {
        PaymentCard storage c = cards[cardIndex];
        require(msg.value > 0, "no ETH");
        c.ethBalance += msg.value;
        emit ETHDepositedToCard(cardIndex, msg.sender, msg.value);
    }

    function withdrawETHToken(uint256 cardIndex, uint256 amount) external onlyOwner {
        PaymentCard storage c = cards[cardIndex];
        require(c.ethTokenBalance >= amount, "insufficient");
        c.ethTokenBalance -= amount;
        require(ETH_TOKEN.transfer(msg.sender, amount), "transfer failed");
    }

    function withdrawETH(uint256 cardIndex, uint256 amount) external onlyOwner {
        PaymentCard storage c = cards[cardIndex];
        require(c.ethBalance >= amount, "insufficient");
        c.ethBalance -= amount;
        payable(msg.sender).transfer(amount);
    }

    /* ------------------- Spend / Borrow ------------------- */
    function spendETH(uint256 cardIndex, uint256 amount, string calldata merchant) external onlyOwner {
        PaymentCard storage c = cards[cardIndex];
        require(c.ethBalance >= amount, "insufficient");
        c.ethBalance -= amount;
        emit SpendExecuted(cardIndex, merchant, "ETH", amount);
    }

    function borrowETH(uint256 cardIndex, uint256 borrowAmountUSD) external onlyOwner {
    require(address(ethUsdFeed) != address(0), "ETH/USD feed not set");

    PaymentCard storage c = cards[cardIndex]; // local variable for the card

    // Fetch latest ETH/USD price
    (, int256 price, , , ) = ethUsdFeed.latestRoundData();
    require(price > 0, "invalid price");

    uint8 decimals = ethUsdFeed.decimals();

    // Convert borrowAmountUSD (assumed in 1e18 precision) to ETH
    // borrowAmountETH = borrowAmountUSD / price
    uint256 borrowAmountETH = (borrowAmountUSD * (10 ** decimals)) / uint256(price);

    // Check collateral leverage
    require(c.ethBalance * MAX_LEVERAGE / 1e5 >= borrowAmountETH, "max leverage exceeded");

    // Update card debt
    c.ethDebt += borrowAmountETH;
    c.lastBorrowTs = uint40(block.timestamp);
    c.repayDueTs = uint40(block.timestamp + 30 days);

    emit BorrowedETHToCard(cardIndex, borrowAmountETH, c.ethBalance, block.timestamp, c.cardNumber);
}

    /* ------------------- PayPal transfer / settle ------------------- */
    function requestPayPalTransfer(uint256 cardIndex, uint256 amount, string calldata merchantIdentifier, string calldata paypalAccount) external onlyOwner {
        PaymentCard storage c = cards[cardIndex];
        require(c.ethBalance >= amount, "insufficient balance");
        c.ethBalance -= amount;
        c.reservedETH += amount;
        emit PayPalTransferRequestedETH(cardIndex, amount, merchantIdentifier, paypalAccount, c.cardNumber, block.timestamp);
    }

    function confirmPayPalSettlement(uint256 cardIndex, uint256 amount, address merchantAddress, bool success) external onlyOwner {
        PaymentCard storage c = cards[cardIndex];
        require(c.reservedETH >= amount, "not reserved");
        c.reservedETH -= amount;
        if (!success) c.ethBalance += amount; // refund if failed
        emit PayPalSettlementConfirmedETH(cardIndex, amount, merchantAddress, success, c.cardNumber, block.timestamp);
    }

    /* ------------------- Uniswap Swap ------------------- */
    function swapExactInputSingle(uint256 cardIndex, address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMinimum) external onlyOwner returns (uint256 amountOut) {
        PaymentCard storage c = cards[cardIndex];
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp + 1 hours,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
        emit SwapExecuted(cardIndex, tokenIn, tokenOut, fee, amountIn, amountOut, address(this));
    }

    /* ------------------- Liquidation ------------------- */
    function liquidateCard(uint256 cardIndex) external onlyOwner {
        PaymentCard storage c = cards[cardIndex];
        uint256 debt = c.ethDebt;
        require(debt > 0, "no debt");
        uint256 collateral = c.ethBalance;
        if (collateral >= debt) { c.ethBalance -= debt; } else { c.ethBalance = 0; }
        c.ethDebt = 0;
        emit Liquidated(cardIndex, "ETH", debt, collateral);
    }

    /* ------------------- Receive ETH ------------------- */
    receive() external payable {
        emit ContractETHDeposited(msg.sender, msg.value, address(this).balance);
    }
}

