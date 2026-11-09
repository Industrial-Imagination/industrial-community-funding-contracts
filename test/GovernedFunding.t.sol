// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import { Test } from "forge-std/Test.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { File, BytecodeSlice } from "ethfs/packages/contracts/src/File.sol";
import { FundingCore } from "../src/FundingCore.sol";
import { CardFiles } from "../src/CardFiles.sol";
import { FundingCardRenderer } from "../src/FundingCardRenderer.sol";
import { SeaDropHarness } from "./SeaDropFunding.t.sol";
import {
  IndustrialImaginationGovernedFunding as Funding
} from "../src/IndustrialImaginationGovernedFunding.sol";
import { FundingCouncil as Council } from "../src/FundingCouncil.sol";

contract GovernedFundingTest is Test {
  Funding funding;
  Council council;
  SeaDropHarness drop;
  FundingCardRenderer renderer;
  address alice = address(0xabc);
  address fee = address(0xfee);
  uint256 start;

  function deploy(uint256 supply) internal returns (Funding f) {
    return deployWithVesting(supply, 180 days);
  }

  /// @dev Shared deployment fixture allows testing the final partial accrual cycle.
  function deployWithVesting(uint256 supply, uint256 vestingDuration) internal returns (Funding f) {
    return new Funding(
      supply,
      supply,
      100003,
      1 days,
      vestingDuration,
      3000,
      address(this),
      address(renderer),
      "IIF",
      "IIF",
      address(drop),
      333,
      fee
    );
  }

  function setUp() public {
    drop = new SeaDropHarness();
    BytecodeSlice[] memory slices = new BytecodeSlice[](1);
    slices[0] = BytecodeSlice(SSTORE2.write(bytes("QUJD")), 1, 5);
    CardFiles.Asset memory asset =
      CardFiles.Asset(SSTORE2.write(abi.encode(File(4, slices))), keccak256(bytes("QUJD")));
    renderer = new FundingCardRenderer(asset, asset, asset);
    funding = deploy(3);
    council = funding.council();
    funding.enableMint();
    funding.enablePublicMint();
    vm.deal(alice, 300009);
    vm.prank(alice);
    drop.mintPublic{ value: 300009 }(address(funding), fee, address(0), 3);
  }

  function begin() internal {
    funding.finalize();
    funding.startPeriod();
    start = council.periodStart();
  }

  function tokens(uint256 first, uint256 count) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](count);
    for (uint256 i; i < count; i++) {
      ids[i] = first + i;
    }
  }

  function review(uint256 cycle, bool approve) internal {
    vm.warp(council.reviewStart(cycle));
    vm.prank(alice);
    council.voteReview(cycle, tokens(1, 1), approve);
    vm.warp(council.reviewDeadline(cycle));
  }

  function open(uint256 failedCycle) internal {
    vm.prank(alice);
    council.openEscapeVote(failedCycle, 1);
  }

  function passEscape() internal {
    uint256 round = council.escapeRound();
    vm.prank(alice);
    council.voteEscape(round, tokens(1, 1), true);
    vm.warp(block.timestamp + 72 hours);
    council.executeEscape(round);
  }

  function escape() internal {
    review(1, false);
    review(2, false);
    open(2);
    passEscape();
  }

  function testOwnerClosesPartialSaleAndCanStartPeriod() public {
    funding = deploy(3);
    council = funding.council();
    vm.expectRevert(FundingCore.MintNotEnabled.selector);
    funding.closeMint();
    funding.enableMint();
    funding.enablePublicMint();

    vm.deal(alice, 200006);
    vm.prank(alice);
    drop.mintPublic{ value: 100003 }(address(funding), fee, address(0), 1);
    vm.expectRevert(FundingCore.MintNotComplete.selector);
    funding.finalize();
    vm.prank(alice);
    vm.expectRevert();
    funding.closeMint();

    uint256 upfront = funding.initialPayoutAccrued();
    uint256 ownerBalance = address(this).balance;
    uint256 locked = address(funding).balance - upfront;
    funding.closeMint();

    assertTrue(funding.mintFinalized());
    assertEq(funding.totalMinted(), 1);
    assertEq(funding.ownerPaidAmount(), upfront);
    assertEq(address(this).balance, ownerBalance + upfront);
    assertEq(address(funding).balance, locked);
    (, uint48 publicStart, uint48 publicEnd,,,) = drop.sales(address(funding));
    assertEq(publicStart, 0);
    assertEq(publicEnd, 0);
    assertEq(drop.roots(address(funding)), bytes32(0));

    vm.prank(address(drop));
    vm.expectRevert(FundingCore.MintPeriodEnded.selector);
    funding.mintSeaDrop(alice, 1);
    vm.expectRevert(FundingCore.MintPeriodEnded.selector);
    funding.enablePublicMint();
    vm.expectRevert(FundingCore.VestingAlreadyStarted.selector);
    funding.closeMint();
    vm.expectRevert(FundingCore.VestingAlreadyStarted.selector);
    funding.finalize();

    assertEq(council.periodStart(), 0);
    funding.startPeriod();
    assertEq(council.periodStart(), block.timestamp);
    assertEq(funding.pendingOwnerShare(), 0);
  }

  function testStartRequiresFinalizationAndOwnerOnce() public {
    vm.expectRevert(Funding.PeriodNotReady.selector);
    funding.startPeriod();
    funding.finalize();
    assertEq(funding.vestingStartTime(), 0);
    assertEq(funding.vestingEndTime(), 0);
    assertEq(council.periodStart(), 0);
    uint256 upfront = funding.ownerPaidAmount();
    assertGt(upfront, 0);
    vm.warp(block.timestamp + 15 days);
    assertEq(funding.vestedPerToken(), 0);
    vm.prank(alice);
    vm.expectRevert();
    funding.startPeriod();
    funding.startPeriod();
    assertEq(funding.vestingStartTime(), council.periodStart());
    vm.expectRevert(Funding.PeriodNotReady.selector);
    funding.startPeriod();
    assertEq(funding.ownerPaidAmount(), upfront);
  }

  function testApprovalCapsCycleAndDoesNotReleaseNextDays() public {
    begin();
    review(1, true);
    vm.warp(start + 35 days);
    funding.claimOwnerShare();
    assertEq(funding.lastPaidVestedPerToken(), funding.LOCKED_PER_TOKEN() / 6);
    uint256 paid = funding.ownerPaidAmount();
    funding.claimOwnerShare();
    assertEq(funding.ownerPaidAmount(), paid);
    vm.warp(start + 59 days);
    funding.claimOwnerShare();
    assertEq(funding.ownerPaidAmount(), paid);
    review(2, true);
    funding.claimOwnerShare();
    assertEq(funding.lastPaidVestedPerToken(), funding.LOCKED_PER_TOKEN() * 2 / 6);
  }

  function testRejectedMonthCatchesUpOnLaterApproval() public {
    begin();
    review(1, false);
    vm.warp(start + 37 days);
    vm.expectRevert(Council.ReviewNotApproved.selector);
    funding.claimOwnerShare();
    review(2, true);
    funding.claimOwnerShare();
    assertEq(funding.lastPaidVestedPerToken(), funding.LOCKED_PER_TOKEN() / 3);
  }

  function testTotalSilenceOnlyAtDay37AndViewMatchesClaim() public {
    begin();
    vm.warp(start + 30 days);
    vm.expectRevert();
    funding.claimOwnerShare();
    vm.warp(start + 33 days);
    vm.expectRevert();
    funding.claimOwnerShare();
    vm.warp(start + 37 days - 1);
    assertEq(funding.pendingOwnerShare(), 0);
    vm.warp(start + 37 days);
    uint256 pending = funding.pendingOwnerShare();
    assertGt(pending, 0);
    uint256 paid = funding.ownerPaidAmount();
    funding.claimOwnerShare();
    assertEq(funding.ownerPaidAmount() - paid, pending);
    assertTrue(council.silencePaid(1));
    assertEq(council.approvedThroughCycle(), 0);
  }

  /// @notice Neither caller class can open refunds before finalization, and council escape retains 100% for holders.
  function testWindDownCannotRunBeforeFinalizationOrAfterCouncilEscape() public {
    vm.expectRevert(Council.InvalidPeriod.selector);
    funding.windDown();
    begin();
    escape();
    vm.expectRevert(Council.Escaped.selector);
    funding.windDown();
    assertEq(funding.windDownOwnerReserve(), 0);
    assertEq(funding.totalUnvested(), address(funding).balance);
  }

  /// @notice A reserve belongs to the activation-time owner even if ownership changes before claiming.
  function testWindDownBeneficiarySurvivesOwnershipTransfer() public {
    funding.finalize();
    vm.warp(council.finalizedAt() + 90 days);
    funding.windDown();
    uint256 reserve = funding.windDownOwnerReserve();
    uint256 balance = address(this).balance;
    funding.transferOwnership(alice);
    vm.prank(alice);
    funding.acceptOwnership();
    vm.prank(alice);
    funding.claimWindDownShare();
    assertEq(address(this).balance, balance + reserve);
    assertEq(funding.windDownOwnerReserve(), 0);
    vm.prank(alice);
    vm.expectRevert(Funding.OwnerPaymentsStopped.selector);
    funding.claimOwnerShare();
  }

  function testSweepExcessRequiresExitEvenWithZeroSupply() public {
    funding = deploy(3);
    vm.deal(address(funding), 1 ether);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.sweepExcessETH();
    assertEq(address(funding).balance, 1 ether);
  }

  function testSweepExcessPreservesRefundsAndPaysCurrentOwnerWithoutTakingReserve() public {
    funding.finalize();
    vm.warp(council.publicWindDownAt());
    funding.windDown();
    uint256 reserve = funding.windDownOwnerReserve();
    assertGt(reserve, 0);

    for (uint256 id = 1; id <= 3; id++) {
      vm.expectRevert(FundingCore.NotAllowed.selector);
      funding.sweepExcessETH();
      vm.prank(alice);
      funding.burn(id);
    }
    assertEq(address(funding).balance, reserve);

    funding.transferOwnership(alice);
    vm.prank(alice);
    funding.acceptOwnership();

    uint256 excess = 123;
    vm.deal(address(funding), reserve + excess);
    uint256 recipientBalance = alice.balance;
    uint256 ownerPaid = funding.ownerPaidAmount();
    vm.prank(address(0xCAFE));
    funding.sweepExcessETH();
    funding.sweepExcessETH();
    assertEq(alice.balance, recipientBalance + excess);
    assertEq(address(funding).balance, reserve);
    assertEq(funding.windDownOwnerReserve(), reserve);
    assertEq(funding.ownerPaidAmount(), ownerPaid);

    uint256 beneficiaryBalance = address(this).balance;
    funding.claimWindDownShare();
    assertEq(address(this).balance, beneficiaryBalance + reserve);
    assertEq(address(funding).balance, 0);
  }

  /// @notice A partial seventh cycle receives its scheduled review before the public grace begins.
  function testPublicBackstopRoundsUpPartialLastCycle() public {
    funding = deployWithVesting(3, 185 days);
    council = funding.council();
    funding.enableMint();
    funding.enablePublicMint();
    vm.deal(alice, 300009);
    vm.prank(alice);
    drop.mintPublic{ value: 300009 }(address(funding), fee, address(0), 3);
    begin();
    assertEq(council.publicWindDownAt(), start + 303 days);
  }

  /// @notice Exact owner inactivity boundary and one-shot reserve allocation before any period starts.
  function testOwnerWindDownBeforeStartRequiresNinetyDays() public {
    funding.finalize();
    uint256 finalized = council.finalizedAt();
    uint256 upfront = funding.ownerPaidAmount();
    uint256 pool = address(funding).balance;
    vm.warp(finalized + 90 days - 1);
    vm.expectRevert(Council.InvalidPeriod.selector);
    funding.windDown();
    vm.warp(finalized + 90 days);
    vm.prank(alice);
    vm.expectRevert(Council.InvalidPeriod.selector);
    funding.windDown();
    funding.windDown();
    assertEq(funding.windDownOwnerReserve(), pool * 500 / 10000);
    assertEq(funding.totalUnvested(), pool - pool * 500 / 10000);
    assertEq(funding.ownerPaidAmount(), upfront);
    vm.expectRevert(Council.Escaped.selector);
    funding.windDown();
    vm.expectRevert(Council.Escaped.selector);
    funding.startPeriod();
  }

  /// @notice An abandoned pre-start fund becomes publicly refundable even when owner and council are absent.
  function testUnstartedPublicBackstopAndLateStartCannotBypassIt() public {
    funding.finalize();
    uint256 deadline = council.publicWindDownAt();
    assertEq(deadline, council.finalizedAt() + 180 days);
    vm.warp(deadline - 1);
    vm.prank(alice);
    vm.expectRevert(Council.InvalidPeriod.selector);
    funding.windDown();
    vm.warp(deadline);
    vm.expectRevert(Council.InvalidPeriod.selector);
    funding.startPeriod();
    vm.prank(alice);
    funding.windDown();
    assertEq(funding.windDownBeneficiary(), address(this));
    assertTrue(council.escapeActivated());
  }

  /// @notice The final voting window closes on day 183, with public exit on day 273 for a 180-day stream.
  function testStartedPublicBackstopStopsClaimsAtExactDeadline() public {
    begin();
    assertEq(council.publicWindDownAt(), start + 273 days);
    vm.warp(start + 273 days - 1);
    assertGt(funding.pendingOwnerShare(), 0);
    vm.prank(alice);
    vm.expectRevert(Council.InvalidPeriod.selector);
    funding.windDown();
    vm.warp(start + 273 days);
    assertEq(funding.pendingOwnerShare(), 0);
    vm.expectRevert(Council.Escaped.selector);
    funding.claimOwnerShare();
    vm.prank(alice);
    funding.windDown();
    vm.prank(alice);
    vm.expectRevert(Council.Escaped.selector);
    council.voteReview(10, tokens(1, 1), true);
  }

  /// @notice Silence payments cannot keep resetting the inactivity timer.
  function testSilenceDoesNotResetOwnerInactivity() public {
    begin();
    vm.warp(start + 30 days);
    vm.warp(start + 67 days);

    funding.claimOwnerShare();
    assertEq(council.lastMajorityDecisionAt(), 0);
    vm.warp(start + 90 days);
    funding.windDown();
    assertTrue(council.escapeActivated());
  }

  /// @notice Both approval and rejection count as council activity; a qualified escape remains first in line.
  function testMajorityApprovalResetsOwnerInactivity() public {
    begin();
    review(1, true);
    assertEq(council.lastMajorityDecisionAt(), start + 33 days);
    vm.warp(start + 123 days - 1);
    vm.expectRevert(Council.InvalidPeriod.selector);
    funding.windDown();
    vm.warp(start + 123 days);
    funding.windDown();
  }

  /// @notice Two consecutive rejections preserve guardian escape priority until the public backstop.
  function testRejectedPairKeepsPriorityOverOwnerWindDown() public {
    begin();
    review(1, false);
    review(2, false);
    vm.warp(start + 157 days);
    funding.claimOwnerShareForCycle(3);
    vm.expectRevert(Council.EscapeHasPriority.selector);
    funding.windDown();
    // The fixed public deadline still provides an exit if no escape vote is completed.
    vm.warp(council.publicWindDownAt());
    vm.prank(alice);
    funding.windDown();
  }

  /// @notice A failed owner transfer cannot prevent holders from burning for the separate refund pool.
  function testRejectingBeneficiaryDoesNotBlockRefunds() public {
    funding.finalize();
    address rejecting = address(0xdead);
    vm.etch(rejecting, hex"60006000fd");
    funding.transferOwnership(rejecting);
    vm.prank(rejecting);
    funding.acceptOwnership();
    uint256 deadline = council.publicWindDownAt();
    vm.warp(deadline);
    funding.windDown();
    uint256 reserve = funding.windDownOwnerReserve();
    assertEq(funding.windDownBeneficiary(), rejecting);
    // The shared transfer helper force-sends ETH even when the recipient reverts.
    funding.claimWindDownShare();
    assertEq(rejecting.balance, reserve);
    assertEq(funding.windDownOwnerReserve(), 0);
    for (uint256 id = 1; id <= 3; id++) {
      vm.prank(alice);
      funding.burn(id);
    }
    assertEq(address(funding).balance, 0);
    assertEq(funding.totalUnvested(), 0);
  }

  /// @notice Conservation holds for all burn orders, reserve claim timings, and late unsolicited ETH.
  function testFuzzWindDownConservation(uint8 order, bool claimFirst, uint96 extra) public {
    begin();
    review(1, true);
    funding.claimOwnerShare();
    vm.warp(start + 123 days);
    uint256 pool = address(funding).balance;
    funding.windDown();
    uint256 reserve = pool * 500 / 10000;
    assertEq(funding.windDownOwnerReserve(), reserve);
    vm.deal(address(funding), pool + uint256(extra));
    uint256 paidBefore = funding.ownerPaidAmount();
    if (claimFirst) funding.claimWindDownShare();
    uint256 refunded;
    for (uint256 i; i < 3; i++) {
      uint256 id = (uint256(order) % 3 + i) % 3 + 1;
      uint256 before = alice.balance;
      vm.prank(alice);
      funding.burn(id);
      refunded += alice.balance - before;
    }
    if (!claimFirst) funding.claimWindDownShare();
    funding.claimWindDownShare();
    assertEq(funding.ownerPaidAmount() - paidBefore, reserve);
    assertEq(refunded + reserve, pool + uint256(extra));
    assertEq(address(funding).balance, 0);
  }

  function testNoRefundBeforeEscapeEvenAfterVestingEnds() public {
    begin();
    vm.warp(start + 200 days);
    vm.prank(alice);
    vm.expectRevert(Funding.RefundUnavailable.selector);
    funding.burn(1);
    assertEq(funding.getRemainingLockedEth(1), 0);
  }

  function testTwoRejectionsOnlyEnableSeparateVoteAndApprovalResets() public {
    begin();
    review(1, false);
    vm.prank(alice);
    vm.expectRevert();
    council.openEscapeVote(1, 1);
    review(2, false);
    assertFalse(council.escapeActivated());
    vm.warp(council.reviewStart(3) + 1 hours);
    open(2);
    vm.prank(alice);
    council.voteEscape(1, tokens(1, 1), true);
    vm.prank(alice);
    council.voteReview(3, tokens(1, 1), true);

    vm.warp(council.reviewDeadline(3) + 1 hours);
    vm.expectRevert(Council.EscapeNotEligible.selector);
    council.executeEscape(1);
    assertGt(funding.pendingOwnerShare(), 0);
    funding.claimOwnerShare(); // Record the approval.
    vm.expectRevert(Council.EscapeNotEligible.selector);
    council.executeEscape(1);
  }

  function testNonconsecutiveFailuresAndSilentCycleCannotQualify() public {
    begin();
    review(1, false);
    review(3, false);
    vm.prank(alice);
    vm.expectRevert();
    council.openEscapeVote(3, 1);
  }

  function testEscapeRefundsAllRemainingFundsAndDust() public {
    begin();
    uint256 net = funding.totalNetReceived();
    escape();
    assertTrue(council.escapeActivated());
    uint256 pool = address(funding).balance;
    assertEq(funding.escapePoolAtActivation(), pool);
    assertEq(funding.totalUnvested(), pool);
    assertEq(funding.pendingOwnerShare(), 0);
    vm.expectRevert(Funding.OwnerPaymentsStopped.selector);
    funding.claimOwnerShare();
    vm.prank(alice);
    vm.expectRevert();
    funding.claimOwnerShare();
    uint256 refunds;
    for (uint256 id = 1; id <= 3; id++) {
      uint256 before = alice.balance;
      uint256 quoted = funding.getRemainingLockedEth(id);
      vm.prank(alice);
      funding.burn(id);
      assertEq(alice.balance - before, quoted);
      refunds += quoted;
    }
    assertEq(refunds, pool);
    assertEq(funding.ownerPaidAmount() + refunds, net);
    assertEq(address(funding).balance, 0);
    assertEq(funding.activeSupply(), 0);
    vm.expectRevert();
    funding.tokenURI(1);
    vm.prank(alice);
    vm.expectRevert(Council.Escaped.selector);
    council.voteReview(3, tokens(1, 1), true);
  }

  function testEscapeAfterApprovedButUnclaimedMonthIncludesItsMoney() public {
    begin();
    review(1, true);
    review(2, false);
    review(3, false);
    open(3);
    uint256 pool = address(funding).balance;
    uint256 authorized = funding.pendingOwnerShare();
    assertGt(authorized, 0);
    passEscape();
    assertEq(funding.escapePoolAtActivation(), pool);
    assertGt(pool, pool - authorized);
  }

  function testPassedEscapeBlocksClaimsAndSurvivesLaterReviewApproval() public {
    begin();
    review(1, true);
    review(2, false);
    review(3, false);
    open(3);
    vm.prank(alice);
    council.voteEscape(1, tokens(1, 1), true);
    (uint256 openedAt,,,) = council.escapeBallots(1);
    uint256 closesAt = openedAt + council.VOTING();
    vm.warp(closesAt - 1);
    assertGt(funding.pendingOwnerShare(), 0);
    funding.claimOwnerShareForCycle(1);

    vm.warp(closesAt);
    vm.expectRevert(Council.EscapeHasPriority.selector);
    funding.claimOwnerShareForCycle(1);
    review(4, true);
    assertEq(funding.pendingOwnerShare(), 0);
    vm.expectRevert(Council.EscapeHasPriority.selector);
    funding.claimOwnerShare();

    // A later review vote records cycle 4's approval. It still cannot undo the passed escape.
    review(5, false);
    vm.warp(council.publicWindDownAt());
    vm.expectRevert(Council.EscapeHasPriority.selector);
    funding.windDown();
    uint256 pool = address(funding).balance;
    vm.prank(address(0xCAFE));
    council.executeEscape(1);
    assertEq(funding.escapePoolAtActivation(), pool);
    assertEq(funding.windDownOwnerReserve(), 0);
  }

  function testPublicBackstopWaitsForOpenEscapeBallot() public {
    begin();
    review(1, false);
    review(2, false);
    uint256 deadline = council.publicWindDownAt();
    vm.warp(deadline - 1);
    open(2);

    vm.warp(deadline);
    vm.prank(alice);
    vm.expectRevert(Council.VotingClosed.selector);
    council.openEscapeVote(2, 1);
    vm.prank(alice);
    vm.expectRevert(Council.EscapeVoteActive.selector);
    funding.windDown();
    vm.prank(alice);
    council.voteEscape(1, tokens(1, 1), true);

    vm.warp(deadline - 1 + council.VOTING());
    vm.prank(alice);
    vm.expectRevert(Council.EscapeHasPriority.selector);
    funding.windDown();
    council.executeEscape(1);
    assertEq(funding.windDownOwnerReserve(), 0);
  }

  function testBackstopAllowsWindDownAfterUnsuccessfulEscape() public {
    begin();
    review(1, false);
    review(2, false);
    uint256 deadline = council.publicWindDownAt();
    vm.warp(deadline - 1);
    open(2);
    vm.warp(deadline - 1 + council.VOTING());
    vm.prank(alice);
    vm.expectRevert(Council.VotingClosed.selector);
    council.openEscapeVote(2, 1);

    uint256 pool = address(funding).balance;
    vm.prank(alice);
    funding.windDown();
    assertEq(funding.windDownOwnerReserve(), pool / 20);
  }

  function testOldSilentCycleClaimableWhenLatestReviewRejected() public {
    begin();
    review(2, false);
    funding.claimOwnerShareForCycle(1);
    assertEq(funding.lastPaidVestedPerToken(), funding.LOCKED_PER_TOKEN() / 6);
  }

  function testFuzzPaidPlusRefundsEqualsNet(uint8 paidCycles, uint8 order) public {
    begin();
    uint256 approved = bound(paidCycles, 0, 3);
    if (approved != 0) {
      review(approved, true);
      funding.claimOwnerShare();
    }
    review(approved + 1, false);
    review(approved + 2, false);
    open(approved + 2);
    passEscape();
    uint256 refunded;
    for (uint256 i; i < 3; i++) {
      uint256 id = (uint256(order) % 3 + i) % 3 + 1;
      uint256 before = alice.balance;
      vm.prank(alice);
      funding.burn(id);
      refunded += alice.balance - before;
    }
    assertEq(funding.ownerPaidAmount() + refunded, funding.totalNetReceived());
    assertEq(address(funding).balance, 0);
  }

  function testQuorumSnapshotLowTurnoutTieAndBatchOwnership() public {
    funding = deploy(25);
    council = funding.council();
    funding.enableMint();
    funding.enablePublicMint();
    drop.mintPublic{ value: 100003 }(address(funding), fee, address(0), 1);
    vm.deal(alice, 2400072);
    vm.prank(alice);
    drop.mintPublic{ value: 2400072 }(address(funding), fee, address(0), 24);
    begin();
    assertEq(council.eligibleSupply(), 24);
    assertEq(council.quorum(), 3);
    vm.expectRevert(Council.VotingClosed.selector);
    council.voteReview(1, tokens(1, 1), true);
    vm.warp(council.reviewStart(1));
    vm.expectRevert(Council.Unauthorized.selector);
    council.voteReview(1, tokens(1, 1), true);
    vm.prank(address(0xbeef));
    vm.expectRevert(Council.Unauthorized.selector);
    council.voteReview(1, tokens(2, 1), true);
    vm.prank(alice);
    council.voteReview(1, tokens(2, 1), true);
    vm.prank(alice);
    vm.expectRevert(Council.AlreadyVoted.selector);
    council.voteReview(1, tokens(2, 2), false);
    assertFalse(council.hasVotedReview(1, 3));
    vm.warp(start + 37 days - 1);
    vm.expectRevert(Council.ReviewNotApproved.selector);
    funding.claimOwnerShareForCycle(1);
    vm.warp(start + 37 days);
    funding.claimOwnerShareForCycle(1);
    assertEq(council.lastMajorityDecisionAt(), 0);

    vm.warp(council.reviewStart(2));
    vm.prank(alice);
    council.voteReview(2, tokens(2, 2), true);
    vm.prank(alice);
    council.voteReview(2, tokens(4, 2), false);
    vm.warp(start + 67 days);
    assertEq(uint256(council.outcome(2)), uint256(Council.Outcome.Unresolved));
    vm.expectRevert(Council.ReviewNotApproved.selector);
    funding.claimOwnerShareForCycle(2);

    vm.warp(council.reviewStart(3));
    vm.prank(alice);
    council.voteReview(3, tokens(2, 2), true);
    vm.prank(alice);
    council.voteReview(3, tokens(4, 1), false);
    vm.expectRevert(Council.ReviewNotApproved.selector);
    funding.claimOwnerShareForCycle(3);
    vm.warp(council.reviewDeadline(3));
    funding.claimOwnerShareForCycle(3);
    assertEq(funding.lastPaidVestedPerToken(), funding.LOCKED_PER_TOKEN() / 2);
  }

  function testIsolatedSilenceAndOutOfOrderCatchUpConservePrincipal() public {
    begin();
    review(1, false);
    vm.warp(start + 67 days);
    funding.claimOwnerShare();
    uint256 locked = funding.LOCKED_PER_TOKEN();
    uint256 second = locked * 2 / 6 - locked / 6;
    assertEq(funding.lastPaidVestedPerToken(), second);
    assertEq(council.approvedThroughCycle(), 0);
    review(3, true);
    vm.warp(start + 127 days);
    funding.claimOwnerShareForCycle(4);
    uint256 fourth = locked * 4 / 6 - locked * 3 / 6;
    assertEq(funding.lastPaidVestedPerToken(), second + fourth);
    funding.claimOwnerShare();
    assertEq(funding.lastPaidVestedPerToken(), locked * 4 / 6);
    funding.claimOwnerShareForCycle(2);
    funding.claimOwnerShareForCycle(4);
    assertEq(funding.lastPaidVestedPerToken(), locked * 4 / 6);
    review(6, true);
    funding.claimOwnerShare();
    assertEq(funding.lastPaidVestedPerToken(), locked);
    assertEq(address(funding).balance, 0);
  }

  function testEscapeNeedsClosedQuorateMajorityAndCanBeRetried() public {
    begin();
    review(1, false);
    review(2, false);
    open(2);
    vm.expectRevert(Council.VotingClosed.selector);
    council.executeEscape(1);
    vm.warp(block.timestamp + 72 hours);
    vm.expectRevert(Council.EscapeNotEligible.selector);
    council.executeEscape(1);
    open(2);
    passEscape();
    assertTrue(council.escapeActivated());
  }

  /// @notice Repeating an isolated payment must not forgive any earlier unpaid installment.
  /// @notice Even unanimous opposition below quorum permits only its own installment.
  function testBelowQuorumOppositionFallbackAndCatchUp() public {
    funding = deploy(25);
    council = funding.council();
    funding.enableMint();
    funding.enablePublicMint();
    vm.deal(alice, 2500075);
    vm.prank(alice);
    drop.mintPublic{ value: 2500075 }(address(funding), fee, address(0), 25);
    begin();
    uint256 upfront = funding.ownerPaidAmount();
    vm.warp(council.reviewStart(1));
    vm.prank(alice);
    council.voteReview(1, tokens(1, 3), false);
    vm.warp(council.reviewStart(2));
    vm.prank(alice);
    council.voteReview(2, tokens(1, 2), false);
    vm.warp(start + 67 days - 1);
    vm.expectRevert(Council.ReviewNotApproved.selector);
    funding.claimOwnerShareForCycle(2);
    vm.warp(start + 67 days);
    uint256 installment = funding.LOCKED_PER_TOKEN() / 3 - funding.LOCKED_PER_TOKEN() / 6;
    assertEq(funding.pendingOwnerShare(), installment * 25);
    funding.claimOwnerShare();
    funding.claimOwnerShareForCycle(2);
    assertEq(council.paidThroughCycle(), 0);
    assertEq(funding.ownerPaidAmount(), upfront + installment * 25);
    vm.expectRevert(Council.ReviewNotApproved.selector);
    funding.claimOwnerShareForCycle(1);
    vm.prank(alice);
    vm.expectRevert(Council.EscapeNotEligible.selector);
    council.openEscapeVote(2, 1);
    vm.warp(council.reviewStart(3));
    vm.prank(alice);
    council.voteReview(3, tokens(1, 3), true);
    vm.warp(council.reviewDeadline(3));
    funding.claimOwnerShare();
    assertEq(funding.lastPaidVestedPerToken(), funding.LOCKED_PER_TOKEN() / 2);
    assertEq(funding.ownerPaidAmount() + address(funding).balance, funding.totalNetReceived());
  }

  function testRepeatedSilenceClaimDoesNotAdvanceCumulativeCheckpoint() public {
    begin();
    review(1, false);
    vm.warp(start + 67 days);
    funding.claimOwnerShareForCycle(2);
    uint256 paid = funding.ownerPaidAmount();
    funding.claimOwnerShareForCycle(2);
    funding.claimOwnerShare();
    assertEq(funding.ownerPaidAmount(), paid);
    assertEq(council.paidThroughCycle(), 0, "silence is not cumulative approval");
    review(3, true);
    funding.claimOwnerShare();
    assertEq(funding.lastPaidVestedPerToken(), funding.LOCKED_PER_TOKEN() / 2);
    review(6, true);
    funding.claimOwnerShare();
    assertEq(address(funding).balance, 0, "no skipped principal");
  }

  function onERC721Received(address, address, uint256, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return this.onERC721Received.selector;
  }

  receive() external payable { }
}
