// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title CLOBMarket — On-Chain Central Limit Order Book
 * @notice Binary YES/NO prediction market with GUARANTEED payouts.
 *         Polymarket/Kalshi-style order book: bids & asks, partial fills,
 *         GTC/FOK/FAK order types, maker rebates, and complementary matching.
 *
 *  Core Model:
 *    - YES + NO shares. 1 winning share = exactly 1 ETH.
 *    - mint(): deposit N ETH → get N YES + N NO shares
 *    - burn(): burn N YES + N NO → get N ETH back
 *    - Shares are internal balances (not ERC-20)
 *
 *  Price Ticks: 1-99 (cents). 1¢ = 0.01 ETH per share.
 *
 *  Matching Engine:
 *    1. Direct matching: YES bid at P matches YES ask at ≤ P
 *    2. Complementary matching: YES bid at P matches NO bid at exactly (100-P)
 *       → auto-mints a complete set from combined collateral
 *    3. Unmatched remainder: GTC → rests on book. FOK → revert. FAK → refund.
 *
 *  Scalability / Gas:
 *    - Head-based FIFO queue: true time-priority, amortized O(1) skipping of tombstones
 *    - O(1) cancel: tombstone (shares=0) + per-level live counters (no array mutation)
 *    - Best price pointers use live counters (no scanning arrays for emptiness)
 *    - Optional compactBook() per level: rebuilds array, resets head to 0
 *
 *  Safety:
 *    - Pull-based withdrawals for all ETH flows (trades, rebates, cancels, resolution refunds)
 *    - Solvency invariant enforced before any ETH outflow
 */
import "./IVotingOracle.sol"; // Interface used by UMA resolver oracle (name kept for factory compat)

