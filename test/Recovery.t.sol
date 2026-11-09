// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import { GovernedFundingTest } from "./GovernedFunding.t.sol";
import { FundingRecovery } from "../src/FundingRecovery.sol";
import { FundingCore } from "../src/FundingCore.sol";

/// @notice Recovery tests use fresh, unstarted collections without changing existing economics.
contract RecoveryTest is GovernedFundingTest {
  FundingRecovery private recovery;
  address private backupWallet = address(0xbac);

  function fresh() private {
    funding = deploy(3);
    council = funding.council();
    recovery = funding.recovery();
  }

  function designate() private {
    fresh();
    recovery.nominateBackup(backupWallet);
    vm.prank(backupWallet);
    recovery.acceptBackup();
  }

  function testRecoveryDeadlineCancellationAndRetry() public {
    designate();
    vm.prank(backupWallet);
    recovery.requestRecovery();
    uint256 deadline = recovery.readyAt();
    vm.warp(deadline - 1);
    vm.prank(backupWallet);
    vm.expectRevert(FundingRecovery.RecoveryNotReady.selector);
    recovery.executeRecovery();
    vm.warp(deadline + 1);
    recovery.cancelRecovery();
    vm.prank(backupWallet);
    vm.expectRevert(FundingRecovery.RecoveryNotReady.selector);
    recovery.executeRecovery();
    vm.prank(backupWallet);
    recovery.requestRecovery();
    assertEq(recovery.readyAt(), deadline + 1 + 7 days);
    vm.warp(recovery.readyAt());
    vm.prank(backupWallet);
    recovery.executeRecovery();
    assertEq(funding.owner(), backupWallet);
    assertEq(recovery.backup(), address(0));
    assertEq(recovery.readyAt(), 0);
  }

  function testNormalHandoverInvalidatesBackupEvenIfOriginalOwnerReturns() public {
    designate();
    vm.prank(backupWallet);
    recovery.requestRecovery();
    funding.transferOwnership(alice);
    vm.prank(alice);
    funding.acceptOwnership();
    vm.prank(alice);
    funding.transferOwnership(address(this));
    funding.acceptOwnership();
    assertEq(recovery.backup(), address(0));
    vm.prank(backupWallet);
    vm.expectRevert(FundingRecovery.Unauthorized.selector);
    recovery.executeRecovery();
  }

  function testRecoveryClearsPendingNormalHandoverAndLeavesFundsUntouched() public {
    designate();
    funding.enableMint();
    funding.enablePublicMint();
    vm.deal(alice, 300009);
    vm.prank(alice);
    drop.mintPublic{ value: 300009 }(address(funding), fee, address(0), 3);
    funding.finalize();
    funding.startPeriod();
    uint256 pool = address(funding).balance;
    uint256 paid = funding.ownerPaidAmount();
    address excluded = council.excludedOwner();
    funding.transferOwnership(alice);
    vm.prank(backupWallet);
    recovery.requestRecovery();
    vm.warp(recovery.readyAt());
    vm.prank(backupWallet);
    recovery.executeRecovery();
    vm.prank(alice);
    vm.expectRevert();
    funding.acceptOwnership();
    assertEq(address(funding).balance, pool);
    assertEq(funding.ownerPaidAmount(), paid);
    assertEq(council.excludedOwner(), excluded);
    vm.prank(backupWallet);
    vm.expectRevert();
    funding.claimOwnerShare();
  }

  function testDesignationConsentAndAuthorization() public {
    fresh();
    vm.prank(alice);
    vm.expectRevert(FundingRecovery.Unauthorized.selector);
    recovery.nominateBackup(backupWallet);
    vm.expectRevert(FundingRecovery.InvalidBackup.selector);
    recovery.nominateBackup(address(this));
    recovery.nominateBackup(backupWallet);
    vm.prank(alice);
    vm.expectRevert(FundingRecovery.Unauthorized.selector);
    recovery.acceptBackup();
    vm.prank(backupWallet);
    vm.expectRevert(FundingRecovery.Unauthorized.selector);
    recovery.requestRecovery();
    vm.prank(backupWallet);
    recovery.acceptBackup();
    funding.enableMint();
    vm.expectRevert(FundingRecovery.ConfigurationClosed.selector);
    recovery.nominateBackup(alice);
    vm.prank(alice);
    vm.expectRevert(FundingRecovery.Unauthorized.selector);
    recovery.cancelRecovery();
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.recoverOwnership(alice);
  }
}
