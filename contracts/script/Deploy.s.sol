// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SystemDeployer} from "./SystemDeployer.sol";

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @title Deploy
/// @notice One-shot deployment of Gapguard: deploys every contract, wires roles/assets/products from
///         ../config/chains.json, hands all admin rights to the 48h Timelock, asserts the handover and writes
///         deployments/<chainId>.json plus app/src/config/deployments/<chainId>.json.
///
///         Signing: only through a Foundry keystore account, e.g. `--account gapguard-deployer` (see DEPLOY.md).
///         This script never reads, derives or prints a private key.
///
///         Environment (all optional):
///           GAPGUARD_ADMIN      Timelock proposer / ops multisig (default: deployer — set a Safe for mainnet!)
///           GAPGUARD_GUARDIAN   pause guardian            (default: GAPGUARD_ADMIN)
///           GAPGUARD_KEEPER     keeper bot address        (default: deployer)
///           GAPGUARD_COMMITTEE  dispute committee         (default: GAPGUARD_ADMIN)
///           GAPGUARD_TIMELOCK_DELAY seconds (>= 172800)   (default: 172800)
///           CONFIG_CHAIN_ID     config to use on a local fork (default: 4663 when chainid == 31337)
contract Deploy is Script, SystemDeployer {
    using stdJson for string;

    function loadParams(uint256 cfgChainId, address deployer) public view returns (Params memory p) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../config/chains.json"));
        string memory k = string.concat(".chain_", vm.toString(cfgChainId));
        p.stablecoin = json.readAddress(string.concat(k, ".stablecoin"));
        p.stablecoinFeed = json.readAddress(string.concat(k, ".stablecoinFeed"));
        p.sequencerUptimeFeed = json.readAddress(string.concat(k, ".sequencerUptimeFeed"));

        string[] memory symbols = json.readStringArray(string.concat(k, ".symbols"));
        address[] memory tokens = json.readAddressArray(string.concat(k, ".tokens"));
        address[] memory feeds = json.readAddressArray(string.concat(k, ".feeds"));
        address[] memory pools = json.readAddressArray(string.concat(k, ".dexPools"));
        bool[] memory gap = json.readBoolArray(string.concat(k, ".gap"));
        bool[] memory depeg = json.readBoolArray(string.concat(k, ".depeg"));
        bool[] memory outage = json.readBoolArray(string.concat(k, ".outage"));
        bool[] memory halt = json.readBoolArray(string.concat(k, ".halt"));
        p.assets = new AssetParams[](symbols.length);
        for (uint256 i; i < symbols.length; ++i) {
            p.assets[i] = AssetParams(symbols[i], tokens[i], feeds[i], pools[i], gap[i], depeg[i], outage[i], halt[i]);
        }

        p.admin = vm.envOr("GAPGUARD_ADMIN", deployer);
        p.guardian = vm.envOr("GAPGUARD_GUARDIAN", p.admin);
        p.keeper = vm.envOr("GAPGUARD_KEEPER", deployer);
        p.committee = vm.envOr("GAPGUARD_COMMITTEE", p.admin);
        p.timelockDelay = vm.envOr("GAPGUARD_TIMELOCK_DELAY", uint256(48 hours));
        p.feedMaxStaleness = 26 hours; // Chainlink heartbeat 24h + 2h tolerance
        p.depegTwapWindow = 30 minutes;
        p.depegMinLiquidity = 1; // non-empty pool; calibrate per asset via Timelock (see DEPLOY.md)
    }

    function configChainId() public view returns (uint256) {
        if (block.chainid == 31337) return vm.envOr("CONFIG_CHAIN_ID", uint256(4663));
        return block.chainid;
    }

    function run() external returns (System memory s) {
        uint256 cfgId = configChainId();
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Params memory p = loadParams(cfgId, deployer);
        console.log("Deployer:", deployer);
        console.log("Chain id:", block.chainid, "config:", cfgId);
        console.log("Timelock proposer (admin):", p.admin);
        if (p.admin == deployer) console.log("WARNING: GAPGUARD_ADMIN not set - the deployer EOA will be the Timelock proposer");
        s = _deploySystem(p, deployer);
        vm.stopBroadcast();

        _assertHandover(s, deployer);
        _writeOutputs(s, p, cfgId);
    }

    // ---------------------------------------------------------------- outputs

    function _startBlock() internal view returns (uint256) {
        if (block.chainid == 31337) return block.number;
        try IArbSys(address(100)).arbBlockNumber() returns (uint256 n) {
            return n;
        } catch {
            return block.number;
        }
    }

    function _writeOutputs(System memory s, Params memory p, uint256 cfgId) internal {
        string memory c = "contracts";
        vm.serializeAddress(c, "timelock", address(s.timelock));
        vm.serializeAddress(c, "oracleAdapter", address(s.oracle));
        vm.serializeAddress(c, "marketClock", address(s.clock));
        vm.serializeAddress(c, "pricingCurve", address(s.pricing));
        vm.serializeAddress(c, "feeCollector", address(s.feeCollector));
        vm.serializeAddress(c, "complianceRegistry", address(s.compliance));
        vm.serializeAddress(c, "projectTokenHooks", address(s.hooks));
        vm.serializeAddress(c, "attestationModule", address(s.attestation));
        vm.serializeAddress(c, "coverNFT", address(s.coverNFT));
        vm.serializeAddress(c, "coverRegistry", address(s.registry));
        vm.serializeAddress(c, "poolWeekendGap", address(s.pools[GAP]));
        vm.serializeAddress(c, "poolDepeg", address(s.pools[DEPEG]));
        vm.serializeAddress(c, "poolOracleOutage", address(s.pools[OUTAGE]));
        vm.serializeAddress(c, "poolIssuerHalt", address(s.pools[HALT]));
        vm.serializeAddress(c, "resolverWeekendGap", address(s.gapResolver));
        vm.serializeAddress(c, "resolverDepeg", address(s.depegResolver));
        vm.serializeAddress(c, "resolverOracleOutage", address(s.outageResolver));
        string memory contractsJson = vm.serializeAddress(c, "resolverIssuerHalt", address(s.haltResolver));

        string memory r = "roles";
        vm.serializeAddress(r, "admin", p.admin);
        vm.serializeAddress(r, "guardian", p.guardian);
        vm.serializeAddress(r, "keeper", p.keeper);
        string memory rolesJson = vm.serializeAddress(r, "committee", p.committee);

        string memory root = "root";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "configChainId", cfgId);
        vm.serializeUint(root, "startBlock", _startBlock());
        vm.serializeUint(root, "deployedAt", block.timestamp);
        vm.serializeAddress(root, "stablecoin", p.stablecoin);
        vm.serializeString(root, "roles", rolesJson);
        string memory out = vm.serializeString(root, "contracts", contractsJson);

        string memory id = vm.toString(block.chainid);
        string memory base = string.concat(vm.projectRoot(), "/..");
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            vm.writeJson(out, string.concat(base, "/deployments/", id, ".json"));
            vm.writeJson(out, string.concat(base, "/app/src/config/deployments/", id, ".json"));
            console.log("Wrote deployments/%s.json and app/src/config/deployments/%s.json", id, id);
        } else {
            vm.writeJson(out, string.concat(base, "/deployments/", id, ".dryrun.json"));
            console.log("Dry run: wrote deployments/%s.dryrun.json (no broadcast, frontend config untouched)", id);
        }
    }
}
