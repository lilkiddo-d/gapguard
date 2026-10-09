// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {ICompliance} from "../../src/interfaces/ICompliance.sol";

/// @notice Test-only ERC-20 (the project never deploys a token on-chain; this is used as USDG and $GAPG stand-ins).
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stock token mock exposing the Robinhood Chain pause / oracle-pause / multiplier surface.
contract MockStockToken is MockERC20 {
    bool public paused;
    bool public oraclePaused;
    uint256 public uiMultiplier = 1e18;

    constructor(string memory s) MockERC20(s, s, 18) {}

    function setPaused(bool p) external {
        paused = p;
    }

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }
}

/// @notice Chainlink-style aggregator proxy with phase-aware round ids (phaseId << 64 | aggregatorRound).
contract MockAggregator is AggregatorV3Interface {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    uint8 public immutable decimals;
    uint16 public phaseId = 1;
    mapping(uint80 => Round) public rounds;
    mapping(uint16 => uint64) public lastAggRound;
    uint80 public latestRound;

    constructor(uint8 d) {
        decimals = d;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function push(int256 answer, uint256 updatedAt) public returns (uint80 id) {
        uint64 next = lastAggRound[phaseId] + 1;
        lastAggRound[phaseId] = next;
        id = uint80((uint256(phaseId) << 64) | next);
        rounds[id] = Round(answer, updatedAt);
        latestRound = id;
    }

    function pushNow(int256 answer) external returns (uint80) {
        return push(answer, block.timestamp);
    }

    function newPhase() external {
        phaseId += 1;
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[roundId];
        require(r.updatedAt != 0, "No data present");
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latestRound];
        return (latestRound, r.answer, r.updatedAt, r.updatedAt, latestRound);
    }
}

/// @notice Sequencer uptime feed mock: answer 0 = up, 1 = down.
contract MockSequencerFeed {
    int256 public answer;
    uint256 public startedAt;

    function set(int256 a, uint256 s) external {
        answer = a;
        startedAt = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }
}

/// @notice Uniswap v3 pool mock: returns tick cumulatives consistent with a constant average tick.
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    uint128 public liquidity = 1e24;
    int24 public avgTick;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setTick(int24 t) external {
        avgTick = t;
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory c, uint160[] memory s) {
        c = new int56[](secondsAgos.length);
        s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            c[i] = int56(avgTick) * int56(int256(block.timestamp - secondsAgos[i]));
        }
    }
}

contract MockComplianceProvider is ICompliance {
    mapping(address => bool) public ok;

    function set(address a, bool v) external {
        ok[a] = v;
    }

    function isAllowed(address account, bytes32) external view returns (bool) {
        return ok[account];
    }
}
