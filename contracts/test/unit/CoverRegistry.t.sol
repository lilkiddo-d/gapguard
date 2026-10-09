// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "../Fixture.sol";
import {CoverRegistry} from "../../src/CoverRegistry.sol";
import {ICoverRegistry} from "../../src/interfaces/ICoverRegistry.sol";
import {ICapitalPool} from "../../src/interfaces/ICapitalPool.sol";
import {ITriggerResolver} from "../../src/interfaces/ITriggerResolver.sol";
import {ICompliance} from "../../src/interfaces/ICompliance.sol";
import {IProjectTokenHooks} from "../../src/interfaces/IProjectTokenHooks.sol";
import {PricingCurve} from "../../src/PricingCurve.sol";
import {CoverNFT} from "../../src/CoverNFT.sol";
import {CapitalPool} from "../../src/CapitalPool.sol";
import {GuardedAccess} from "../../src/governance/GuardedAccess.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract CoverRegistryTest is Fixture {
    function setUp() public override {
        super.setUp();
        underwrite(GAP, bob, 1_000_000e6);
        underwrite(DEPEG, bob, 1_000_000e6);
        underwrite(OUTAGE, bob, 1_000_000e6);
        underwrite(HALT, bob, 1_000_000e6);
    }

    // ------------------------------------------------------------ buying

    function test_buyCover_mintsNftLocksCapitalAndDistributesPremium() public {
        (uint256 q,) = s.registry.quote(GAP, address(aaa), 10_000e6, 30 days);
        uint256 id = buy(alice, GAP, address(aaa), 10_000e6, 30 days);
        assertEq(id, 1);
        assertEq(s.coverNFT.ownerOf(id), alice);
        ICoverRegistry.Cover memory c = cover(id);
        assertEq(uint8(c.status), uint8(ICoverRegistry.CoverStatus.Active));
        assertEq(c.amount, 10_000e6);
        assertEq(c.premium, q);
        assertEq(c.start, T0 + 1 hours);
        assertEq(c.end, T0 + 1 hours + 30 days);
        assertEq(s.pools[GAP].lockedCapital(), 10_000e6);
        assertEq(s.registry.assetExposure(GAP, address(aaa)), 10_000e6);
        assertEq(s.registry.productExposure(GAP), 10_000e6);
        // 10% protocol fee, staker share routed to the pool while no token is set
        assertEq(usdg.balanceOf(address(s.feeCollector)), q * 1_000 / 10_000);
        assertEq(s.pools[GAP].unvestedPremium(), q - q * 1_000 / 10_000);
    }

    function test_buyCover_premiumMatchesCurve() public view {
        // 10k of 1M at 80% cap => util after = 1% ; rate = 300 + 800*100/7000 = 311 bps
        (uint256 premium, uint256 rate) = s.registry.quote(GAP, address(aaa), 10_000e6, 365 days / 5);
        assertEq(rate, 311);
        assertApproxEqAbs(premium, uint256(10_000e6) * 311 / 10_000 / 5, 2);
    }

    function test_buyCover_customFutureStart() public {
        fund(alice, 1_000_000e6);
        uint64 start = uint64(T0 + 3 days);
        vm.prank(alice);
        uint256 id = s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, start, type(uint256).max);
        assertEq(cover(id).start, start);
    }

    function test_revert_cannotBuyForPeriodThatHasStarted() public {
        fund(alice, 1_000_000e6);
        vm.startPrank(alice);
        vm.expectRevert(CoverRegistry.InvalidStart.selector);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, uint64(T0 - 1), type(uint256).max);
        vm.expectRevert(CoverRegistry.InvalidStart.selector);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, uint64(T0), type(uint256).max);
        vm.expectRevert(CoverRegistry.InvalidStart.selector);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, uint64(T0 + 59 minutes), type(uint256).max);
        vm.expectRevert(CoverRegistry.InvalidStart.selector);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, uint64(T0 + 31 days), type(uint256).max);
        vm.stopPrank();
    }

    function test_revert_durationBounds() public {
        fund(alice, 1_000_000e6);
        vm.startPrank(alice);
        vm.expectRevert(CoverRegistry.InvalidDuration.selector);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days - 1, 0, type(uint256).max);
        vm.expectRevert(CoverRegistry.InvalidDuration.selector);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 90 days + 1, 0, type(uint256).max);
        vm.stopPrank();
        vm.expectRevert(CoverRegistry.InvalidDuration.selector);
        s.registry.quote(GAP, address(aaa), 1_000e6, 1 days);
    }

    function test_revert_amountAndAssetChecks() public {
        fund(alice, 1_000_000e6);
        vm.startPrank(alice);
        vm.expectRevert(CoverRegistry.InvalidAmount.selector);
        s.registry.buyCover(GAP, address(aaa), 0, 7 days, 0, type(uint256).max);
        vm.expectRevert(CoverRegistry.InvalidAmount.selector);
        s.registry.buyCover(GAP, address(aaa), 9e6, 7 days, 0, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CoverRegistry.AssetNotAllowed.selector, DEPEG, address(bbb)));
        s.registry.buyCover(DEPEG, address(bbb), 1_000e6, 7 days, 0, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CoverRegistry.ProductInactive.selector, uint8(9)));
        s.registry.buyCover(9, address(aaa), 1_000e6, 7 days, 0, type(uint256).max);
        vm.stopPrank();
    }

    function test_revert_premiumSlippage() public {
        fund(alice, 1_000_000e6);
        (uint256 q,) = s.registry.quote(GAP, address(aaa), 10_000e6, 30 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CoverRegistry.PremiumTooHigh.selector, q));
        s.registry.buyCover(GAP, address(aaa), 10_000e6, 30 days, 0, q - 1);
    }

    function test_exposureLimits_perAssetAndPerProduct() public {
        // per-asset cap 25% of 1M = 250k
        assertEq(s.registry.availableCapacity(GAP, address(aaa)), 250_000e6);
        buy(alice, GAP, address(aaa), 250_000e6, 7 days);
        fund(alice, 1_000_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CoverRegistry.AssetExposureExceeded.selector, 0));
        s.registry.buyCover(GAP, address(aaa), 1e6 * 10, 7 days, 0, type(uint256).max);

        // per-product cap 80%: raise asset cap to 80% and fill up with BBB
        asTimelock();
        s.registry.setProduct(GAP, ICapitalPool(address(s.pools[GAP])), ITriggerResolver(address(s.gapResolver)), 8_000, 8_000, 1 hours, true);
        buy(alice, GAP, address(bbb), 550_000e6, 7 days);
        assertEq(s.registry.availableCapacity(GAP, address(bbb)), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CoverRegistry.CapacityExceeded.selector, 0));
        s.registry.buyCover(GAP, address(bbb), 10e6, 7 days, 0, type(uint256).max);
    }

    function test_availableCapacity_unknownProduct() public view {
        assertEq(s.registry.availableCapacity(7, address(aaa)), 0);
    }

    function test_revert_purchaseBlockedByResolver() public {
        aaa.setPaused(true);
        s.haltResolver.poke(address(aaa));
        fund(alice, 1_000_000e6);
        vm.prank(alice);
        vm.expectRevert(CoverRegistry.PurchaseBlocked.selector);
        s.registry.buyCover(HALT, address(aaa), 1_000e6, 7 days, 0, type(uint256).max);
    }

    function test_compliance_gatesBuy() public {
        vm.prank(address(s.timelock));
        s.compliance.setEnabled(true);
        fund(alice, 1_000_000e6);
        vm.prank(alice);
        vm.expectRevert(CoverRegistry.NotAllowed.selector);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, 0, type(uint256).max);
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(admin);
        s.compliance.setAllowlisted(list, true);
        vm.prank(alice);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, 0, type(uint256).max);
    }

    function test_pause_blocksBuyAndClaim_onlyTimelockUnpauses() public {
        vm.prank(guardian);
        s.registry.pause();
        fund(alice, 1_000_000e6);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, 0, type(uint256).max);
        vm.prank(guardian);
        vm.expectRevert();
        s.registry.unpause();
        asTimelock();
        s.registry.unpause();
        vm.prank(alice);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, 0, type(uint256).max);
    }

    function test_revert_nonGuardianCannotPause() public {
        vm.prank(alice);
        vm.expectRevert();
        s.registry.pause();
    }

    // ------------------------------------------------------------ claims

    function _triggerGap() internal returns (bytes32 eventId) {
        // closing round on Friday, opening round after the weekly reopen 15% lower
        vm.warp(CLOSE - 10 minutes);
        uint80 closeRound = aaaFeed.pushNow(200e8);
        vm.warp(OPEN + 5 minutes);
        uint80 openRound = aaaFeed.pushNow(170e8);
        (eventId,) = s.gapResolver.resolve(address(aaa), WEEK_ID, closeRound, openRound);
    }

    function test_claim_paysCurrentHolderOnce() public {
        uint256 id = buy(alice, GAP, address(aaa), 10_000e6, 14 days);
        bytes32 eventId = _triggerGap();
        assertTrue(s.registry.isClaimable(id, eventId));
        // cover NFT is transferable: carol receives the payout
        vm.prank(alice);
        s.coverNFT.transferFrom(alice, carol, id);
        uint256 before = usdg.balanceOf(carol);
        uint256 paid = s.registry.claim(id, eventId); // permissionless keeper call
        assertEq(paid, 10_000e6);
        assertEq(usdg.balanceOf(carol) - before, 10_000e6);
        assertEq(uint8(cover(id).status), uint8(ICoverRegistry.CoverStatus.Claimed));
        assertEq(s.pools[GAP].lockedCapital(), 0);
        assertEq(s.registry.claimedEvent(id), eventId);
        assertFalse(s.registry.isClaimable(id, eventId));
        vm.expectRevert(abi.encodeWithSelector(CoverRegistry.NotActive.selector, id));
        s.registry.claim(id, eventId);
    }

    function test_revert_claimEventBeforeCoverStart_buyingAfterCloseIsWorthless() public {
        vm.warp(CLOSE - 10 minutes);
        uint80 closeRound = aaaFeed.pushNow(200e8);
        // market closed: an informed buyer tries to buy cover for the weekend gap
        vm.warp(CLOSE + 1 hours);
        aaaFeed.pushNow(200e8);
        uint256 id = buy(alice, GAP, address(aaa), 10_000e6, 14 days);
        assertGt(cover(id).start, CLOSE);
        vm.warp(OPEN + 5 minutes);
        uint80 openRound = aaaFeed.pushNow(150e8);
        (bytes32 eventId, bool triggered) = s.gapResolver.resolve(address(aaa), WEEK_ID, closeRound, openRound);
        assertTrue(triggered);
        assertFalse(s.registry.isClaimable(id, eventId));
        vm.expectRevert(CoverRegistry.EventMismatch.selector);
        s.registry.claim(id, eventId);
    }

    function test_revert_claimMismatch() public {
        uint256 idBbb = buy(alice, GAP, address(bbb), 1_000e6, 14 days);
        bytes32 eventId = _triggerGap(); // AAA event
        vm.expectRevert(CoverRegistry.EventMismatch.selector);
        s.registry.claim(idBbb, eventId);
        assertFalse(s.registry.isClaimable(idBbb, eventId));
    }

    function test_revert_claimNotTriggered() public {
        uint256 id = buy(alice, GAP, address(aaa), 1_000e6, 14 days);
        vm.warp(CLOSE - 10 minutes);
        uint80 c = aaaFeed.pushNow(200e8);
        vm.warp(OPEN + 5 minutes);
        uint80 o = aaaFeed.pushNow(195e8); // 2.5% gap < 10%
        (bytes32 eventId, bool triggered) = s.gapResolver.resolve(address(aaa), WEEK_ID, c, o);
        assertFalse(triggered);
        vm.expectRevert(CoverRegistry.NotTriggered.selector);
        s.registry.claim(id, eventId);
    }

    function test_revert_claimCoverStartingAfterEvent() public {
        fund(alice, 1_000_000e6);
        vm.prank(alice);
        uint256 id = s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, uint64(CLOSE + 1), type(uint256).max);
        bytes32 eventId = _triggerGap();
        vm.expectRevert(CoverRegistry.EventMismatch.selector);
        s.registry.claim(id, eventId);
    }

    // ------------------------------------------------------------ expiry

    function test_expire_releasesCapitalAfterGrace() public {
        uint256 id = buy(alice, GAP, address(aaa), 10_000e6, 7 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.warp(cover(id).end + 14 days);
        vm.expectRevert(CoverRegistry.NotExpired.selector);
        s.registry.expireCovers(ids);
        vm.warp(cover(id).end + 14 days + 1);
        s.registry.expireCovers(ids);
        assertEq(uint8(cover(id).status), uint8(ICoverRegistry.CoverStatus.Expired));
        assertEq(s.pools[GAP].lockedCapital(), 0);
        assertEq(s.registry.productExposure(GAP), 0);
        vm.expectRevert(abi.encodeWithSelector(CoverRegistry.NotActive.selector, id));
        s.registry.expireCovers(ids);
    }

    function test_revert_expireBatchTooLarge() public {
        uint256[] memory ids = new uint256[](101);
        vm.expectRevert(CoverRegistry.BatchTooLarge.selector);
        s.registry.expireCovers(ids);
    }

    // ------------------------------------------------------------ admin

    function test_admin_onlyTimelock() public {
        vm.expectRevert();
        s.registry.setFees(0, 0);
        asTimelock();
        s.registry.setFees(500, 2_000);
        assertEq(s.registry.protocolFeeBps(), 500);
        asTimelock();
        vm.expectRevert(CoverRegistry.InvalidParam.selector);
        s.registry.setFees(2_001, 0);
        asTimelock();
        vm.expectRevert(CoverRegistry.InvalidParam.selector);
        s.registry.setFees(0, 3_001);
    }

    function test_admin_setProductValidation() public {
        ICapitalPool pool = ICapitalPool(address(s.pools[GAP]));
        ITriggerResolver r = ITriggerResolver(address(s.gapResolver));
        vm.startPrank(address(s.timelock));
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        s.registry.setProduct(GAP, ICapitalPool(address(0)), r, 8_000, 2_500, 1 hours, true);
        vm.expectRevert(CoverRegistry.InvalidParam.selector);
        s.registry.setProduct(DEPEG, pool, r, 8_000, 2_500, 1 hours, true); // resolver product mismatch
        vm.expectRevert(CoverRegistry.InvalidParam.selector);
        s.registry.setProduct(GAP, pool, r, 0, 0, 1 hours, true);
        vm.expectRevert(CoverRegistry.InvalidParam.selector);
        s.registry.setProduct(GAP, pool, r, 8_000, 9_000, 1 hours, true);
        vm.expectRevert(CoverRegistry.InvalidParam.selector);
        s.registry.setProduct(GAP, pool, r, 8_000, 2_500, 59 minutes, true);
        // pool asset must be the stablecoin
        CapitalPool other = new CapitalPool(IERC20(address(new MockERC20("X", "X", 6))), "x", "x", GAP, address(this));
        vm.expectRevert(CoverRegistry.InvalidParam.selector);
        s.registry.setProduct(GAP, ICapitalPool(address(other)), r, 8_000, 2_500, 1 hours, true);
        vm.stopPrank();

        // cannot swap a pool that has live exposure
        buy(alice, GAP, address(aaa), 1_000e6, 7 days);
        CapitalPool fresh = new CapitalPool(IERC20(address(usdg)), "y", "y", GAP, address(this));
        asTimelock();
        vm.expectRevert(CoverRegistry.InvalidParam.selector);
        s.registry.setProduct(GAP, ICapitalPool(address(fresh)), r, 8_000, 2_500, 1 hours, true);
    }

    function test_admin_misc() public {
        vm.startPrank(address(s.timelock));
        vm.expectRevert(CoverRegistry.InvalidParam.selector);
        s.registry.setClaimGracePeriod(1 days);
        s.registry.setClaimGracePeriod(30 days);
        assertEq(s.registry.claimGracePeriod(), 30 days);
        s.registry.setMinCoverAmount(1e6);
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        s.registry.setAssetAllowed(GAP, address(0), true);
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        s.registry.setModules(PricingCurve(address(0)), ICompliance(address(0)), IProjectTokenHooks(address(0)), address(1));
        s.registry.setModules(s.pricing, ICompliance(address(0)), IProjectTokenHooks(address(0)), address(s.feeCollector));
        vm.stopPrank();
        assertEq(address(s.registry.compliance()), address(0));
        assertEq(s.registry.getProduct(GAP).maxUtilizationBps, 8_000);
    }

    function test_constructorZeroChecks() public {
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        new CoverRegistry(address(this), IERC20(address(0)), s.coverNFT, s.pricing, address(1));
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        new CoverRegistry(address(this), IERC20(address(usdg)), s.coverNFT, PricingCurve(address(0)), address(1));
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        new CoverRegistry(address(0), IERC20(address(usdg)), s.coverNFT, s.pricing, address(1));
    }

    function test_tokenURI() public {
        uint256 id = buy(alice, GAP, address(aaa), 1_000e6, 7 days);
        string memory uri = s.coverNFT.tokenURI(id);
        assertGt(bytes(uri).length, 100);
        // NFT contract metadata branches for other products
        uint256 id2 = buy(alice, HALT, address(aaa), 1_000e6, 7 days);
        uint256 id3 = buy(alice, OUTAGE, address(aaa), 1_000e6, 7 days);
        uint256 id4 = buy(alice, DEPEG, address(aaa), 1_000e6, 7 days);
        s.coverNFT.tokenURI(id2);
        s.coverNFT.tokenURI(id3);
        s.coverNFT.tokenURI(id4);
        assertTrue(s.coverNFT.supportsInterface(0x80ac58cd));
    }

    function test_nftTransferCompliance() public {
        uint256 id = buy(alice, GAP, address(aaa), 1_000e6, 7 days);
        vm.prank(address(s.timelock));
        s.compliance.setEnabled(true);
        vm.prank(alice);
        vm.expectRevert(CoverNFT.NotAllowed.selector);
        s.coverNFT.transferFrom(alice, carol, id);
    }

    function test_nftAdmin() public {
        vm.expectRevert();
        s.coverNFT.mint(alice, 999);
        vm.startPrank(address(s.timelock));
        vm.expectRevert(CoverNFT.ZeroAddress.selector);
        s.coverNFT.setRegistry(CoverRegistry(address(0)));
        s.coverNFT.setCompliance(ICompliance(address(0)));
        vm.stopPrank();
        vm.expectRevert(CoverNFT.ZeroAddress.selector);
        new CoverNFT(address(0));
    }
}
