// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./CTFDeployer.sol";
import "./MultiChoiceMarketDeployer.sol";
import "./ParimutuelDeployer.sol";
import "./CLOBDeployer.sol";
import "./ArenaDeployer.sol";

/// @dev Interface for configuring resolution-reward routing on deployed markets
interface IRewardConfigurable {
    function setVotingConfig(address _votingContract, uint256 _voterRewardBps) external;
}

/// @dev Minimal interface for UMA resolution oracle
interface IUMAResolutionOracle {
    function registerMarket(uint256 _marketId, address _marketAddress, uint8 _marketType, string calldata _question) external;
}

/**
 * @title ClawshiFactory
 * @notice Factory that deploys all Clawshi prediction market types.
 *
 *  Market types:
 *    0 = CTF        — Binary YES/NO (FPMM token-set AMM, drain-proof)
 *    1 = MULTI_CTF  — N-option    (FPMM token-set AMM, drain-proof)
 *    2 = PARIMUTUEL — Pot-split   (no AMM, 1-winner-takes-all payout)
 *    3 = CLOB       — Order book  (binary — multi-CLOB = N binary CLOBs grouped)
 *    4 = ARENA      — Elimination prediction market (internal AMM, reaping)
 *
 *  The owner address doubles as the default AI resolver for all markets.
 *  UMA Optimistic Oracle handles decentralized resolution via bonded assertions.
 *
 *  Fee split (1% base fee, all types):
 *    Creator  60%  |  Protocol  35%  |  Resolver  5%   (non-CLOB)
 *    Creator  60%  |  Protocol  30%  |  Resolver  5%  |  Makers 5%  (CLOB)
 *    CLOB also charges 0.3% maker-rebate on top (1.3% total taker fee).
 */