contract CLOBMarket {
    enum Outcome { UNRESOLVED, YES, NO, INVALID }
    enum OrderType { GTC, FOK, FAK }

    uint256 public constant MAX_PROTOCOL_FEE_BPS = 100; // 1% max
    uint256 public constant PRICE_PRECISION = 100;      // cents
    uint16  public constant MAX_ORDERS_PER_LEVEL = 500;
    uint256 public constant MAX_ORDERS_PER_USER = 200;
    uint256 public constant MIN_ORDER_SIZE = 1e14;      // 0.0001 ETH
    uint256 public constant MIN_SHARES = 1e15;          // 0.001 shares
    uint256 public constant MAX_FILLS_PER_ORDER = 50;
    uint256 internal constant AUTO_COMPACT_THRESHOLD = 200;
    uint256 internal constant AUTO_COMPACT_MAX_WORK = 300;

    // ── Market metadata ──
    uint256 public marketId;
    address public creator;
    address public resolver;
    string  public question;
    string  public categories;
    uint256 public endTime;
    uint256 public resolutionTime;
    uint256 public protocolFeeBps;
    uint256 public makerRebateBps;
    address public protocolFeeRecipient;
    bool    public isPrivate;

    Outcome public outcome;
    bool    public resolved;
    bool    public bettingClosed;  // hard freeze: no trading, no cancel, no burn

    // ── Share balances (1 winning share = 1 ETH) ──
    mapping(address => uint256) public yesShares;
    mapping(address => uint256) public noShares;
    mapping(address => uint256) public yesSharesEscrowed; // shares locked in resting sell orders
    mapping(address => uint256) public noSharesEscrowed;
    uint256 public totalYesShares;
    uint256 public totalNoShares;

    // ── Collateral pool (ETH backing all minted shares) ──
    uint256 public collateralPool;

    // ── Accumulated fees ──
    uint256 public accCreatorFees;
    uint256 public accProtocolFees;

    // ── Maker reward pool (share of protocol fees for market makers) ──
    uint256 public makerRewardBps;       // % of protocol cut → maker pool (bps)
    uint256 public accMakerRewards;      // ETH accumulated in maker reward pool
    mapping(address => uint256) public makerVolume;  // maker fill volume (shares)
    uint256 public totalMakerVolume;
    mapping(address => uint256) public claimedMakerRewards;

    // ── Resolver reward (UMA resolution oracle) ──
    address public resolverOracle;
    uint256 public resolverRewardBps;
    uint256 public accResolverRewards;

    // ── Order Book ──
    struct Order {
        uint64  id;
        address owner;
        uint96  shares;    // remaining shares (in wei)
        uint8   price;     // 1-99 cents
        bool    isBuy;     // true=bid, false=ask
        bool    isYesSide; // true=YES book, false=NO book
    }

    uint64 public nextOrderId;
    mapping(uint64 => Order) public orders;

    mapping(uint8 => uint64[]) public yesBids;
    mapping(uint8 => uint64[]) public yesAsks;
    mapping(uint8 => uint64[]) public noBids;
    mapping(uint8 => uint64[]) public noAsks;

    // Head pointers per price level
    mapping(uint8 => uint256) internal yesBidsHead;
    mapping(uint8 => uint256) internal yesAsksHead;
    mapping(uint8 => uint256) internal noBidsHead;
    mapping(uint8 => uint256) internal noAsksHead;

    // O(1) level emptiness via live counters (cap=100 so uint16 is enough)
    mapping(uint8 => uint16) internal yesBidsLive;
    mapping(uint8 => uint16) internal yesAsksLive;
    mapping(uint8 => uint16) internal noBidsLive;
    mapping(uint8 => uint16) internal noAsksLive;

    // Best price tracking
    uint8 public bestYesBid;  // highest YES bid (0 = none)
    uint8 public bestYesAsk;  // lowest  YES ask (100 = none)
    uint8 public bestNoBid;   // highest NO  bid
    uint8 public bestNoAsk;   // lowest  NO  ask

    // ── Pull-based withdrawals ──
    mapping(address => uint256) public pendingWithdrawal;
    uint256 public totalPendingWithdrawal;

    // ── Solvency tracking ──
    uint256 public totalBidCollateral;        // ETH locked for resting bids
    uint256 public totalClaimedMakerRewards;  // maker rewards paid out
    mapping(address => uint256) public activeOrderCount;

    // ── Reentrancy guard ──
    uint256 private _locked = 1;

    // ── Tracking ──
    mapping(address => bool) private isParticipant;
    address[] public participants;
    mapping(address => uint64[]) public userOrders;

    // ── Events ──
    event OrderPlaced(uint64 indexed orderId, address indexed owner, bool isYesSide, bool isBuy, uint8 price, uint256 shares);
    event OrderFilled(uint64 indexed takerOrderId, uint64 indexed makerOrderId, uint256 shares, uint8 price, bool isYesSide, bool takerIsBuy);
    event OrderCancelled(uint64 indexed orderId, address indexed owner, uint256 refundedShares);
    event SharesMinted(address indexed user, uint256 amount);
    event SharesBurned(address indexed user, uint256 amount);
    event MarketResolved(Outcome outcome, address resolvedBy);
    event SharesRedeemed(address indexed redeemer, uint256 amount);
    event FeesClaimed(address indexed to, uint256 amount, bool isCreator);
    event MakerRewardClaimed(address indexed maker, uint256 amount);
    event MakerRewardBpsUpdated(uint256 newBps);
    event Withdrawal(address indexed user, uint256 amount);
    event BookLevelCancelled(uint8 price, bool isYesSide, bool isBid, uint256 ordersCleared);

    modifier canResolve() {
        if (msg.sender == resolverOracle && resolverOracle != address(0)) {
            // UMA resolver oracle always authorized
        } else if (isPrivate) {
            require(msg.sender == creator || msg.sender == resolver, "NA");
        } else {
            require(msg.sender == resolver, "PR");
        }
        _;
    }

    modifier marketOpen() {
        require(!bettingClosed, "CL");
        require(block.timestamp < endTime, "MC");
        require(!resolved, "AR");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 1, "RE");
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        uint256 _marketId,
        address _creator,
        address _resolver,
        string memory _question,
        uint256 _endTime,
        uint256 _resolutionTime,
        uint256 _protocolFeeBps,
        address _protocolFeeRecipient,
        string memory _categories,
        bool _isPrivate,
        uint256 _makerRebateBps,
        uint256 _makerRewardBps
    ) {
        require(_protocolFeeBps <= MAX_PROTOCOL_FEE_BPS, "PF");
        require(_makerRebateBps <= 500, "RB");
        require(_makerRewardBps <= 5000, "MR");

        marketId = _marketId;
        creator = _creator;
        resolver = _resolver;
        question = _question;
        endTime = _endTime;
        resolutionTime = _resolutionTime;
        protocolFeeBps = _protocolFeeBps;
        makerRebateBps = _makerRebateBps;
        makerRewardBps = _makerRewardBps;
        protocolFeeRecipient = _protocolFeeRecipient;
        categories = _categories;
        isPrivate = _isPrivate;

        nextOrderId = 1;
        bestYesAsk = 100;
        bestNoAsk = 100;
    }

    // ═══════════════════════════════════════════
    //  MINT / BURN — Complete sets
    // ═══════════════════════════════════════════

    function mint() external payable marketOpen returns (uint256 amount) {
        require(msg.value > 0, "V0");
        amount = msg.value;

        yesShares[msg.sender] += amount;
        noShares[msg.sender] += amount;
        totalYesShares += amount;
        totalNoShares += amount;
        collateralPool += amount;

        _trackParticipant();
        emit SharesMinted(msg.sender, amount);
    }

    function burn(uint256 _amount) external nonReentrant returns (uint256 ethOut) {
        require(!bettingClosed, "CL");
        require(_amount > 0, "A0");
        require(yesShares[msg.sender] >= _amount, "IY");
        require(noShares[msg.sender] >= _amount, "IN");

        yesShares[msg.sender] -= _amount;
        noShares[msg.sender] -= _amount;
        totalYesShares -= _amount;
        totalNoShares -= _amount;
        collateralPool -= _amount;

        ethOut = _amount;

        _creditWithdrawal(msg.sender, ethOut);
        emit SharesBurned(msg.sender, _amount);
    }

    // ═══════════════════════════════════════════
    //  ORDER PLACEMENT
    // ═══════════════════════════════════════════

    function placeBuyOrder(
        bool _isYesSide,
        uint8 _price,
        uint256 _shares,
        OrderType _orderType
    ) external payable marketOpen nonReentrant returns (uint64 orderId) {
        require(_price >= 1 && _price <= 99, "P1");
        require(_shares >= MIN_SHARES, "SD");
        require(_shares <= type(uint96).max, "S96");
        require(_shares % PRICE_PRECISION == 0, "GRAN"); // shares must be multiple of 100 wei

        uint256 maxCost = (_shares * _price) / PRICE_PRECISION;
        require(maxCost >= MIN_ORDER_SIZE, "MS");

        uint256 takerFeeMax = (maxCost * (protocolFeeBps + makerRebateBps)) / 10000;
        require(msg.value >= maxCost + takerFeeMax, "IE");

        _trackParticipant();

        orderId = nextOrderId++;
        uint256 remaining = _shares;
        uint256 ethUsed = 0;
        uint256 fillsUsed = 0;

        if (_isYesSide) {
            (remaining, ethUsed, fillsUsed) = _matchBuyAgainstAsks(orderId, remaining, _price, true, fillsUsed);
            if (remaining > 0 && fillsUsed < MAX_FILLS_PER_ORDER) {
                (remaining, ethUsed, fillsUsed) = _matchBuyComplementary(orderId, remaining, _price, true, ethUsed, fillsUsed);
            }
        } else {
            (remaining, ethUsed, fillsUsed) = _matchBuyAgainstAsks(orderId, remaining, _price, false, fillsUsed);
            if (remaining > 0 && fillsUsed < MAX_FILLS_PER_ORDER) {
                (remaining, ethUsed, fillsUsed) = _matchBuyComplementary(orderId, remaining, _price, false, ethUsed, fillsUsed);
            }
        }

        if (_orderType == OrderType.FOK) {
            require(remaining == 0, "FK");
        } else if (_orderType == OrderType.GTC && remaining > 0) {
            require(activeOrderCount[msg.sender] < MAX_ORDERS_PER_USER, "UL");

            Order storage o = orders[orderId];
            o.id = orderId;
            o.owner = msg.sender;
            o.shares = uint96(remaining);
            o.price = _price;
            o.isBuy = true;
            o.isYesSide = _isYesSide;

            if (_isYesSide) {
                require(yesBidsLive[_price] < MAX_ORDERS_PER_LEVEL, "BF");
                yesBids[_price].push(orderId);
                yesBidsLive[_price] += 1;
                if (_price > bestYesBid) bestYesBid = _price;
            } else {
                require(noBidsLive[_price] < MAX_ORDERS_PER_LEVEL, "BF");
                noBids[_price].push(orderId);
                noBidsLive[_price] += 1;
                if (_price > bestNoBid) bestNoBid = _price;
            }

            userOrders[msg.sender].push(orderId);
            activeOrderCount[msg.sender]++;

            uint256 lockedEth = (remaining * _price) / PRICE_PRECISION;
            totalBidCollateral += lockedEth;
            ethUsed += lockedEth;

            emit OrderPlaced(orderId, msg.sender, _isYesSide, true, _price, remaining);
        }

        // refund any unused ETH (including FAK remainder / unspent fee buffer)
        uint256 refund = msg.value - ethUsed;
        if (refund > 0) {
            _creditWithdrawal(msg.sender, refund);
        }
    }

    function placeSellOrder(
        bool _isYesSide,
        uint8 _price,
        uint256 _shares,
        OrderType _orderType
    ) external marketOpen nonReentrant returns (uint64 orderId) {
        require(_price >= 1 && _price <= 99, "P1");
        require(_shares >= MIN_SHARES, "SD");
        require(_shares <= type(uint96).max, "S96");
        require(_shares % PRICE_PRECISION == 0, "GRAN"); // shares must be multiple of 100 wei

        uint256 orderValue = (_shares * _price) / PRICE_PRECISION;
        require(orderValue >= MIN_ORDER_SIZE, "MS");

        if (_isYesSide) {
            require(yesShares[msg.sender] >= _shares, "IY");
            yesShares[msg.sender] -= _shares;
        } else {
            require(noShares[msg.sender] >= _shares, "IN");
            noShares[msg.sender] -= _shares;
        }

        _trackParticipant();

        orderId = nextOrderId++;
        uint256 remaining = _shares;
        uint256 ethEarned = 0;

        (remaining, ethEarned) = _matchSellAgainstBids(orderId, remaining, _price, _isYesSide);

        if (_orderType == OrderType.FOK) {
            require(remaining == 0, "FK");
        } else if (_orderType == OrderType.GTC && remaining > 0) {
            require(activeOrderCount[msg.sender] < MAX_ORDERS_PER_USER, "UL");

            Order storage o = orders[orderId];
            o.id = orderId;
            o.owner = msg.sender;
            o.shares = uint96(remaining);
            o.price = _price;
            o.isBuy = false;
            o.isYesSide = _isYesSide;

            if (_isYesSide) {
                require(yesAsksLive[_price] < MAX_ORDERS_PER_LEVEL, "BF");
                yesAsks[_price].push(orderId);
                yesAsksLive[_price] += 1;
                if (_price < bestYesAsk) bestYesAsk = _price;
            } else {
                require(noAsksLive[_price] < MAX_ORDERS_PER_LEVEL, "BF");
                noAsks[_price].push(orderId);
                noAsksLive[_price] += 1;
                if (_price < bestNoAsk) bestNoAsk = _price;
            }

            userOrders[msg.sender].push(orderId);
            activeOrderCount[msg.sender]++;

            // Track escrowed shares for pull-based resolution
            if (_isYesSide) yesSharesEscrowed[msg.sender] += remaining;
            else noSharesEscrowed[msg.sender] += remaining;

            emit OrderPlaced(orderId, msg.sender, _isYesSide, false, _price, remaining);
        } else if (remaining > 0) {
            // FAK: return unfilled shares
            if (_isYesSide) yesShares[msg.sender] += remaining;
            else noShares[msg.sender] += remaining;
        }

        if (ethEarned > 0) _creditWithdrawal(msg.sender, ethEarned);
    }

    // O(1) cancel: tombstone shares=0 + counters; no array mutation; ETH refunds are pull-based
    // Allowed at any time — owners can always reclaim their own collateral/shares.
    function cancelOrder(uint64 _orderId) external {
        Order storage o = orders[_orderId];
        require(o.owner == msg.sender, "NY");
        require(o.shares > 0, "AF");

        uint256 remaining = uint256(o.shares);
        o.shares = 0;

        if (activeOrderCount[msg.sender] > 0) activeOrderCount[msg.sender]--;

        if (o.isBuy) {
            uint256 refund = (remaining * o.price) / PRICE_PRECISION;
            totalBidCollateral -= refund;
            _creditWithdrawal(msg.sender, refund);

            _decLiveAndMaybeUpdateBest(true, o.isYesSide, o.price);
        } else {
            _returnEscrowedShares(msg.sender, o.isYesSide, remaining);

            _decLiveAndMaybeUpdateBest(false, o.isYesSide, o.price);
        }

        emit OrderCancelled(_orderId, msg.sender, remaining);
    }

    // ═══════════════════════════════════════════
    //  MATCHING ENGINE
    // ═══════════════════════════════════════════

    function _matchBuyAgainstAsks(
        uint64 _takerOrderId,
        uint256 _remaining,
        uint8 _maxPrice,
        bool _isYesSide,
        uint256 _fillsUsed
    ) internal returns (uint256 remaining, uint256 ethUsed, uint256 fillsUsed) {
        remaining = _remaining;
        ethUsed = 0;
        fillsUsed = _fillsUsed;

        uint8 askPrice = _isYesSide ? bestYesAsk : bestNoAsk;

        while (remaining > 0 && askPrice <= _maxPrice && askPrice < 100 && fillsUsed < MAX_FILLS_PER_ORDER) {
            if (_getLive(false, _isYesSide, askPrice) == 0) {
                askPrice = _nextAskPrice(_isYesSide, askPrice);
                continue;
            }

            uint64[] storage book = _isYesSide ? yesAsks[askPrice] : noAsks[askPrice];
            uint256 i = _getHead(false, _isYesSide, askPrice);
            i = _skipZeros(book, i);

            while (i < book.length && remaining > 0 && fillsUsed < MAX_FILLS_PER_ORDER) {
                Order storage maker = orders[book[i]];
                if (maker.shares == 0) { i++; continue; }

                uint256 makerShares = uint256(maker.shares);
                uint256 fillQty = remaining < makerShares ? remaining : makerShares;

                uint256 fillCost = (fillQty * askPrice) / PRICE_PRECISION;
                uint256 takerFee = (fillCost * protocolFeeBps) / 10000;
                uint256 makerRebate = (fillCost * makerRebateBps) / 10000;

                ethUsed += fillCost + takerFee + makerRebate;
                _accumulateProtocolFee(takerFee);

                // maker proceeds (incl rebate)
                _creditWithdrawal(maker.owner, fillCost + makerRebate);

                // shares to buyer
                if (_isYesSide) yesShares[msg.sender] += fillQty;
                else noShares[msg.sender] += fillQty;

                maker.shares = uint96(makerShares - fillQty);
                remaining -= fillQty;

                // Decrement maker's escrowed shares (ask filled)
                if (_isYesSide) yesSharesEscrowed[maker.owner] -= fillQty;
                else noSharesEscrowed[maker.owner] -= fillQty;

                _trackMakerVolume(maker.owner, fillQty);
                emit OrderFilled(_takerOrderId, maker.id, fillQty, askPrice, _isYesSide, true);

                fillsUsed++;

                // IMPORTANT: only advance index if maker fully consumed (preserves FIFO on partial fills)
                if (maker.shares == 0) {
                    if (activeOrderCount[maker.owner] > 0) activeOrderCount[maker.owner]--;
                    _decLive(false, _isYesSide, askPrice);
                    i++;
                } else {
                    // maker still has shares; keep i here (if remaining==0 loop ends)
                }
            }

            i = _skipZeros(book, i);
            _setHead(false, _isYesSide, askPrice, i);

            if (_getLive(false, _isYesSide, askPrice) == 0) {
                _deleteBook(false, _isYesSide, askPrice);
                askPrice = _nextAskPrice(_isYesSide, askPrice);
            } else {
                if (i >= AUTO_COMPACT_THRESHOLD && book.length <= i + AUTO_COMPACT_MAX_WORK)
                    _autoCompact(book, false, _isYesSide, askPrice);
                break;
            }
        }

        if (_isYesSide) bestYesAsk = askPrice;
        else bestNoAsk = askPrice;
    }

    function _matchBuyComplementary(
        uint64 _takerOrderId,
        uint256 _remaining,
        uint8 _takerPrice,
        bool _takerIsYes,
        uint256 _ethUsed,
        uint256 _fillsUsed
    ) internal returns (uint256 remaining, uint256 ethUsed, uint256 fillsUsed) {
        remaining = _remaining;
        ethUsed = _ethUsed;
        fillsUsed = _fillsUsed;

        uint8 compPrice = uint8(PRICE_PRECISION - _takerPrice);
        if (compPrice < 1 || compPrice > 99) return (remaining, ethUsed, fillsUsed);

        // Complementary book is bids on the opposite side at compPrice
        bool makerIsYesBidBook = !_takerIsYes;
        if (_getLive(true, makerIsYesBidBook, compPrice) == 0) return (remaining, ethUsed, fillsUsed);

        uint64[] storage book = _takerIsYes ? noBids[compPrice] : yesBids[compPrice];
        uint256 i = _getHead(true, makerIsYesBidBook, compPrice);
        i = _skipZeros(book, i);

        while (i < book.length && remaining > 0 && fillsUsed < MAX_FILLS_PER_ORDER) {
            Order storage maker = orders[book[i]];
            if (maker.shares == 0) { i++; continue; }

            uint256 makerShares = uint256(maker.shares);
            uint256 fillQty = remaining < makerShares ? remaining : makerShares;

            uint256 takerCost = (fillQty * _takerPrice) / PRICE_PRECISION;
            uint256 makerLocked = (fillQty * compPrice) / PRICE_PRECISION;
            require(takerCost + makerLocked == fillQty, "MINT_ARITH");

            uint256 takerFee = (takerCost * protocolFeeBps) / 10000;
            uint256 makerRebate = (takerCost * makerRebateBps) / 10000;

            ethUsed += takerCost + takerFee + makerRebate;
            _accumulateProtocolFee(takerFee);

            // release maker bid collateral tracking
            totalBidCollateral -= makerLocked;

            // mint complete set into system collateral
            collateralPool += fillQty;
            totalYesShares += fillQty;
            totalNoShares += fillQty;

            // taker gets requested side, maker gets the other
            if (_takerIsYes) {
                yesShares[msg.sender] += fillQty;
                noShares[maker.owner] += fillQty;
            } else {
                noShares[msg.sender] += fillQty;
                yesShares[maker.owner] += fillQty;
            }

            if (makerRebate > 0) _creditWithdrawal(maker.owner, makerRebate);

            maker.shares = uint96(makerShares - fillQty);
            remaining -= fillQty;

            _trackMakerVolume(maker.owner, fillQty);
            emit OrderFilled(_takerOrderId, maker.id, fillQty, _takerPrice, _takerIsYes, true);

            fillsUsed++;

            if (maker.shares == 0) {
                if (activeOrderCount[maker.owner] > 0) activeOrderCount[maker.owner]--;
                _decLive(true, makerIsYesBidBook, compPrice);
                i++;
            }
        }

        i = _skipZeros(book, i);
        _setHead(true, makerIsYesBidBook, compPrice, i);

        // If complementary level drained, update best bid for that book
        if (_getLive(true, makerIsYesBidBook, compPrice) == 0) {
            _deleteBook(true, makerIsYesBidBook, compPrice);

            if (_takerIsYes) bestNoBid = _prevBidPrice(false, compPrice); // NO bids book
            else bestYesBid = _prevBidPrice(true, compPrice);            // YES bids book
        } else if (i >= AUTO_COMPACT_THRESHOLD && book.length <= i + AUTO_COMPACT_MAX_WORK) {
            _autoCompact(book, true, makerIsYesBidBook, compPrice);
        }

        return (remaining, ethUsed, fillsUsed);
    }

    function _matchSellAgainstBids(
        uint64 _takerOrderId,
        uint256 _remaining,
        uint8 _minPrice,
        bool _isYesSide
    ) internal returns (uint256 remaining, uint256 ethEarned) {
        remaining = _remaining;
        ethEarned = 0;

        uint256 fillCount = 0;
        uint8 bidPrice = _isYesSide ? bestYesBid : bestNoBid;

        while (remaining > 0 && bidPrice >= _minPrice && bidPrice >= 1 && fillCount < MAX_FILLS_PER_ORDER) {
            if (_getLive(true, _isYesSide, bidPrice) == 0) {
                bidPrice = _prevBidPrice(_isYesSide, bidPrice);
                continue;
            }

            uint64[] storage book = _isYesSide ? yesBids[bidPrice] : noBids[bidPrice];
            uint256 i = _getHead(true, _isYesSide, bidPrice);
            i = _skipZeros(book, i);

            while (i < book.length && remaining > 0 && fillCount < MAX_FILLS_PER_ORDER) {
                Order storage maker = orders[book[i]];
                if (maker.shares == 0) { i++; continue; }

                uint256 makerShares = uint256(maker.shares);
                uint256 fillQty = remaining < makerShares ? remaining : makerShares;
                uint256 fillValue = (fillQty * bidPrice) / PRICE_PRECISION;

                uint256 takerFee = (fillValue * protocolFeeBps) / 10000;
                uint256 makerRebate = (fillValue * makerRebateBps) / 10000;

                ethEarned += fillValue - takerFee - makerRebate;
                _accumulateProtocolFee(takerFee);

                // release maker bid collateral tracking
                totalBidCollateral -= fillValue;

                // maker receives shares they bid for
                if (_isYesSide) yesShares[maker.owner] += fillQty;
                else noShares[maker.owner] += fillQty;

                if (makerRebate > 0) _creditWithdrawal(maker.owner, makerRebate);

                maker.shares = uint96(makerShares - fillQty);
                remaining -= fillQty;

                _trackMakerVolume(maker.owner, fillQty);
                emit OrderFilled(_takerOrderId, maker.id, fillQty, bidPrice, _isYesSide, false);

                fillCount++;

                // FIFO correctness: only advance if maker fully consumed
                if (maker.shares == 0) {
                    if (activeOrderCount[maker.owner] > 0) activeOrderCount[maker.owner]--;
                    _decLive(true, _isYesSide, bidPrice);
                    i++;
                }
            }

            i = _skipZeros(book, i);
            _setHead(true, _isYesSide, bidPrice, i);

            if (_getLive(true, _isYesSide, bidPrice) == 0) {
                _deleteBook(true, _isYesSide, bidPrice);
                bidPrice = _prevBidPrice(_isYesSide, bidPrice);
            } else {
                if (i >= AUTO_COMPACT_THRESHOLD && book.length <= i + AUTO_COMPACT_MAX_WORK)
                    _autoCompact(book, true, _isYesSide, bidPrice);
                break;
            }
        }

        if (_isYesSide) bestYesBid = bidPrice;
        else bestNoBid = bidPrice;
    }

    // ═══════════════════════════════════════════
    //  BOOK MAINTENANCE
    // ═══════════════════════════════════════════

    // Public compaction for a single level: rebuild array from head, keep only live orders, reset head=0.
    function compactBook(uint8 _price, bool _isYesSide, bool _isBid) external {
        require(_price >= 1 && _price <= 99, "P1");

        uint64[] storage book = _isBid
            ? (_isYesSide ? yesBids[_price] : noBids[_price])
            : (_isYesSide ? yesAsks[_price] : noAsks[_price]);

        uint256 head = _getHead(_isBid, _isYesSide, _price);
        uint256 w = 0;

        for (uint256 r = head; r < book.length; r++) {
            if (orders[book[r]].shares > 0) {
                book[w] = book[r];
                w++;
            }
        }
        // Trim tombstones from tail after compaction
        while (book.length > w) book.pop();

        _setHead(_isBid, _isYesSide, _price, 0);

        // If live count says empty, delete entire level for storage hygiene.
        if (_getLive(_isBid, _isYesSide, _price) == 0) {
            _deleteBook(_isBid, _isYesSide, _price);
        }
    }

    // ═══════════════════════════════════════════
    //  FEE MANAGEMENT
    // ═══════════════════════════════════════════

    function _accumulateProtocolFee(uint256 _fee) internal {
        if (_fee == 0) return;

        uint256 creatorCut = (_fee * 60) / 100;
        uint256 protocolCut = _fee - creatorCut;

        uint256 makerRewardCut = (protocolCut * makerRewardBps) / 10000;
        uint256 resolverCut = (protocolCut * resolverRewardBps) / 10000;
        uint256 subCuts = makerRewardCut + resolverCut;

        accCreatorFees += creatorCut;
        accMakerRewards += makerRewardCut;
        accResolverRewards += resolverCut;
        accProtocolFees += (protocolCut - subCuts);
    }

    function _trackMakerVolume(address _maker, uint256 _fillQty) internal {
        makerVolume[_maker] += _fillQty;
        totalMakerVolume += _fillQty;
    }

    function claimCreatorFees() external {
        require(msg.sender == creator, "NC");
        uint256 amount = accCreatorFees;
        require(amount > 0, "NF");
        accCreatorFees = 0;
        _creditWithdrawal(creator, amount);
        emit FeesClaimed(creator, amount, true);
    }

    function claimProtocolFees() external {
        require(msg.sender == protocolFeeRecipient || msg.sender == resolver, "NA");
        uint256 amount = accProtocolFees;
        require(amount > 0, "NF");
        accProtocolFees = 0;
        _creditWithdrawal(protocolFeeRecipient, amount);
        emit FeesClaimed(protocolFeeRecipient, amount, false);
    }

    function claimResolverRewards() external nonReentrant {
        require(resolverOracle != address(0), "NV");
        uint256 amt = accResolverRewards;
        require(amt > 0, "NR");
        accResolverRewards = 0;
        _ensureSolvent();
        try IVotingOracle(resolverOracle).depositVoterReward{value: amt}(marketId) {
            // success -- ETH sent to oracle
        } catch {
            // Oracle reverted -- credit to protocol fee recipient as fallback
            _creditWithdrawal(protocolFeeRecipient, amt);
        }
    }

    function closeBetting() external nonReentrant {
        require(block.timestamp >= endTime, "MO");
        require(!resolved, "AR");
        bettingClosed = true;
        if (resolverOracle != address(0) && accResolverRewards > 0) {
            uint256 amt = accResolverRewards;
            accResolverRewards = 0;
            _ensureSolvent();
            try IVotingOracle(resolverOracle).depositVoterReward{value: amt}(marketId) {
                // success
            } catch {
                // Oracle reverted -- credit to protocol fee recipient
                _creditWithdrawal(protocolFeeRecipient, amt);
            }
        }
    }

    // Name kept for factory compatibility
    function setVotingConfig(address _votingContract, uint256 _voterRewardBps) external {
        if (resolverOracle != address(0)) {
            require(msg.sender == resolver || msg.sender == creator, "NA");
        }
        require(_voterRewardBps <= 5000, "VC");
        require(_voterRewardBps + makerRewardBps <= 10000, "TH");
        resolverOracle = _votingContract;
        resolverRewardBps = _voterRewardBps;
    }

    function claimMakerRewards() external nonReentrant {
        require(makerVolume[msg.sender] > 0, "NM");
        require(totalMakerVolume > 0, "NL");

        uint256 totalShare = (accMakerRewards * makerVolume[msg.sender]) / totalMakerVolume;
        uint256 claimable = totalShare > claimedMakerRewards[msg.sender]
            ? totalShare - claimedMakerRewards[msg.sender]
            : 0;

        // Cap so total claimed never exceeds total accumulated (prevents overclaim insolvency)
        uint256 maxClaimable = accMakerRewards > totalClaimedMakerRewards
            ? accMakerRewards - totalClaimedMakerRewards
            : 0;
        if (claimable > maxClaimable) claimable = maxClaimable;

        require(claimable > 0, "N0");

        claimedMakerRewards[msg.sender] += claimable;
        totalClaimedMakerRewards += claimable;

        _creditWithdrawal(msg.sender, claimable);
        emit MakerRewardClaimed(msg.sender, claimable);
    }

    function setMakerRewardBps(uint256 _bps) external {
        require(msg.sender == resolver || msg.sender == protocolFeeRecipient, "NA");
        require(_bps + resolverRewardBps <= 10000, "MP");
        makerRewardBps = _bps;
        emit MakerRewardBpsUpdated(_bps);
    }

    // ═══════════════════════════════════════════
    //  WITHDRAWALS
    // ═══════════════════════════════════════════

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawal[msg.sender];
        require(amount > 0, "NP");
        pendingWithdrawal[msg.sender] = 0;
        totalPendingWithdrawal -= amount;
        _ensureSolvent();
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "TF");
        emit Withdrawal(msg.sender, amount);
    }

    // ═══════════════════════════════════════════
    //  RESOLUTION & REDEMPTION
    // ═══════════════════════════════════════════

    function resolve(Outcome _outcome) external canResolve {
        require(!resolved, "AR");
        require(block.timestamp >= endTime, "MO");
        require(_outcome == Outcome.YES || _outcome == Outcome.NO || _outcome == Outcome.INVALID, "IO");

        outcome = _outcome;
        resolved = true;
        bettingClosed = true;

        bestYesBid = 0;
        bestNoBid = 0;
        bestYesAsk = 100;
        bestNoAsk = 100;

        emit MarketResolved(_outcome, msg.sender);
    }

    /**
     * @notice Emergency resolve — forces INVALID outcome.
     *         Only works when the oracle confirms emergency conditions:
     *         (a) Assertion was disputed and UMA DVM hasn't returned in 3 days, OR
     *         (b) UMA DVM returned false (assertion rejected).
     *         Callable by resolver or resolver oracle.
     */
    function emergencyResolve() external {
        require(!resolved, "AR");
        require(
            resolverOracle != address(0) &&
            IVotingOracle(resolverOracle).canEmergencyResolve(marketId),
            "ER"
        );
        require(
            msg.sender == resolver ||
            (resolverOracle != address(0) && msg.sender == resolverOracle),
            "NA"
        );

        outcome = Outcome.INVALID;
        resolved = true;
        bettingClosed = true;

        bestYesBid = 0;
        bestNoBid = 0;
        bestYesAsk = 100;
        bestNoAsk = 100;

        emit MarketResolved(Outcome.INVALID, msg.sender);
    }

    function cancelBookAtPrice(uint8 _price, bool _isYesSide, bool _isBid) external {
        require(resolved, "NR");
        require(_price >= 1 && _price <= 99, "P1");

        uint16 live = _getLive(_isBid, _isYesSide, _price);
        if (live == 0) return;

        uint64[] storage book = _isBid
            ? (_isYesSide ? yesBids[_price] : noBids[_price])
            : (_isYesSide ? yesAsks[_price] : noAsks[_price]);

        uint256 cleared = 0;
        uint256 idx = _getHead(_isBid, _isYesSide, _price);

        // Walk from head, stop after processing all live orders
        while (idx < book.length && cleared < live) {
            Order storage o = orders[book[idx]];
            idx++;
            if (o.shares == 0) continue;

            uint256 rem = uint256(o.shares);
            o.shares = 0;
            cleared++;

            if (activeOrderCount[o.owner] > 0) activeOrderCount[o.owner]--;

            if (_isBid) {
                uint256 refund = (rem * o.price) / PRICE_PRECISION;
                totalBidCollateral -= refund;
                _creditWithdrawal(o.owner, refund);
            } else {
                _returnEscrowedShares(o.owner, _isYesSide, rem);
            }
        }

        require(cleared == live, "INCOMPLETE");
        _deleteBook(_isBid, _isYesSide, _price);

        emit BookLevelCancelled(_price, _isYesSide, _isBid, cleared);
    }

    function cancelMyOrders(uint256 _startIdx, uint256 _maxBatch) external returns (uint256 nextIdx) {
        require(resolved, "NR");
        uint64[] storage ords = userOrders[msg.sender];
        uint256 end = _startIdx + _maxBatch;
        if (end > ords.length) end = ords.length;

        for (uint256 i = _startIdx; i < end; i++) {
            Order storage o = orders[ords[i]];
            if (o.shares == 0) continue;

            uint256 rem = uint256(o.shares);
            o.shares = 0;

            if (activeOrderCount[msg.sender] > 0) activeOrderCount[msg.sender]--;

            if (o.isBuy) {
                uint256 refund = (rem * o.price) / PRICE_PRECISION;
                totalBidCollateral -= refund;
                _creditWithdrawal(msg.sender, refund);
                _decLive(true, o.isYesSide, o.price);
            } else {
                _returnEscrowedShares(msg.sender, o.isYesSide, rem);
                _decLive(false, o.isYesSide, o.price);
            }
        }
        nextIdx = end;
        // best pointers already reset to 0/100 on resolve(); no update needed
    }

    function redeem() external nonReentrant {
        require(resolved, "NR");

        // Reclaim shares escrowed in open sell orders
        uint256 escY = yesSharesEscrowed[msg.sender];
        uint256 escN = noSharesEscrowed[msg.sender];
        if (escY > 0) {
            yesShares[msg.sender] += escY;
            yesSharesEscrowed[msg.sender] = 0;
        }
        if (escN > 0) {
            noShares[msg.sender] += escN;
            noSharesEscrowed[msg.sender] = 0;
        }

        uint256 payout = 0;

        if (outcome == Outcome.INVALID) {
            uint256 userShares = yesShares[msg.sender] + noShares[msg.sender];
            require(userShares > 0, "N1");
            uint256 totalShares = totalYesShares + totalNoShares;
            if (totalShares > 0) payout = (userShares * collateralPool) / totalShares;

            collateralPool -= payout;
            totalYesShares -= yesShares[msg.sender];
            totalNoShares -= noShares[msg.sender];
            yesShares[msg.sender] = 0;
            noShares[msg.sender] = 0;
        } else if (outcome == Outcome.YES) {
            uint256 shares = yesShares[msg.sender];
            require(shares > 0, "NW");
            payout = shares;
            collateralPool -= shares;
            totalYesShares -= shares;
            yesShares[msg.sender] = 0;
        } else {
            uint256 shares = noShares[msg.sender];
            require(shares > 0, "NW");
            payout = shares;
            collateralPool -= shares;
            totalNoShares -= shares;
            noShares[msg.sender] = 0;
        }

        if (payout > 0) {
            _creditWithdrawal(msg.sender, payout);
        }
        emit SharesRedeemed(msg.sender, payout);
    }

    // ═══════════════════════════════════════════
    //  VIEW FUNCTIONS (unchanged behavior)
    // ═══════════════════════════════════════════

    function yesPrice() public view returns (uint256) {
        if (bestYesAsk < 100 && bestYesBid > 0) {
            return (uint256(bestYesBid) + uint256(bestYesAsk)) * 50;
        } else if (bestYesAsk < 100) {
            return uint256(bestYesAsk) * 100;
        } else if (bestYesBid > 0) {
            return uint256(bestYesBid) * 100;
        }
        return 5000;
    }

    function noPrice() public view returns (uint256) {
        return 10000 - yesPrice();
    }

    function getOdds() external view returns (uint256 yesOdds, uint256 noOdds) {
        return (yesPrice(), noPrice());
    }

    function getMarketInfo() external view returns (
        string memory _question, uint256 _endTime,
        uint256 _totalYesShares, uint256 _totalNoShares,
        uint256 _collateralPool, uint256 _contractBalance,
        Outcome _outcome, bool _resolved, address _creator
    ) {
        return (question, endTime, totalYesShares, totalNoShares,
                collateralPool, address(this).balance, outcome, resolved, creator);
    }

    function getPosition(address _user) external view returns (uint256 yes, uint256 no) {
        return (yesShares[_user], noShares[_user]);
    }

    function getOrderBookSide(
        bool _isYesSide,
        bool _isBid,
        uint8 _fromPrice,
        uint8 _toPrice
    ) external view returns (uint64[] memory ids, address[] memory owners, uint96[] memory shares, uint8[] memory prices) {
        uint256 count = 0;
        for (uint8 p = _fromPrice; p <= _toPrice && p < 100; p++) {
            uint64[] storage book = _isBid
                ? (_isYesSide ? yesBids[p] : noBids[p])
                : (_isYesSide ? yesAsks[p] : noAsks[p]);
            for (uint256 i = 0; i < book.length; i++) {
                if (orders[book[i]].shares > 0) count++;
            }
        }

        ids = new uint64[](count);
        owners = new address[](count);
        shares = new uint96[](count);
        prices = new uint8[](count);

        uint256 idx = 0;
        for (uint8 p = _fromPrice; p <= _toPrice && p < 100; p++) {
            uint64[] storage book = _isBid
                ? (_isYesSide ? yesBids[p] : noBids[p])
                : (_isYesSide ? yesAsks[p] : noAsks[p]);
            for (uint256 i = 0; i < book.length; i++) {
                Order storage o = orders[book[i]];
                if (o.shares > 0) {
                    ids[idx] = o.id;
                    owners[idx] = o.owner;
                    shares[idx] = o.shares;
                    prices[idx] = o.price;
                    idx++;
                }
            }
        }
    }

    function getUserOrders(address _user) external view returns (
        uint64[] memory ids, uint96[] memory sharesArr, uint8[] memory pricesArr,
        bool[] memory isBuys, bool[] memory isYesSides
    ) {
        uint64[] storage all = userOrders[_user];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) if (orders[all[i]].shares > 0) count++;

        ids = new uint64[](count);
        sharesArr = new uint96[](count);
        pricesArr = new uint8[](count);
        isBuys = new bool[](count);
        isYesSides = new bool[](count);

        uint256 idx = 0;
        for (uint256 i = 0; i < all.length; i++) {
            Order storage o = orders[all[i]];
            if (o.shares > 0) {
                ids[idx] = o.id;
                sharesArr[idx] = o.shares;
                pricesArr[idx] = o.price;
                isBuys[idx] = o.isBuy;
                isYesSides[idx] = o.isYesSide;
                idx++;
            }
        }
    }

    function getBookSummary() external view returns (
        uint8 _bestYesBid, uint8 _bestYesAsk,
        uint8 _bestNoBid, uint8 _bestNoAsk,
        uint256 yesBidDepth, uint256 yesAskDepth,
        uint256 noBidDepth, uint256 noAskDepth
    ) {
        _bestYesBid = bestYesBid;
        _bestYesAsk = bestYesAsk;
        _bestNoBid = bestNoBid;
        _bestNoAsk = bestNoAsk;

        for (uint8 p = 1; p < 100; p++) {
            for (uint256 i = 0; i < yesBids[p].length; i++)
                if (orders[yesBids[p][i]].shares > 0) yesBidDepth += uint256(orders[yesBids[p][i]].shares);
            for (uint256 i = 0; i < yesAsks[p].length; i++)
                if (orders[yesAsks[p][i]].shares > 0) yesAskDepth += uint256(orders[yesAsks[p][i]].shares);
            for (uint256 i = 0; i < noBids[p].length; i++)
                if (orders[noBids[p][i]].shares > 0) noBidDepth += uint256(orders[noBids[p][i]].shares);
            for (uint256 i = 0; i < noAsks[p].length; i++)
                if (orders[noAsks[p][i]].shares > 0) noAskDepth += uint256(orders[noAsks[p][i]].shares);
        }
    }

    function getFeeInfo() external view returns (
        uint256 _protocolFeeBps, uint256 _makerRebateBps,
        uint256 _accCreatorFees, uint256 _accProtocolFees,
        uint256 _maxProtocolFeeBps,
        uint256 _makerRewardBps, uint256 _accMakerRewards, uint256 _totalMakerVolume
    ) {
        return (protocolFeeBps, makerRebateBps, accCreatorFees, accProtocolFees, MAX_PROTOCOL_FEE_BPS,
                makerRewardBps, accMakerRewards, totalMakerVolume);
    }

    function getMakerRewardInfo(address _maker) external view returns (
        uint256 volume, uint256 totalVol, uint256 poolBalance,
        uint256 earned, uint256 claimed, uint256 claimable
    ) {
        volume = makerVolume[_maker];
        totalVol = totalMakerVolume;
        poolBalance = accMakerRewards;
        if (totalVol > 0 && volume > 0) {
            earned = (poolBalance * volume) / totalVol;
            claimed = claimedMakerRewards[_maker];
            claimable = earned > claimed ? earned - claimed : 0;
        }
    }

    function getParticipantCount() external view returns (uint256) { return participants.length; }

    function getSolvencyInfo() external view returns (
        uint256 balance, uint256 obligations,
        uint256 _collateralPool, uint256 _totalBidCollateral,
        uint256 _totalPendingWithdrawal, uint256 _accCreatorFees,
        uint256 _accProtocolFees, uint256 unclaimedMakerRewards,
        uint256 _accResolverRewards, bool solvent
    ) {
        balance = address(this).balance;
        obligations = totalObligations();
        _collateralPool = collateralPool;
        _totalBidCollateral = totalBidCollateral;
        _totalPendingWithdrawal = totalPendingWithdrawal;
        _accCreatorFees = accCreatorFees;
        _accProtocolFees = accProtocolFees;
        unclaimedMakerRewards = accMakerRewards > totalClaimedMakerRewards
            ? accMakerRewards - totalClaimedMakerRewards : 0;
        _accResolverRewards = accResolverRewards;
        solvent = balance >= obligations;
    }

    function checkCollateralInvariant() external view returns (bool yesOk, bool noOk) {
        yesOk = (totalYesShares == collateralPool);
        noOk = (totalNoShares == collateralPool);
    }

    // ═══════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════

    function _trackParticipant() internal {
        if (!isParticipant[msg.sender]) {
            participants.push(msg.sender);
            isParticipant[msg.sender] = true;
        }
    }

    function _creditWithdrawal(address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        pendingWithdrawal[_to] += _amount;
        totalPendingWithdrawal += _amount;
    }

    /// @dev Return escrowed shares on cancel; safe against double-return after redeem.
    function _returnEscrowedShares(address _user, bool _isYesSide, uint256 _amount) internal {
        if (_isYesSide) {
            uint256 esc = yesSharesEscrowed[_user];
            uint256 ret = _amount < esc ? _amount : esc;
            yesSharesEscrowed[_user] -= ret;
            yesShares[_user] += ret;
        } else {
            uint256 esc = noSharesEscrowed[_user];
            uint256 ret = _amount < esc ? _amount : esc;
            noSharesEscrowed[_user] -= ret;
            noShares[_user] += ret;
        }
    }

    function totalObligations() public view returns (uint256) {
        uint256 unclaimedMaker = accMakerRewards > totalClaimedMakerRewards
            ? accMakerRewards - totalClaimedMakerRewards : 0;
        return collateralPool + totalBidCollateral + totalPendingWithdrawal
             + accCreatorFees + accProtocolFees + unclaimedMaker + accResolverRewards;
    }

    function _ensureSolvent() internal view {
        require(address(this).balance >= totalObligations(), "ISV");
    }

    function _skipZeros(uint64[] storage book, uint256 i) internal view returns (uint256) {
        while (i < book.length && orders[book[i]].shares == 0) i++;
        return i;
    }

    function _getHead(bool isBid, bool isYes, uint8 price) internal view returns (uint256) {
        if (isBid) return isYes ? yesBidsHead[price] : noBidsHead[price];
        return isYes ? yesAsksHead[price] : noAsksHead[price];
    }

    function _setHead(bool isBid, bool isYes, uint8 price, uint256 h) internal {
        if (isBid) {
            if (isYes) yesBidsHead[price] = h;
            else noBidsHead[price] = h;
        } else {
            if (isYes) yesAsksHead[price] = h;
            else noAsksHead[price] = h;
        }
    }

    /// @dev Delete the entire array at mapping[price] in O(1), reset head and live counter.
    function _deleteBook(bool isBid, bool isYes, uint8 price) internal {
        if (isBid) {
            if (isYes) {
                delete yesBids[price];
                yesBidsHead[price] = 0;
                yesBidsLive[price] = 0;
            } else {
                delete noBids[price];
                noBidsHead[price] = 0;
                noBidsLive[price] = 0;
            }
        } else {
            if (isYes) {
                delete yesAsks[price];
                yesAsksHead[price] = 0;
                yesAsksLive[price] = 0;
            } else {
                delete noAsks[price];
                noAsksHead[price] = 0;
                noAsksLive[price] = 0;
            }
        }
    }

    /// @dev Compact a price level: rewrite live orders to front, trim tail, reset head.
    function _autoCompact(uint64[] storage book, bool isBid, bool isYes, uint8 price) internal {
        uint256 head = _getHead(isBid, isYes, price);
        uint256 w = 0;
        for (uint256 r = head; r < book.length; r++) {
            if (orders[book[r]].shares > 0) {
                book[w] = book[r];
                w++;
            }
        }
        while (book.length > w) book.pop();
        _setHead(isBid, isYes, price, 0);
    }

    function _getLive(bool isBid, bool isYes, uint8 price) internal view returns (uint16) {
        if (isBid) return isYes ? yesBidsLive[price] : noBidsLive[price];
        return isYes ? yesAsksLive[price] : noAsksLive[price];
    }

    function _decLive(bool isBid, bool isYes, uint8 price) internal {
        if (isBid) {
            if (isYes) yesBidsLive[price] -= 1;
            else noBidsLive[price] -= 1;
        } else {
            if (isYes) yesAsksLive[price] -= 1;
            else noAsksLive[price] -= 1;
        }
    }

    function _decLiveAndMaybeUpdateBest(bool isBid, bool isYes, uint8 price) internal {
        _decLive(isBid, isYes, price);
        if (_getLive(isBid, isYes, price) != 0) return;

        // If that was the best level, move best pointer.
        if (isBid) {
            if (isYes && price == bestYesBid) bestYesBid = _prevBidPrice(true, price);
            else if (!isYes && price == bestNoBid) bestNoBid = _prevBidPrice(false, price);
        } else {
            if (isYes && price == bestYesAsk) bestYesAsk = _nextAskPrice(true, price);
            else if (!isYes && price == bestNoAsk) bestNoAsk = _nextAskPrice(false, price);
        }
    }

    function _nextAskPrice(bool isYes, uint8 from) internal view returns (uint8) {
        uint8 p = from;
        if (p < 99) p++;
        else return 100;

        while (p < 100) {
            if (_getLive(false, isYes, p) > 0) return p;
            if (p == 99) break;
            p++;
        }
        return 100;
    }

    function _prevBidPrice(bool isYes, uint8 from) internal view returns (uint8) {
        uint8 p = from;
        if (p > 1) p--;
        else return 0;

        while (p >= 1) {
            if (_getLive(true, isYes, p) > 0) return p;
            if (p == 1) break;
            p--;
        }
        return 0;
    }

    receive() external payable {}
}