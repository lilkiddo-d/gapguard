// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {GapguardTimelock} from "../src/governance/GapguardTimelock.sol";
import {ChainlinkOracleAdapter} from "../src/ChainlinkOracleAdapter.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {PricingCurve} from "../src/PricingCurve.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {AttestationModule} from "../src/AttestationModule.sol";
import {CoverNFT} from "../src/CoverNFT.sol";
import {CoverRegistry} from "../src/CoverRegistry.sol";
import {CapitalPool} from "../src/CapitalPool.sol";
import {WeekendGapResolver} from "../src/resolvers/WeekendGapResolver.sol";
import {DepegResolver} from "../src/resolvers/DepegResolver.sol";
import {OracleOutageResolver} from "../src/resolvers/OracleOutageResolver.sol";
import {IssuerHaltResolver} from "../src/resolvers/IssuerHaltResolver.sol";
import {BaseResolver} from "../src/resolvers/BaseResolver.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ICapitalPool} from "../src/interfaces/ICapitalPool.sol";
import {ITriggerResolver} from "../src/interfaces/ITriggerResolver.sol";
import {ICompliance} from "../src/interfaces/ICompliance.sol";
import {IMarketClock} from "../src/interfaces/IMarketClock.sol";
import {IOracleAdapter} from "../src/interfaces/IOracleAdapter.sol";
import {IProjectTokenHooks} from "../src/interfaces/IProjectTokenHooks.sol";
import {IAttestationModule} from "../src/interfaces/IAttestationModule.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {Roles} from "../src/libraries/Roles.sol";