contract ClawshiFactory {
    address public owner;
    uint256 public protocolFeeBps;
    uint256 public marketCount;
    uint256 public virtualLiquidity;
    uint256 public lpFeeBps;
    uint256 public makerRewardBps;        // CLOB: % of protocol cut → maker pool (bps)
    uint256 public resolverRewardBps;      // non-CLOB: % of protocol cut → UMA resolver (bps)
    uint256 public clobResolverRewardBps;  // CLOB: % of protocol cut → UMA resolver (bps)
    address public umaOracle;

    CTFDeployer public ctfDeployer;
    MultiChoiceMarketDeployer public multiDeployer;
    ParimutuelDeployer public parimutuelDeployer;
    CLOBDeployer public clobDeployer;
    ArenaDeployer public arenaDeployer;
    uint256 public arenaMaxWalletBps;     // 0 = disabled, 100 = 1% start

    enum MarketType { CTF, MULTI_CTF, PARIMUTUEL, CLOB, ARENA }

    struct MarketInfo {
        address marketAddress;
        address creator;
        string question;
        uint256 endTime;
        bool isAgent;
        bool isPrivate;
        MarketType marketType;
    }

    mapping(uint256 => MarketInfo) public markets;
    mapping(address => bool) public registeredAgents;
    mapping(address => string) public agentNames;
    mapping(address => uint256[]) public agentMarkets;
    mapping(address => uint256[]) public creatorMarkets;

    // ── CLOB Group tracking (Multi-choice CLOB = N binary CLOBs grouped) ──
    uint256 public clobGroupCount;
    struct ClobGroup {
        string question;
        uint256[] marketIds;
    }
    mapping(uint256 => ClobGroup) private _clobGroups;
    mapping(uint256 => uint256) public marketToGroup;

    event ClobGroupCreated(uint256 indexed groupId, string question, uint256[] marketIds);
    event AgentRegistered(address indexed agent, string name);
    event AgentRevoked(address indexed agent);
    event MarketCreated(
        uint256 indexed marketId, address indexed marketAddress,
        address indexed creator, string question, uint256 endTime,
        bool isAgentCreator, uint8 marketType
    );
    event ProtocolFeeUpdated(uint256 newFeeBps);
    event MakerRewardBpsUpdated(uint256 newBps);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        uint256 _protocolFeeBps,
        uint256 _virtualLiquidity,
        uint256 _lpFeeBps,
        uint256 _makerRewardBps,
        address _ctfDeployer,
        address _multiDeployer,
        address _parimutuelDeployer,
        address _clobDeployer
    ) {
        require(_protocolFeeBps <= 100, "Protocol fee cannot exceed 1%");
        require(_lpFeeBps <= 500, "LP fee too high");
        require(_makerRewardBps <= 10000, "Maker reward too high");
        require(_virtualLiquidity > 0, "Virtual liquidity must be > 0");
        require(_ctfDeployer != address(0), "Zero CTF deployer");
        require(_multiDeployer != address(0), "Zero multi deployer");
        require(_parimutuelDeployer != address(0), "Zero parimutuel deployer");
        require(_clobDeployer != address(0), "Zero CLOB deployer");

        owner = msg.sender;
        protocolFeeBps = _protocolFeeBps;
        virtualLiquidity = _virtualLiquidity;
        lpFeeBps = _lpFeeBps;
        makerRewardBps = _makerRewardBps;
        ctfDeployer = CTFDeployer(_ctfDeployer);
        multiDeployer = MultiChoiceMarketDeployer(_multiDeployer);
        parimutuelDeployer = ParimutuelDeployer(_parimutuelDeployer);
        clobDeployer = CLOBDeployer(_clobDeployer);
    }

    // ══════════════════════════════════════════════════════════════
    //  AGENT MANAGEMENT
    // ══════════════════════════════════════════════════════════════

    /// @dev Register market with UMA oracle + route resolver reward fees to it
    function _setupUMA(
        uint256 _marketId, address _marketAddress,
        MarketType _marketType, string calldata _question
    ) internal {
        if (umaOracle == address(0)) return;

        // 1. Map factory enum → UMA enum (CTF→BINARY=0, MULTI_CTF→MULTI=1, ...)
        uint8 umaType;
        if (_marketType == MarketType.CTF)            umaType = 0;
        else if (_marketType == MarketType.MULTI_CTF) umaType = 1;
        else if (_marketType == MarketType.PARIMUTUEL) umaType = 2;
        else if (_marketType == MarketType.CLOB)       umaType = 3;
        else                                           umaType = 4;

        // 2. Register market with UMA oracle (stores question for claim text)
        IUMAResolutionOracle(umaOracle).registerMarket(_marketId, _marketAddress, umaType, _question);

        // 3. Route resolver-reward portion of fees to UMA oracle
        uint256 rewardBps = (_marketType == MarketType.CLOB)
            ? clobResolverRewardBps
            : resolverRewardBps;
        if (rewardBps > 0) {
            IRewardConfigurable(_marketAddress).setVotingConfig(umaOracle, rewardBps);
        }
    }

    function registerAgent(address _agent, string calldata _name) external onlyOwner {
        require(!registeredAgents[_agent], "Already registered");
        require(bytes(_name).length > 0, "Name required");
        registeredAgents[_agent] = true;
        agentNames[_agent] = _name;
        emit AgentRegistered(_agent, _name);
    }

    function revokeAgent(address _agent) external onlyOwner {
        require(registeredAgents[_agent], "Not registered");
        registeredAgents[_agent] = false;
        emit AgentRevoked(_agent);
    }

    // ══════════════════════════════════════════════════════════════
    //  MARKET CREATION
    // ══════════════════════════════════════════════════════════════

    /// @notice Create a binary CTF market (YES/NO, FPMM AMM)
    function createMarket(
        string calldata _question, uint256 _endTime,
        uint256 _resolutionTime, string calldata _categories,
        bool _isPrivate
    ) external returns (uint256 marketId, address marketAddress) {
        require(bytes(_question).length > 0, "Empty question");
        require(_endTime > block.timestamp, "End time must be future");
        require(_resolutionTime > _endTime, "Resolution must be after end");

        marketId = marketCount++;
        bool creatorIsAgent = registeredAgents[msg.sender];

        marketAddress = ctfDeployer.deploy(
            marketId, msg.sender, owner,
            _question, _endTime, _resolutionTime,
            protocolFeeBps, owner, _categories, virtualLiquidity, _isPrivate, lpFeeBps
        );

        markets[marketId] = MarketInfo({
            marketAddress: marketAddress, creator: msg.sender,
            question: _question, endTime: _endTime,
            isAgent: creatorIsAgent, isPrivate: _isPrivate, marketType: MarketType.CTF
        });

        _setupUMA(marketId, marketAddress, MarketType.CTF, _question);
        creatorMarkets[msg.sender].push(marketId);
        if (creatorIsAgent) agentMarkets[msg.sender].push(marketId);
        emit MarketCreated(marketId, marketAddress, msg.sender, _question, _endTime, creatorIsAgent, 0);
    }

    /// @notice Create a multi-choice CTF market (N options, FPMM AMM)
    function createMultiChoiceMarket(
        string calldata _question, string[] calldata _options,
        uint256 _endTime, uint256 _resolutionTime, string calldata _categories,
        bool _isPrivate
    ) external returns (uint256 marketId, address marketAddress) {
        require(bytes(_question).length > 0, "Empty question");
        require(_options.length >= 2 && _options.length <= 20, "2-20 options");
        require(_endTime > block.timestamp, "End time must be future");
        require(_resolutionTime > _endTime, "Resolution must be after end");

        marketId = marketCount++;
        bool creatorIsAgent = registeredAgents[msg.sender];

        marketAddress = multiDeployer.deploy(
            marketId, msg.sender, owner,
            _question, _options, _endTime, _resolutionTime,
            protocolFeeBps, owner, _categories, virtualLiquidity, _isPrivate, lpFeeBps
        );

        markets[marketId] = MarketInfo({
            marketAddress: marketAddress, creator: msg.sender,
            question: _question, endTime: _endTime,
            isAgent: creatorIsAgent, isPrivate: _isPrivate, marketType: MarketType.MULTI_CTF
        });

        _setupUMA(marketId, marketAddress, MarketType.MULTI_CTF, _question);
        creatorMarkets[msg.sender].push(marketId);
        if (creatorIsAgent) agentMarkets[msg.sender].push(marketId);
        emit MarketCreated(marketId, marketAddress, msg.sender, _question, _endTime, creatorIsAgent, 1);
    }

    /// @notice Create a parimutuel market (pot-split, no AMM)
    function createParimutuelMarket(
        string calldata _question, string[] calldata _options,
        uint256 _endTime, uint256 _resolutionTime, string calldata _categories,
        bool _isPrivate
    ) external returns (uint256 marketId, address marketAddress) {
        require(bytes(_question).length > 0, "Empty question");
        require(_options.length >= 2 && _options.length <= 20, "2-20 options");
        require(_endTime > block.timestamp, "End time must be future");
        require(_resolutionTime > _endTime, "Resolution must be after end");

        marketId = marketCount++;
        bool creatorIsAgent = registeredAgents[msg.sender];

        marketAddress = parimutuelDeployer.deploy(
            marketId, msg.sender, owner,
            _question, _options, _endTime, _resolutionTime,
            protocolFeeBps, owner, _categories, _isPrivate
        );

        markets[marketId] = MarketInfo({
            marketAddress: marketAddress, creator: msg.sender,
            question: _question, endTime: _endTime,
            isAgent: creatorIsAgent, isPrivate: _isPrivate, marketType: MarketType.PARIMUTUEL
        });

        _setupUMA(marketId, marketAddress, MarketType.PARIMUTUEL, _question);
        creatorMarkets[msg.sender].push(marketId);
        if (creatorIsAgent) agentMarkets[msg.sender].push(marketId);
        emit MarketCreated(marketId, marketAddress, msg.sender, _question, _endTime, creatorIsAgent, 2);
    }

    /// @notice Create a CLOB market (order book, binary YES/NO)
    function createCLOBMarket(
        string calldata _question, uint256 _endTime,
        uint256 _resolutionTime, string calldata _categories,
        bool _isPrivate
    ) external returns (uint256 marketId, address marketAddress) {
        require(bytes(_question).length > 0, "Empty question");
        require(_endTime > block.timestamp, "End time must be future");
        require(_resolutionTime > _endTime, "Resolution must be after end");

        marketId = marketCount++;
        bool creatorIsAgent = registeredAgents[msg.sender];

        marketAddress = clobDeployer.deploy(
            marketId, msg.sender, owner,
            _question, _endTime, _resolutionTime,
            protocolFeeBps, owner, _categories, _isPrivate, lpFeeBps, makerRewardBps
        );

        markets[marketId] = MarketInfo({
            marketAddress: marketAddress, creator: msg.sender,
            question: _question, endTime: _endTime,
            isAgent: creatorIsAgent, isPrivate: _isPrivate, marketType: MarketType.CLOB
        });

        _setupUMA(marketId, marketAddress, MarketType.CLOB, _question);
        creatorMarkets[msg.sender].push(marketId);
        if (creatorIsAgent) agentMarkets[msg.sender].push(marketId);
        emit MarketCreated(marketId, marketAddress, msg.sender, _question, _endTime, creatorIsAgent, 3);
    }

    /// @notice Deploy N binary CLOB markets grouped under one multi-choice event
    function createMultiCLOBMarket(
        string calldata _question,
        string[] calldata _optionLabels,
        uint256 _endTime,
        uint256 _resolutionTime,
        string calldata _categories,
        bool _isPrivate
    ) external returns (uint256 groupId) {
        require(bytes(_question).length > 0, "Empty question");
        require(_optionLabels.length >= 2 && _optionLabels.length <= 20, "2-20 options");
        require(_endTime > block.timestamp, "End time must be future");
        require(_resolutionTime > _endTime, "Resolution must be after end");

        clobGroupCount++;
        groupId = clobGroupCount;
        bool creatorIsAgent = registeredAgents[msg.sender];

        ClobGroup storage g = _clobGroups[groupId];
        g.question = _question;

        for (uint256 i = 0; i < _optionLabels.length; i++) {
            uint256 mId = marketCount++;

            address addr = clobDeployer.deploy(
                mId, msg.sender, owner,
                _optionLabels[i], _endTime, _resolutionTime,
                protocolFeeBps, owner, _categories, _isPrivate, lpFeeBps, makerRewardBps
            );

            markets[mId] = MarketInfo({
                marketAddress: addr, creator: msg.sender,
                question: _optionLabels[i], endTime: _endTime,
                isAgent: creatorIsAgent, isPrivate: _isPrivate, marketType: MarketType.CLOB
            });

            _setupUMA(mId, addr, MarketType.CLOB, _optionLabels[i]);
            marketToGroup[mId] = groupId;
            g.marketIds.push(mId);

            creatorMarkets[msg.sender].push(mId);
            if (creatorIsAgent) agentMarkets[msg.sender].push(mId);
            emit MarketCreated(mId, addr, msg.sender, _optionLabels[i], _endTime, creatorIsAgent, 3);
        }

        emit ClobGroupCreated(groupId, _question, g.marketIds);
    }

    // ══════════════════════════════════════════════════════════════
    //  CLOB GROUP HELPERS
    // ══════════════════════════════════════════════════════════════

    function getClobGroup(uint256 _groupId) external view returns (
        string memory question, uint256[] memory marketIds
    ) {
        require(_groupId > 0 && _groupId <= clobGroupCount, "Invalid group");
        ClobGroup storage g = _clobGroups[_groupId];
        return (g.question, g.marketIds);
    }

    function createClobGroup(
        string calldata _question, uint256[] calldata _marketIds
    ) external returns (uint256 groupId) {
        require(_marketIds.length >= 2, "Need 2+ markets");
        for (uint256 i = 0; i < _marketIds.length; i++) {
            uint256 mId = _marketIds[i];
            require(mId < marketCount, "Invalid market ID");
            require(markets[mId].marketType == MarketType.CLOB, "Not a CLOB market");
            require(markets[mId].creator == msg.sender || msg.sender == owner, "Not creator");
            require(marketToGroup[mId] == 0, "Already grouped");
        }
        clobGroupCount++;
        groupId = clobGroupCount;
        ClobGroup storage g = _clobGroups[groupId];
        g.question = _question;
        for (uint256 i = 0; i < _marketIds.length; i++) {
            g.marketIds.push(_marketIds[i]);
            marketToGroup[_marketIds[i]] = groupId;
        }
        emit ClobGroupCreated(groupId, _question, _marketIds);
    }

    // ══════════════════════════════════════════════════════════════
    //  ADMIN / VIEWS
    // ══════════════════════════════════════════════════════════════

    function getMarket(uint256 _marketId) external view returns (MarketInfo memory) {
        require(_marketId < marketCount, "Invalid market ID");
        return markets[_marketId];
    }

    function getMarketsByCreator(address _creator) external view returns (uint256[] memory) {
        return creatorMarkets[_creator];
    }

    function getAgentMarkets(address _agent) external view returns (uint256[] memory) {
        return agentMarkets[_agent];
    }

    function isAgent(address _addr) external view returns (bool) {
        return registeredAgents[_addr];
    }

    function setProtocolFee(uint256 _newFeeBps) external onlyOwner {
        require(_newFeeBps <= 100, "Fee cannot exceed 1%");
        protocolFeeBps = _newFeeBps;
        emit ProtocolFeeUpdated(_newFeeBps);
    }

    function setMakerRewardBps(uint256 _newBps) external onlyOwner {
        require(_newBps <= 10000, "Cannot exceed 100% of protocol cut");
        makerRewardBps = _newBps;
        emit MakerRewardBpsUpdated(_newBps);
    }

    function setUMAOracle(address _umaOracle) external onlyOwner {
        umaOracle = _umaOracle;
    }

    function setResolverRewardBps(uint256 _newBps) external onlyOwner {
        require(_newBps <= 10000, "Too high");
        resolverRewardBps = _newBps;
    }

    function setClobResolverRewardBps(uint256 _newBps) external onlyOwner {
        require(_newBps <= 10000, "Too high");
        clobResolverRewardBps = _newBps;
    }

    function setClobDeployer(address _newDeployer) external onlyOwner {
        require(_newDeployer != address(0), "Zero address");
        clobDeployer = CLOBDeployer(_newDeployer);
    }

    function setCtfDeployer(address _newDeployer) external onlyOwner {
        require(_newDeployer != address(0), "Zero address");
        ctfDeployer = CTFDeployer(_newDeployer);
    }

    function setMultiDeployer(address _newDeployer) external onlyOwner {
        require(_newDeployer != address(0), "Zero address");
        multiDeployer = MultiChoiceMarketDeployer(_newDeployer);
    }

    function setArenaDeployer(address _newDeployer) external onlyOwner {
        require(_newDeployer != address(0), "Zero address");
        arenaDeployer = ArenaDeployer(_newDeployer);
    }

    function setArenaMaxWalletBps(uint256 _bps) external onlyOwner {
        require(_bps <= 1500, "Max wallet bps too high");
        arenaMaxWalletBps = _bps;
    }

    // ══════════════════════════════════════════════════════════════
    //  ARENA MARKET CREATION
    // ══════════════════════════════════════════════════════════════

    /// @notice Create an elimination-style arena prediction market
    /// @dev No real ETH required — uses virtual liquidity for initial pricing.
    ///      Optional msg.value adds real ETH on top of virtual seed.
    function createArenaMarket(
        string calldata _question,
        string[] calldata _options,
        uint256 _endTime,
        string calldata _categories,
        bool _agentOnly,
        bool _isPrivate
    ) external payable returns (uint256 marketId, address marketAddress) {
        require(bytes(_question).length > 0, "Empty question");
        require(_options.length >= 8 && _options.length <= 32, "8-32 options");
        require(_endTime > block.timestamp, "End time must be future");
        require(address(arenaDeployer) != address(0), "Arena deployer not set");

        marketId = marketCount++;
        bool creatorIsAgent = registeredAgents[msg.sender];

        marketAddress = arenaDeployer.deploy{value: msg.value}(
            marketId, msg.sender, owner, address(this),
            _question, _options, _endTime,
            protocolFeeBps, owner, _categories,
            _agentOnly, virtualLiquidity,
            arenaMaxWalletBps
        );

        markets[marketId] = MarketInfo({
            marketAddress: marketAddress, creator: msg.sender,
            question: _question, endTime: _endTime,
            isAgent: creatorIsAgent, isPrivate: _isPrivate, marketType: MarketType.ARENA
        });

        _setupUMA(marketId, marketAddress, MarketType.ARENA, _question);
        creatorMarkets[msg.sender].push(marketId);
        if (creatorIsAgent) agentMarkets[msg.sender].push(marketId);
        emit MarketCreated(marketId, marketAddress, msg.sender, _question, _endTime, creatorIsAgent, 4);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address");
        owner = _newOwner;
    }
}
