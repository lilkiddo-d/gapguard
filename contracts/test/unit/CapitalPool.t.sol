// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "../Fixture.sol";
import {CapitalPool} from "../../src/CapitalPool.sol";
import {ICompliance} from "../../src/interfaces/ICompliance.sol";
import {ITriggerResolver} from "../../src/interfaces/ITriggerResolver.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract CapitalPoolTest is Fixture {
    CapitalPool pool;

    function setUp() public override {
        super.setUp();
        pool = s.pools[OUTAGE];
    }

    function test_depositAndShares() public {
        uint256 shares = underwrite(OUTAGE, bob, 1_000e6);
        assertEq(pool.balanceOf(bob), shares);
        assertEq(shares, 1_000e6 * 1e6); // 6-decimal virtual offset
        assertEq(pool.totalAssets(), 1_000e6);
        assertEq(pool.decimals(), 12);
        assertEq(pool.freeCapital(), 1_000e6);
        assertEq(pool.utilizationBps(), 0);
        assertEq(pool.maxDeposit(bob), type(uint256).max);
        assertEq(pool.maxMint(bob), type(uint256).max);
    }

    function test_mint() public {
        usdg.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdg.approve(address(pool), type(uint256).max);
        pool.mint(5e14, bob);
        vm.stopPrank();
        assertEq(pool.balanceOf(bob), 5e14);
    }

    function test_withdrawFlow_cooldownWindowAndFreeCapital() public {
        uint256 shares = underwrite(OUTAGE, bob, 1_000e6);
        vm.startPrank(bob);
        // direct redeem without request is impossible
        assertEq(pool.maxRedeem(bob), 0);
        vm.expectRevert(CapitalPool.NoMaturedRequest.selector);
        pool.redeem(shares, bob, bob);

        pool.requestWithdraw(shares);
        assertEq(pool.balanceOf(bob), 0);
        assertEq(pool.balanceOf(address(pool)), shares);
        assertEq(pool.totalRequestedShares(), shares);
        vm.expectRevert(CapitalPool.NoMaturedRequest.selector);
        pool.redeem(shares, bob, bob);
        vm.stopPrank();

        vm.warp(block.timestamp + 14 days);
        usdgFeed.pushNow(1e8);
        aaaFeed.pushNow(200e8);
        bbbFeed.pushNow(50e8);
        assertTrue(pool.isWithdrawable(bob));
        assertEq(pool.maxRedeem(bob), shares);
        assertApproxEqAbs(pool.maxWithdraw(bob), 1_000e6, 1);
        vm.prank(bob);
        uint256 got = pool.redeem(shares / 2, bob, bob);
        assertApproxEqAbs(got, 500e6, 1);
        vm.prank(bob);
        pool.withdraw(400e6, bob, bob);
        assertApproxEqAbs(usdg.balanceOf(bob), 900e6, 2);

        // window expires
        vm.warp(block.timestamp + 7 days + 1);
        assertFalse(pool.isWithdrawable(bob));
    }

    function test_withdraw_onlyFromFreeCapital() public {
        uint256 shares = underwrite(OUTAGE, bob, 100_000e6);
        buy(alice, OUTAGE, address(aaa), 20_000e6, 7 days); // locks 20k
        vm.prank(bob);
        pool.requestWithdraw(shares);
        warpAndRefresh(block.timestamp + 14 days);
        uint256 maxR = pool.maxRedeem(bob);
        assertLt(maxR, shares);
        vm.prank(bob);
        vm.expectRevert();
        pool.redeem(shares, bob, bob);
        vm.prank(bob);
        pool.redeem(maxR, bob, bob);
        assertGe(pool.totalAssets(), pool.lockedCapital());
    }

    function test_withdraw_blockedWhileGuardReportsEvent() public {
        uint256 shares = underwrite(OUTAGE, bob, 1_000e6);
        vm.prank(bob);
        pool.requestWithdraw(shares);
        warpAndRefresh(block.timestamp + 14 days);
        // feed for AAA goes quiet for > maxStaleness of open-market time: outage suspected
        vm.warp(block.timestamp + 27 hours);
        s.outageResolver.report(address(aaa));
        assertTrue(s.outageResolver.withdrawalsBlocked());
        assertEq(pool.maxRedeem(bob), 0);
        vm.prank(bob);
        vm.expectRevert(CapitalPool.NoMaturedRequest.selector);
        pool.redeem(shares, bob, bob);
    }

    function test_cancelWithdraw() public {
        uint256 shares = underwrite(OUTAGE, bob, 1_000e6);
        vm.startPrank(bob);
        pool.requestWithdraw(shares);
        vm.expectRevert(CapitalPool.ExceedsRequest.selector);
        pool.cancelWithdraw(shares + 1);
        pool.cancelWithdraw(shares);
        assertEq(pool.balanceOf(bob), shares);
        vm.expectRevert(CapitalPool.InvalidParam.selector);
        pool.requestWithdraw(0);
        vm.stopPrank();
    }

    function test_revert_redeemByNonOwnerAndExcess() public {
        uint256 shares = underwrite(OUTAGE, bob, 1_000e6);
        vm.prank(bob);
        pool.requestWithdraw(shares);
        warpAndRefresh(block.timestamp + 14 days);
        vm.prank(alice);
        vm.expectRevert(CapitalPool.NotOwner.selector);
        pool.redeem(shares, alice, bob);
        vm.prank(bob);
        vm.expectRevert(CapitalPool.ExceedsRequest.selector);
        pool.redeem(shares + 1, bob, bob);
    }

    function test_premiumVestsLinearly_noJitCapture() public {
        underwrite(OUTAGE, bob, 100_000e6);
        uint256 before = pool.totalAssets();
        buy(alice, OUTAGE, address(aaa), 20_000e6, 90 days);
        // premium not instantly in share price
        assertEq(pool.totalAssets(), before);
        uint256 unvested = pool.unvestedPremium();
        assertGt(unvested, 0);
        vm.warp(block.timestamp + 3.5 days);
        assertApproxEqRel(pool.unvestedPremium(), unvested / 2, 0.001e18);
        vm.warp(block.timestamp + 3.5 days);
        assertEq(pool.unvestedPremium(), 0);
        assertEq(pool.totalAssets(), before + unvested);
    }

    function test_inflationAttackMitigated() public {
        // attacker deposits 1 wei and donates 1M; victim deposit still gets fair shares
        usdg.mint(carol, 1_000_001e6);
        vm.startPrank(carol);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(1, carol);
        usdg.transfer(address(pool), 1_000_000e6);
        vm.stopPrank();
        uint256 shares = underwrite(OUTAGE, bob, 10_000e6);
        assertGt(shares, 0);
        assertApproxEqRel(pool.previewRedeem(shares), 10_000e6, 0.01e18);
    }

    function test_depositCapComplianceAndPause() public {
        vm.prank(address(s.timelock));
        pool.setDepositCap(1_000e6);
        underwrite(OUTAGE, bob, 1_000e6);
        assertEq(pool.maxDeposit(bob), 0);
        usdg.mint(carol, 1e6);
        vm.startPrank(carol);
        usdg.approve(address(pool), 1e6);
        vm.expectRevert();
        pool.deposit(1e6, carol);
        vm.stopPrank();
        vm.prank(address(s.timelock));
        pool.setDepositCap(0);

        vm.prank(address(s.timelock));
        s.compliance.setEnabled(true);
        vm.prank(carol);
        vm.expectRevert(CapitalPool.NotAllowed.selector);
        pool.deposit(1e6, carol);
        vm.prank(carol);
        vm.expectRevert(CapitalPool.NotAllowed.selector);
        pool.mint(1e6, carol);

        vm.prank(address(s.timelock));
        s.compliance.setEnabled(false);
        vm.prank(guardian);
        pool.pause();
        assertEq(pool.maxDeposit(carol), 0);
        vm.prank(carol);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.deposit(1e6, carol);
    }

    function test_registryHooksRestricted() public {
        vm.expectRevert();
        pool.lockCapital(1);
        vm.expectRevert();
        pool.unlockCapital(1);
        vm.expectRevert();
        pool.payout(alice, 1);
        vm.expectRevert();
        pool.addPremium(1);
    }

    function test_lockCapitalCannotExceedAssets() public {
        underwrite(OUTAGE, bob, 1_000e6);
        vm.prank(address(s.registry));
        vm.expectRevert(abi.encodeWithSelector(CapitalPool.InsufficientFreeCapital.selector, 1_001e6, 1_000e6));
        pool.lockCapital(1_001e6);
    }

    function test_admin() public {
        vm.startPrank(address(s.timelock));
        vm.expectRevert(CapitalPool.InvalidParam.selector);
        pool.setCooldown(1 days, 7 days);
        vm.expectRevert(CapitalPool.InvalidParam.selector);
        pool.setCooldown(14 days, 31 days);
        pool.setCooldown(21 days, 3 days);
        assertEq(pool.cooldown(), 21 days);
        pool.setWithdrawGuard(ITriggerResolver(address(0)));
        pool.setCompliance(ICompliance(address(0)));
        vm.stopPrank();
        assertEq(pool.productId(), OUTAGE);
    }
}