/// @notice Deploys and wires the full Gapguard system, then hands every admin role to the Timelock.
///         Shared by script/Deploy.s.sol and the test-suite so tests exercise the exact production wiring.
abstract contract SystemDeployer {
    uint8 internal constant GAP = 0;
    uint8 internal constant DEPEG = 1;
    uint8 internal constant OUTAGE = 2;
    uint8 internal constant HALT = 3;

    struct AssetParams {
        string symbol;
        address token;
        address feed;
        address dexPool; // address(0) = no depeg cover
        bool gap;
        bool depeg;
        bool outage;
        bool halt;
    }

    struct Params {
        address stablecoin;
        address stablecoinFeed;
        address sequencerUptimeFeed; // address(0) = none
        address admin; // Timelock proposer (ops multisig)
        address guardian; // can pause
        address keeper; // keeper bot (KEEPER_ROLE on attestation-based resolver)
        address committee; // dispute committee (COMMITTEE_ROLE)
        uint256 timelockDelay;
        uint32 feedMaxStaleness;
        uint32 depegTwapWindow;
        uint128 depegMinLiquidity;
        AssetParams[] assets;
    }

    struct System {
        GapguardTimelock timelock;
        ChainlinkOracleAdapter oracle;
        MarketClock clock;
        PricingCurve pricing;
        FeeCollector feeCollector;
        ComplianceRegistry compliance;
        ProjectTokenHooks hooks;
        AttestationModule attestation;
        CoverNFT coverNFT;
        CoverRegistry registry;
        CapitalPool[4] pools;
        WeekendGapResolver gapResolver;
        DepegResolver depegResolver;
        OracleOutageResolver outageResolver;
        IssuerHaltResolver haltResolver;
    }

    /// @param self The account that sends the deployment transactions (broadcaster EOA in scripts, the test
    ///             contract in tests). It is temporary admin and renounces every admin role at the end.
    function _deploySystem(Params memory p, address self) internal returns (System memory s) {
        {
            address[] memory proposers = new address[](1);
            proposers[0] = p.admin;
            address[] memory executors = new address[](1);
            executors[0] = address(0); // open execution once the delay has elapsed
            s.timelock = new GapguardTimelock(p.timelockDelay, proposers, executors);
        }
        s.oracle = new ChainlinkOracleAdapter(self);
        // Friday 20:00 New York close, Sunday 20:00 New York reopen (24/5 session)
        s.clock = new MarketClock(self, 20 hours, 2, 20 hours);
        s.pricing = new PricingCurve(self);
        s.feeCollector = new FeeCollector(address(s.timelock));
        s.compliance = new ComplianceRegistry(self);
        s.hooks = new ProjectTokenHooks(IERC20(p.stablecoin), self);
        s.attestation = new AttestationModule(self, IProjectTokenHooks(address(s.hooks)), address(s.feeCollector));
        s.coverNFT = new CoverNFT(self);
        s.registry = new CoverRegistry(self, IERC20(p.stablecoin), s.coverNFT, s.pricing, address(s.feeCollector));

        s.pools[GAP] = new CapitalPool(IERC20(p.stablecoin), "Gapguard Weekend Gap Pool", "ggGAP", GAP, self);
        s.pools[DEPEG] = new CapitalPool(IERC20(p.stablecoin), "Gapguard Depeg Pool", "ggDEPEG", DEPEG, self);
        s.pools[OUTAGE] = new CapitalPool(IERC20(p.stablecoin), "Gapguard Oracle Outage Pool", "ggOUTAGE", OUTAGE, self);
        s.pools[HALT] = new CapitalPool(IERC20(p.stablecoin), "Gapguard Issuer Halt Pool", "ggHALT", HALT, self);

        IOracleAdapter oracle = IOracleAdapter(address(s.oracle));
        s.gapResolver = new WeekendGapResolver(self, oracle, IMarketClock(address(s.clock)));
        s.depegResolver = new DepegResolver(self, oracle);
        s.outageResolver = new OracleOutageResolver(self, oracle, IMarketClock(address(s.clock)));
        s.haltResolver = new IssuerHaltResolver(self, oracle, IAttestationModule(address(s.attestation)));

        _wireOracle(s, p);
        _wireCore(s, p);
        _wireAssets(s, p);
        _handover(s, p, self);
    }

    function _wireOracle(System memory s, Params memory p) internal {
        s.oracle.setFeed(p.stablecoin, AggregatorV3Interface(p.stablecoinFeed), p.feedMaxStaleness, false);
        if (p.sequencerUptimeFeed != address(0)) {
            s.oracle.setSequencerUptimeFeed(AggregatorV3Interface(p.sequencerUptimeFeed), 1 hours);
        }
        for (uint256 i; i < p.assets.length; ++i) {
            s.oracle.setFeed(p.assets[i].token, AggregatorV3Interface(p.assets[i].feed), p.feedMaxStaleness, true);
        }
    }

    function _wireCore(System memory s, Params memory p) internal {
        // Pricing curves (annualised bps): base, slope1, slope2, kink
        s.pricing.setCurve(GAP, 300, 800, 4_000, 7_000);
        s.pricing.setCurve(DEPEG, 200, 600, 4_000, 7_000);
        s.pricing.setCurve(OUTAGE, 100, 400, 3_000, 7_000);
        s.pricing.setCurve(HALT, 150, 500, 3_000, 7_000);

        s.coverNFT.setRegistry(s.registry);
        s.coverNFT.setCompliance(ICompliance(address(s.compliance)));
        s.coverNFT.grantRole(Roles.MINTER_ROLE, address(s.registry));

        s.registry.setModules(
            s.pricing, ICompliance(address(s.compliance)), IProjectTokenHooks(address(s.hooks)), address(s.feeCollector)
        );
        s.registry.setMinCoverAmount(10e6); // 10 USDG

        ITriggerResolver[4] memory resolvers = [
            ITriggerResolver(address(s.gapResolver)),
            ITriggerResolver(address(s.depegResolver)),
            ITriggerResolver(address(s.outageResolver)),
            ITriggerResolver(address(s.haltResolver))
        ];
        uint16[4] memory assetCaps = [uint16(2_500), uint16(3_000), uint16(2_500), uint16(2_500)];
        for (uint8 i; i < 4; ++i) {
            CapitalPool pool = s.pools[i];
            pool.grantRole(Roles.REGISTRY_ROLE, address(s.registry));
            pool.setWithdrawGuard(resolvers[i]);
            pool.setCompliance(ICompliance(address(s.compliance)));
            s.registry.setProduct(i, ICapitalPool(address(pool)), resolvers[i], 8_000, assetCaps[i], 1 hours, true);
        }

        s.hooks.grantRole(Roles.REGISTRY_ROLE, address(s.registry));
        s.hooks.grantRole(Roles.ATTESTATION_ROLE, address(s.attestation));
        s.hooks.setCompliance(ICompliance(address(s.compliance)));

        s.attestation.grantRole(Roles.RESOLVER_ROLE, address(s.haltResolver));
        s.attestation.grantRole(Roles.COMMITTEE_ROLE, p.committee);
        s.haltResolver.grantRole(Roles.KEEPER_ROLE, p.keeper);
        s.haltResolver.grantRole(Roles.COMMITTEE_ROLE, p.committee);

        s.clock.grantRole(Roles.OPERATOR_ROLE, p.admin);
        s.compliance.grantRole(Roles.COMPLIANCE_ROLE, p.admin);
    }

    function _wireAssets(System memory s, Params memory p) internal {
        for (uint256 i; i < p.assets.length; ++i) {
            AssetParams memory a = p.assets[i];
            if (a.gap) {
                s.gapResolver.setAssetEnabled(a.token, true);
                s.registry.setAssetAllowed(GAP, a.token, true);
            }
            if (a.depeg && a.dexPool != address(0)) {
                s.depegResolver.setDexConfig(
                    a.token, IUniswapV3Pool(a.dexPool), p.stablecoin, p.depegTwapWindow, p.depegMinLiquidity
                );
                s.depegResolver.setAssetEnabled(a.token, true);
                s.registry.setAssetAllowed(DEPEG, a.token, true);
            }
            if (a.outage) {
                s.outageResolver.setAssetEnabled(a.token, true);
                s.registry.setAssetAllowed(OUTAGE, a.token, true);
            }
            if (a.halt) {
                s.haltResolver.setAssetEnabled(a.token, true);
                s.registry.setAssetAllowed(HALT, a.token, true);
            }
        }
    }

    function _handover(System memory s, Params memory p, address self) internal {
        address tl = address(s.timelock);
        AccessControl[17] memory all = [
            AccessControl(address(s.oracle)),
            AccessControl(address(s.clock)),
            AccessControl(address(s.pricing)),
            AccessControl(address(s.compliance)),
            AccessControl(address(s.hooks)),
            AccessControl(address(s.attestation)),
            AccessControl(address(s.coverNFT)),
            AccessControl(address(s.registry)),
            AccessControl(address(s.pools[0])),
            AccessControl(address(s.pools[1])),
            AccessControl(address(s.pools[2])),
            AccessControl(address(s.pools[3])),
            AccessControl(address(s.gapResolver)),
            AccessControl(address(s.depegResolver)),
            AccessControl(address(s.outageResolver)),
            AccessControl(address(s.haltResolver)),
            AccessControl(address(s.feeCollector))
        ];
        for (uint256 i; i < all.length; ++i) {
            AccessControl c = all[i];
            // GUARDIAN_ROLE is harmless on contracts without pause(); grant uniformly for simplicity
            if (address(c) != address(s.feeCollector)) {
                c.grantRole(Roles.GUARDIAN_ROLE, p.guardian);
                c.grantRole(c.DEFAULT_ADMIN_ROLE(), tl);
                c.renounceRole(c.DEFAULT_ADMIN_ROLE(), self);
            }
        }
    }

    /// @notice Post-deploy assertions: the deployer must hold no admin role anywhere.
    function _assertHandover(System memory s, address deployer) internal view {
        bytes32 admin = 0x00;
        require(s.registry.hasRole(admin, address(s.timelock)), "registry admin");
        require(!s.registry.hasRole(admin, deployer), "deployer still admin: registry");
        require(!s.hooks.hasRole(admin, deployer), "deployer still admin: hooks");
        require(!s.oracle.hasRole(admin, deployer), "deployer still admin: oracle");
        require(!s.coverNFT.hasRole(admin, deployer), "deployer still admin: nft");
        require(!s.attestation.hasRole(admin, deployer), "deployer still admin: attestation");
        for (uint256 i; i < 4; ++i) {
            require(!s.pools[i].hasRole(admin, deployer), "deployer still admin: pool");
        }
        require(!s.gapResolver.hasRole(admin, deployer), "deployer still admin: gap");
        require(!s.depegResolver.hasRole(admin, deployer), "deployer still admin: depeg");
        require(!s.outageResolver.hasRole(admin, deployer), "deployer still admin: outage");
        require(!s.haltResolver.hasRole(admin, deployer), "deployer still admin: halt");
        require(!s.clock.hasRole(admin, deployer), "deployer still admin: clock");
        require(!s.pricing.hasRole(admin, deployer), "deployer still admin: pricing");
        require(!s.compliance.hasRole(admin, deployer), "deployer still admin: compliance");
        require(s.timelock.getMinDelay() >= 48 hours, "timelock delay");
        require(!s.hooks.tokenEnabled(), "token must start disabled");
    }

    function _resolverOf(System memory s, uint8 productId) internal pure returns (BaseResolver) {
        if (productId == GAP) return BaseResolver(address(s.gapResolver));
        if (productId == DEPEG) return BaseResolver(address(s.depegResolver));
        if (productId == OUTAGE) return BaseResolver(address(s.outageResolver));
        return BaseResolver(address(s.haltResolver));
    }
}
