// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "../Fixture.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {AttestationModule} from "../../src/AttestationModule.sol";
import {GapguardTimelock} from "../../src/governance/GapguardTimelock.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {IProjectTokenHooks} from "../../src/interfaces/IProjectTokenHooks.sol";
import {ICompliance} from "../../src/interfaces/ICompliance.sol";
import {IAttestationModule} from "../../src/interfaces/IAttestationModule.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockERC20, MockComplianceProvider} from "../mocks/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GuardedAccess} from "../../src/governance/GuardedAccess.sol";

contract TokenGovernanceTest is Fixture {
    MockERC20 gapg; // test-only stand-in for the externally launched $GAPG

    function setUp() public override {
        super.setUp();
        gapg = new MockERC20("Gapguard", "GAPG", 18);
        underwrite(HALT, bob, 1_000_000e6);
        underwrite(GAP, bob, 1_000_000e6);
    }

    /// @dev setProjectToken through the real 48h timelock flow (schedule as proposer, execute after delay).
    function _setTokenViaTimelock() internal {
        bytes memory data = abi.encodeCall(ProjectTokenHooks.setProjectToken, (address(gapg)));
        vm.prank(admin);
        s.timelock.schedule(address(s.hooks), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.expectRevert();
        s.timelock.execute(address(s.hooks), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        s.timelock.execute(address(s.hooks), 0, data, bytes32(0), bytes32(0)); // open executor
        // refresh feeds after the warp
        warpAndRefresh(block.timestamp);
    }

    function test_tokenDisabledByDefault() public {
        assertFalse(s.hooks.tokenEnabled());
        assertFalse(s.hooks.canReceiveRewards());
        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        s.hooks.stake(1);
        assertFalse(s.attestation.canDispute(carol));
        assertTrue(s.attestation.canDispute(committee));
    }

    function test_setProjectToken_onlyOnceOnlyTimelock() public {
        vm.prank(admin);
        vm.expectRevert();
        s.hooks.setProjectToken(address(gapg));
        _setTokenViaTimelock();
        assertTrue(s.hooks.tokenEnabled());
        assertEq(address(s.hooks.projectToken()), address(gapg));
        vm.prank(address(s.timelock));
        vm.expectRevert(ProjectTokenHooks.TokenAlreadySet.selector);
        s.hooks.setProjectToken(address(gapg));
    }

    function test_setProjectToken_rejectsInvalid() public {
        vm.startPrank(address(s.timelock));
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        s.hooks.setProjectToken(address(0));
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        s.hooks.setProjectToken(makeAddr("eoa"));
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        s.hooks.setProjectToken(address(usdg));
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal {
        gapg.mint(who, amount);
        vm.startPrank(who);
        gapg.approve(address(s.hooks), amount);
        s.hooks.stake(amount);
        vm.stopPrank();
    }

    function test_stakersEarnPremiumShare() public {
        _setTokenViaTimelock();
        _stake(carol, 10_000e18);
        assertTrue(s.hooks.canReceiveRewards());
        (uint256 q,) = s.registry.quote(GAP, address(aaa), 100_000e6, 30 days);
        buy(alice, GAP, address(aaa), 100_000e6, 30 days);
        uint256 stakerShare = q * 1_000 / 10_000;
        assertApproxEqAbs(s.hooks.pendingRewards(carol), stakerShare, 1);
        vm.prank(carol);
        uint256 got = s.hooks.claimRewards();
        assertApproxEqAbs(got, stakerShare, 1);
        assertEq(usdg.balanceOf(carol), got);
        // claiming again yields nothing
        vm.prank(carol);
        assertEq(s.hooks.claimRewards(), 0);
    }

    function test_unstakeCooldown() public {
        _setTokenViaTimelock();
        _stake(carol, 1_000e18);
        vm.startPrank(carol);
        vm.expectRevert(ProjectTokenHooks.InsufficientUnbonded.selector);
        s.hooks.requestUnstake(2_000e18);
        s.hooks.requestUnstake(1_000e18);
        vm.expectRevert(ProjectTokenHooks.CooldownActive.selector);
        s.hooks.withdrawUnstaked();
        vm.warp(block.timestamp + 7 days);
        s.hooks.withdrawUnstaked();
        vm.expectRevert(ProjectTokenHooks.InvalidAmount.selector);
        s.hooks.withdrawUnstaked();
        vm.expectRevert(ProjectTokenHooks.InvalidAmount.selector);
        s.hooks.stake(0);
        vm.stopPrank();
        assertEq(gapg.balanceOf(carol), 1_000e18);
    }

    function test_rewardsWithNoStakersAreBuffered() public {
        _setTokenViaTimelock();
        usdg.mint(address(s.hooks), 100e6);
        vm.prank(address(s.registry));
        s.hooks.notifyReward(100e6);
        assertEq(s.hooks.undistributedRewards(), 100e6);
        _stake(carol, 1e18);
        usdg.mint(address(s.hooks), 1e6);
        vm.prank(address(s.registry));
        s.hooks.notifyReward(1e6);
        assertApproxEqAbs(s.hooks.pendingRewards(carol), 101e6, 1);
    }

    function _proposeHalt() internal returns (uint256 attId, bytes32 eventId) {
        s.haltResolver.poke(address(aaa));
        vm.warp(block.timestamp + 1 hours);
        aaa.setPaused(true);
        uint64 start = uint64(block.timestamp);
        s.haltResolver.poke(address(aaa));
        vm.warp(block.timestamp + 25 hours);
        vm.prank(keeper);
        eventId = s.haltResolver.proposeHalt(address(aaa), start);
        (,,, attId,) = s.haltResolver.claims(eventId);
    }

    function test_stakerDispute_wrongDisputeIsSlashed() public {
        _setTokenViaTimelock();
        _stake(carol, 5_000e18);
        (uint256 attId, bytes32 eventId) = _proposeHalt();
        assertTrue(s.attestation.canDispute(carol));
        vm.prank(carol);
        s.attestation.dispute(attId);
        assertEq(s.hooks.availableToBond(carol), 4_000e18);
        // bonded stake cannot be unstaked
        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.InsufficientUnbonded.selector);
        s.hooks.requestUnstake(5_000e18);
        vm.prank(committee);
        s.attestation.resolveDispute(attId, true); // attestation was right -> disputer slashed
        assertEq(gapg.balanceOf(address(s.feeCollector)), 1_000e18);
        (uint256 staked, uint256 bonded,,,,) = s.hooks.stakers(carol);
        assertEq(staked, 4_000e18);
        assertEq(bonded, 0);
        assertTrue(s.haltResolver.settle(eventId));
        assertEq(uint8(s.attestation.getAttestation(attId).status), uint8(IAttestationModule.Status.Accepted));
    }

    function test_stakerDispute_correctDisputeReleasesBond() public {
        _setTokenViaTimelock();
        _stake(carol, 5_000e18);
        (uint256 attId,) = _proposeHalt();
        vm.prank(carol);
        s.attestation.dispute(attId);
        vm.prank(committee);
        s.attestation.resolveDispute(attId, false);
        assertEq(s.hooks.availableToBond(carol), 5_000e18);
    }

    function test_dispute_arbitrationTimeoutRejects() public {
        _setTokenViaTimelock();
        _stake(carol, 5_000e18);
        (uint256 attId,) = _proposeHalt();
        vm.prank(carol);
        s.attestation.dispute(attId);
        vm.expectRevert(AttestationModule.WindowOpen.selector);
        s.attestation.finalize(attId);
        vm.warp(block.timestamp + 7 days);
        s.attestation.finalize(attId);
        assertEq(uint8(s.attestation.statusOf(attId)), uint8(IAttestationModule.Status.Rejected));
        assertEq(s.hooks.availableToBond(carol), 5_000e18);
        vm.expectRevert(abi.encodeWithSelector(AttestationModule.WrongStatus.selector, IAttestationModule.Status.Rejected));
        s.attestation.finalize(attId);
    }

    function test_dispute_validation() public {
        (uint256 attId,) = _proposeHalt();
        vm.prank(committee);
        vm.expectRevert(abi.encodeWithSelector(AttestationModule.WrongStatus.selector, IAttestationModule.Status.Pending));
        s.attestation.resolveDispute(attId, true);
        vm.warp(block.timestamp + 1 days);
        vm.prank(committee);
        vm.expectRevert(AttestationModule.WindowClosed.selector);
        s.attestation.dispute(attId);
        vm.expectRevert();
        s.attestation.propose(bytes32(0), alice);
        vm.prank(committee);
        vm.expectRevert(abi.encodeWithSelector(AttestationModule.WrongStatus.selector, IAttestationModule.Status.None));
        s.attestation.dispute(999);
    }

    function test_attestationAdmin() public {
        vm.startPrank(address(s.timelock));
        vm.expectRevert(AttestationModule.InvalidParam.selector);
        s.attestation.setParams(1 minutes, 7 days, 1);
        vm.expectRevert(AttestationModule.InvalidParam.selector);
        s.attestation.setParams(1 days, 1 hours, 1);
        vm.expectRevert(AttestationModule.InvalidParam.selector);
        s.attestation.setParams(1 days, 7 days, 0);
        s.attestation.setParams(12 hours, 3 days, 500e18);
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        s.attestation.setHooks(IProjectTokenHooks(address(s.hooks)), address(0));
        s.attestation.setHooks(IProjectTokenHooks(address(0)), address(s.feeCollector));
        vm.stopPrank();
        assertFalse(s.attestation.canDispute(carol));
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        new AttestationModule(address(this), IProjectTokenHooks(address(0)), address(0));
    }

    function test_hooksRestricted() public {
        vm.expectRevert();
        s.hooks.lockBond(carol, 1);
        vm.expectRevert();
        s.hooks.notifyReward(1);
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        new ProjectTokenHooks(IERC20(address(0)), address(this));
    }

    function test_stakeCompliance() public {
        _setTokenViaTimelock();
        vm.prank(address(s.timelock));
        s.compliance.setEnabled(true);
        gapg.mint(carol, 1e18);
        vm.startPrank(carol);
        gapg.approve(address(s.hooks), 1e18);
        vm.expectRevert(ProjectTokenHooks.NotAllowed.selector);
        s.hooks.stake(1e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ timelock / compliance / fees

    function test_timelockFloor() public {
        address[] memory a = new address[](1);
        a[0] = admin;
        vm.expectRevert(GapguardTimelock.DelayTooShort.selector);
        new GapguardTimelock(1 days, a, a);
        // even a timelocked updateDelay cannot go below 48h effective
        bytes memory data = abi.encodeWithSignature("updateDelay(uint256)", 1 hours);
        vm.prank(admin);
        s.timelock.schedule(address(s.timelock), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        s.timelock.execute(address(s.timelock), 0, data, bytes32(0), bytes32(0));
        assertEq(s.timelock.getMinDelay(), 48 hours);
    }

    function test_complianceProvider() public {
        MockComplianceProvider p = new MockComplianceProvider();
        vm.startPrank(address(s.timelock));
        s.compliance.setEnabled(true);
        s.compliance.setProvider(ICompliance(address(p)));
        vm.stopPrank();
        assertFalse(s.compliance.isAllowed(alice, Roles.ACTION_BUY_COVER));
        p.set(alice, true);
        assertTrue(s.compliance.isAllowed(alice, Roles.ACTION_BUY_COVER));
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        new ComplianceRegistry(address(0));
    }

    function test_feeCollector() public {
        buy(alice, GAP, address(aaa), 10_000e6, 7 days);
        uint256 bal = usdg.balanceOf(address(s.feeCollector));
        assertGt(bal, 0);
        vm.expectRevert();
        s.feeCollector.withdraw(IERC20(address(usdg)), admin, bal);
        vm.prank(address(s.timelock));
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        s.feeCollector.withdraw(IERC20(address(usdg)), address(0), bal);
        vm.prank(address(s.timelock));
        s.feeCollector.withdraw(IERC20(address(usdg)), admin, bal);
        assertEq(usdg.balanceOf(admin), bal);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(address(0));
    }

    function test_guardedAccessZeroAdmin() public {
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        new ProjectTokenHooks(IERC20(address(usdg)), address(0));
    }
}
