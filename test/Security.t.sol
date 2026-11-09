// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { SeaDrop } from "seadrop/src/SeaDrop.sol";
import { MintParams, PublicDrop, AllowListData } from "seadrop/src/lib/SeaDropStructs.sol";
import {
  ERC721SeaDropStructsErrorsAndEvents
} from "seadrop/src/lib/ERC721SeaDropStructsErrorsAndEvents.sol";
import { INonFungibleSeaDropToken } from "seadrop/src/interfaces/INonFungibleSeaDropToken.sol";
import { File, BytecodeSlice } from "ethfs/packages/contracts/src/File.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { FundingCore } from "../src/FundingCore.sol";
import { FundingCouncil } from "../src/FundingCouncil.sol";
import { CardFiles } from "../src/CardFiles.sol";
import { FundingCardRenderer } from "../src/FundingCardRenderer.sol";
import {
  IndustrialImaginationGovernedFunding as Funding
} from "../src/IndustrialImaginationGovernedFunding.sol";
import {
  IndustrialImaginationFunding as DirectFunding
} from "../src/IndustrialImaginationFunding.sol";

/// @dev Adversarial wallet used as NFT receiver, ETH recipient, owner or fee recipient.
contract SecurityWallet {
  address public target;
  bytes public attack;
  bool public attempted;
  bool public succeeded;
  bool public rejectETH;
  bool public rejectNFT;

  function configure(address target_, bytes calldata attack_, bool rejectETH_, bool rejectNFT_)
    external
  {
    target = target_;
    attack = attack_;
    rejectETH = rejectETH_;
    rejectNFT = rejectNFT_;
    attempted = false;
    succeeded = false;
  }

  function _attack() private {
    if (attack.length != 0) {
      attempted = true;
      (succeeded,) = target.call(attack);
    }
  }

  function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
    require(!rejectNFT, "reject NFT");
    _attack();
    return this.onERC721Received.selector;
  }

  receive() external payable {
    require(!rejectETH, "reject ETH");
    _attack();
  }
}

/// @notice Regression and adversarial tests against the actual pinned SeaDrop implementation.
contract SecurityTest is Test {
  SeaDrop internal drop;
  FundingCardRenderer internal renderer;
  Funding internal funding;
  address internal alice = address(0xa11ce);
  address internal fee = address(0xfee);

  function setUp() public {
    // Isolated fork calls otherwise inherit a nonzero network gas price. These
    // assertions measure mint/refund principal; transaction gas is a separate cost.
    vm.txGasPrice(0);
    vm.fee(0);
    vm.warp(1_800_000_000);
    if (vm.envOr("TEST_CANONICAL_SEADROP", false)) {
      // Used only with forge test --fork-url. All writes remain in Foundry's local EVM.
      require(block.chainid == 8453 || block.chainid == 84532, "unexpected fork network");
      drop = SeaDrop(0x00005EA00Ac477B1030CE78506496e8C2dE24bf5);
      bytes32 expected = block.chainid == 8453
        ? bytes32(0x2151e8d092f04e5cf00576bf5e6b92a0fc15b0013dc8c08b68934048d39ac1fc)
        : bytes32(0x7ebd6750c54fd6e4667af4d3310cf02bc420606f6e3eaed9654127047f5166c0);
      assertEq(address(drop).codehash, expected, "unreviewed SeaDrop runtime");
    } else {
      drop = new SeaDrop();
    }
    BytecodeSlice[] memory slices = new BytecodeSlice[](1);
    slices[0] = BytecodeSlice(SSTORE2.write(bytes("QUJD")), 1, 5);
    CardFiles.Asset memory a =
      CardFiles.Asset(SSTORE2.write(abi.encode(File(4, slices))), keccak256(bytes("QUJD")));
    renderer = new FundingCardRenderer(a, a, a);
    funding = deploy(25, 100003, 333, 3000, 185 days, fee);
    vm.deal(alice, 100 ether);
  }

  function deploy(
    uint256 supply,
    uint256 price,
    uint16 fees,
    uint256 upfront,
    uint256 duration,
    address recipient
  ) internal returns (Funding f) {
    f = new Funding(
      supply,
      supply,
      price,
      1 days,
      duration,
      upfront,
      address(this),
      address(renderer),
      "Industrial",
      "IIF",
      address(drop),
      fees,
      recipient
    );
  }

  /// @notice Exercise the approved release size and price against the real SeaDrop source.
  /// @dev The fee and upfront rates here are accounting fixtures, not new production terms.
  function testApprovedSaleTermsAndPublicMintSettlement() public {
    funding = deploy(2500, 0.008 ether, 1000, 3000, 180 days, fee);
    assertEq(funding.MAX_SUPPLY(), 2500);
    assertEq(funding.GROSS_MINT_PRICE(), 0.008 ether);
    assertEq(funding.MAX_SUPPLY() * funding.GROSS_MINT_PRICE(), 20 ether);
    funding.enableMint();
    vm.prank(address(drop));
    vm.expectRevert(FundingCore.MintNotEnabled.selector);
    funding.mintSeaDrop(alice, 1);
    funding.enablePublicMint();
    vm.prank(alice);
    drop.mintPublic{ value: 0.024 ether }(address(funding), fee, address(0), 3);
    assertEq(funding.totalMinted(), 3);
    assertEq(funding.totalNetReceived(), 0.0216 ether);
    assertEq(funding.pendingNetProceeds(), 0);
    assertEq(fee.balance, 0.0024 ether);
    funding.closeMint();
    assertEq(funding.ownerPaidAmount(), 0.00648 ether);
    assertEq(address(funding).balance, 0.01512 ether);
    funding.startPeriod();
    assertEq(funding.council().eligibleSupply(), 3);
  }

  function testGovernedConstructorEmitsSeaDropStudioIndexingEvent() public {
    vm.recordLogs();
    Funding collection = deploy(25, 100003, 333, 3000, 185 days, fee);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    bytes32 signature = keccak256("SeaDropTokenDeployed()");
    uint256 deployments;
    for (uint256 i; i < logs.length; ++i) {
      Vm.Log memory entry = logs[i];
      if (
        entry.emitter == address(collection) && entry.topics.length == 1
          && entry.topics[0] == signature && entry.data.length == 0
      ) ++deployments;
    }
    assertEq(deployments, 1, "collection must emit the SeaDrop deployment event once");
  }

  function start() internal {
    funding.enableMint();
    funding.enablePublicMint();
  }

  function mint(address minter, uint256 quantity) internal {
    uint256 value = funding.GROSS_MINT_PRICE() * quantity;
    address recipient = funding.FEE_RECIPIENT();
    vm.prank(minter);
    drop.mintPublic{ value: value }(address(funding), recipient, address(0), quantity);
  }

  /// @dev Set the expected revert after the getter calls needed to assemble the mint.
  function mintReverts(address minter, uint256 quantity) internal {
    uint256 value = funding.GROSS_MINT_PRICE() * quantity;
    address recipient = funding.FEE_RECIPIENT();
    vm.prank(minter);
    vm.expectRevert();
    drop.mintPublic{ value: value }(address(funding), recipient, address(0), quantity);
  }

  function ids(uint256 id) internal pure returns (uint256[] memory result) {
    result = new uint256[](1);
    result[0] = id;
  }

  function testRealSeaDropSameBlockBurstHasNoPendingSettlementLeak() public {
    start();
    uint256 height = block.number;
    uint256 timestamp = block.timestamp;
    uint256 net = 100003 - uint256(100003) * 333 / 10000;
    for (uint256 i; i < 25; ++i) {
      address holder = address(uint160(1000 + i));
      vm.deal(holder, 100003);
      mint(holder, 1);
      assertEq(funding.ownerOf(i + 1), holder);
      assertEq(funding.pendingNetProceeds(), 0);
      assertEq(funding.totalNetReceived(), net * (i + 1));
      assertEq(address(funding).balance, net * (i + 1));
    }
    assertEq(block.number, height);
    assertEq(block.timestamp, timestamp);
    mintReverts(alice, 1);
    assertEq(funding.totalSupply(), 25);
  }

  function testRealSeaDropReceiverAndFeeCannotFinalizeBeforeSettlement() public {
    SecurityWallet probe = new SecurityWallet();
    funding = deploy(2, 100003, 333, 3000, 180 days, address(probe));
    probe.configure(address(funding), abi.encodeCall(funding.finalize, ()), false, false);
    start();
    vm.deal(address(probe), 200006);
    mint(address(probe), 2);
    assertTrue(probe.attempted());
    assertFalse(probe.succeeded());
    assertFalse(funding.vestingStarted());
    assertEq(funding.pendingNetProceeds(), 0);
    assertEq(funding.totalNetReceived(), 200006 - uint256(200006) * 333 / 10000);
    funding.finalize();
  }

  function testRealSeaDropRejectingFeeRollsBackMintAndValue() public {
    SecurityWallet rejecting = new SecurityWallet();
    rejecting.configure(address(0), "", true, false);
    funding = deploy(2, 100003, 333, 3000, 180 days, address(rejecting));
    start();
    uint256 balance = alice.balance;
    uint256 dropBalance = address(drop).balance;
    mintReverts(alice, 1);
    assertEq(alice.balance, balance);
    assertEq(funding.totalMinted(), 0);
    assertEq(funding.totalSupply(), 0);
    assertEq(funding.mintedBy(alice), 0);
    assertEq(funding.initialPayoutAccrued(), 0);
    assertEq(funding.pendingNetProceeds(), 0);
    assertEq(address(funding).balance, 0);
    assertEq(address(drop).balance, dropBalance);
  }

  function testRealSeaDropRejectingNFTRollsBackMintAndValue() public {
    SecurityWallet rejecting = new SecurityWallet();
    rejecting.configure(address(0), "", false, true);
    start();
    uint256 feeBalance = fee.balance;
    vm.deal(address(rejecting), 100003);
    mintReverts(address(rejecting), 1);
    assertEq(address(rejecting).balance, 100003);
    assertEq(funding.totalMinted(), 0);
    assertEq(funding.pendingNetProceeds(), 0);
    assertEq(fee.balance, feeBalance);
  }

  function testRealSeaDropSponsoredMintAndWrongFeeRecipient() public {
    start();
    vm.expectRevert();
    drop.mintPublic{ value: 100003 }(address(funding), fee, alice, 1);
    funding.updatePayer(address(drop), address(this), true);
    vm.expectRevert();
    drop.mintPublic{ value: 100003 }(address(funding), address(123), alice, 1);
    drop.mintPublic{ value: 100003 }(address(funding), fee, alice, 1);
    assertEq(funding.ownerOf(1), alice);
    assertEq(funding.mintedBy(alice), 1);
    assertEq(funding.mintedBy(address(this)), 0);
  }

  /// @notice Neither obsolete setup selectors nor upstream proofs can open a private sale.
  function testRealSeaDropRejectsAllowlistMinting() public {
    address[] memory wallets = new address[](1);
    wallets[0] = alice;
    (bool configured,) =
      address(funding).call(abi.encodeWithSignature("setAllowlist(address[])", wallets));
    assertFalse(configured);
    (configured,) =
      address(funding).call(abi.encodeWithSignature("appendAllowlist(address[])", wallets));
    assertFalse(configured);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.setMerkleRoot(bytes32(uint256(1)));
    funding.enableMint();
    funding.enablePublicMint();
    assertEq(drop.getAllowListMerkleRoot(address(funding)), bytes32(0));
    MintParams memory params =
      MintParams(100003, 3, block.timestamp, block.timestamp + 1 days, 1, 3, 333, true);
    vm.prank(alice);
    vm.expectRevert();
    drop.mintAllowList{ value: 100003 }(
      address(funding), fee, address(0), 1, params, new bytes32[](0)
    );
    assertEq(funding.totalMinted(), 0);
    vm.prank(alice);
    drop.mintPublic{ value: 100003 }(address(funding), fee, address(0), 1);
    assertEq(funding.totalMinted(), 1);
  }

  function testRealSeaDropConfigurationCannotBypassFixedEconomics() public {
    assertTrue(funding.supportsInterface(type(INonFungibleSeaDropToken).interfaceId));
    address[] memory allowed = new address[](1);
    allowed[0] = alice;
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.updateAllowedSeaDrop(allowed);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.updateAllowedFeeRecipient(address(drop), alice, true);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.updateAllowList(address(drop), AllowListData(bytes32(uint256(1)), new string[](0), ""));
    ERC721SeaDropStructsErrorsAndEvents.MultiConfigureStruct memory config;
    config.seaDropImpl = address(drop);
    config.maxSupply = 500;
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.multiConfigure(config);
    vm.prank(alice);
    vm.expectRevert();
    funding.updateCreatorPayoutAddress(address(drop), alice);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.renounceOwnership();
    assertEq(funding.maxSupply(), 25);
  }

  /// @dev Build the exact public configuration from the immutable funding terms.
  function publicTerms() internal view returns (PublicDrop memory) {
    return PublicDrop(
      uint80(funding.GROSS_MINT_PRICE()),
      uint48(funding.mintStartTime()),
      uint48(funding.mintStartTime() + funding.MINT_PERIOD()),
      uint16(funding.MAX_PER_WALLET()),
      funding.SEADROP_FEE_BPS(),
      true
    );
  }

  function testMatchingPublicUpdateEnablesMintAndSupportsMultiConfigure() public {
    funding.enableMint();
    PublicDrop memory terms = publicTerms();
    funding.updatePublicDrop(address(drop), terms);
    assertTrue(funding.publicMintEnabled());
    assertEq(abi.encode(drop.getPublicDrop(address(funding))), abi.encode(terms));
    mint(alice, 1);
    ERC721SeaDropStructsErrorsAndEvents.MultiConfigureStruct memory config;
    config.seaDropImpl = address(drop);
    config.publicDrop = terms;
    funding.multiConfigure(config);
    mint(alice, 1);
    assertEq(funding.totalMinted(), 2);
    assertEq(funding.pendingNetProceeds(), 0);
  }

  function testPublicUpdateRejectsEveryChangedTermAndUnauthorizedCaller() public {
    funding.enableMint();
    PublicDrop memory terms = publicTerms();
    vm.prank(alice);
    vm.expectRevert();
    funding.updatePublicDrop(address(drop), terms);
    vm.expectRevert();
    funding.updatePublicDrop(alice, terms);
    for (uint256 i; i < 6; ++i) {
      terms = publicTerms();
      if (i == 0) terms.mintPrice++;
      if (i == 1) terms.startTime++;
      if (i == 2) terms.endTime++;
      if (i == 3) terms.maxTotalMintableByWallet++;
      if (i == 4) terms.feeBps++;
      if (i == 5) terms.restrictFeeRecipients = false;
      vm.expectRevert();
      funding.updatePublicDrop(address(drop), terms);
      assertFalse(funding.publicMintEnabled());
    }
  }

  function testPublicUpdateCannotStartWindowOrReopenClosedSale() public {
    PublicDrop memory unopened = publicTerms();
    vm.expectRevert(FundingCore.MintNotEnabled.selector);
    funding.updatePublicDrop(address(drop), unopened);
    funding.enableMint();
    PublicDrop memory terms = publicTerms();
    funding.updatePublicDrop(address(drop), terms);
    mint(alice, 1);
    funding.closeMint();
    vm.expectRevert(FundingCore.MintPeriodEnded.selector);
    funding.updatePublicDrop(address(drop), terms);
    assertEq(drop.getPublicDrop(address(funding)).endTime, 0);
  }

  function testPublicUpdateRejectsExpiredWindow() public {
    funding.enableMint();
    PublicDrop memory terms = publicTerms();
    vm.warp(uint256(terms.endTime) + 1);
    vm.expectRevert(FundingCore.MintPeriodEnded.selector);
    funding.updatePublicDrop(address(drop), terms);
  }

  function testAllSoulboundTransferAndApprovalEntrypointsReject() public {
    start();
    mint(alice, 1);
    vm.startPrank(alice);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.transferFrom(alice, fee, 1);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.safeTransferFrom(alice, fee, 1);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.safeTransferFrom(alice, fee, 1, hex"aabb");
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.approve(fee, 1);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.setApprovalForAll(fee, true);
    vm.stopPrank();
    assertFalse(funding.isApprovedForAll(alice, fee));
    assertEq(funding.getApproved(1), address(0));
    assertEq(funding.ownerOf(1), alice);
  }

  function testRealSeaDropPayoutRedirectInNFTCallbackRevertsEverything() public {
    SecurityWallet ownerWallet = new SecurityWallet();
    start();
    funding.transferOwnership(address(ownerWallet));
    vm.prank(address(ownerWallet));
    funding.acceptOwnership();
    ownerWallet.configure(
      address(funding),
      abi.encodeCall(funding.updateCreatorPayoutAddress, (address(drop), address(ownerWallet))),
      false,
      false
    );
    vm.deal(address(ownerWallet), 100003);
    mintReverts(address(ownerWallet), 1);
    assertEq(funding.totalMinted(), 0);
    assertEq(drop.getCreatorPayoutAddress(address(funding)), address(funding));
    assertEq(address(ownerWallet).balance, 100003);
  }

  function testRealSeaDropPayoutRedirectInFeeCallbackCannotStealCurrentPayment() public {
    SecurityWallet ownerWallet = new SecurityWallet();
    funding = deploy(2, 100003, 333, 3000, 180 days, address(ownerWallet));
    start();
    funding.transferOwnership(address(ownerWallet));
    vm.prank(address(ownerWallet));
    funding.acceptOwnership();
    ownerWallet.configure(
      address(funding),
      abi.encodeCall(funding.updateCreatorPayoutAddress, (address(drop), address(ownerWallet))),
      false,
      false
    );
    mint(alice, 1);
    // SeaDrop snapshots the payout destination before invoking the fee recipient.
    uint256 cut = uint256(100003) * 333 / 10000;
    assertEq(address(ownerWallet).balance, cut);
    assertEq(address(funding).balance, 100003 - cut);
    assertEq(funding.pendingNetProceeds(), 0);
    mintReverts(alice, 1);
    assertEq(funding.totalMinted(), 1);
  }

  function testRefundCallbackCannotBurnTwiceOrDrainOtherHolder() public {
    SecurityWallet holder = new SecurityWallet();
    start();
    vm.deal(address(holder), 100003);
    mint(address(holder), 1);
    mint(alice, 1);
    funding.closeMint();
    vm.warp(funding.council().publicWindDownAt());
    funding.windDown();
    holder.configure(address(funding), abi.encodeCall(funding.burn, (1)), false, false);
    uint256 quote = funding.getRemainingLockedEth(1);
    vm.prank(address(holder));
    funding.burn(1);
    assertTrue(holder.attempted());
    assertFalse(holder.succeeded());
    assertEq(address(holder).balance, quote);
    assertEq(funding.ownerOf(2), alice);
    assertEq(funding.activeSupply(), 1);
    assertEq(
      address(funding).balance, funding.getRemainingLockedEth(2) + funding.windDownOwnerReserve()
    );
  }

  function testRejectingHolderGetsForcedRefundWithoutBlockingOthers() public {
    SecurityWallet holder = new SecurityWallet();
    holder.configure(address(0), "", true, false);
    start();
    vm.deal(address(holder), 100003);
    mint(address(holder), 1);
    mint(alice, 1);
    funding.closeMint();
    vm.warp(funding.council().publicWindDownAt());
    funding.windDown();
    uint256 quote = funding.getRemainingLockedEth(1);
    vm.prank(address(holder));
    funding.burn(1);
    assertEq(address(holder).balance, quote);
    vm.prank(alice);
    funding.burn(2);
    funding.claimWindDownShare();
    assertEq(address(funding).balance, 0);
  }

  function testOwnerCallbackCannotClaimUpfrontTwice() public {
    SecurityWallet ownerWallet = new SecurityWallet();
    start();
    mint(alice, 25);
    funding.transferOwnership(address(ownerWallet));
    vm.prank(address(ownerWallet));
    funding.acceptOwnership();
    ownerWallet.configure(address(funding), abi.encodeCall(funding.finalize, ()), false, false);
    uint256 upfront = funding.initialPayoutAccrued();
    funding.finalize();
    assertTrue(ownerWallet.attempted());
    assertFalse(ownerWallet.succeeded());
    assertEq(address(ownerWallet).balance, upfront);
    assertEq(funding.ownerPaidAmount(), upfront);
  }

  function testExtremePeriodsAreRejectedBeforeAcceptingFunds() public {
    vm.expectRevert(FundingCore.InvalidParameter.selector);
    deploy(1, 100003, 333, 3000, type(uint256).max, fee);
    vm.expectRevert(FundingCore.InvalidParameter.selector);
    new DirectFunding(
      1, 1, 1, 1, uint256(type(uint48).max) + 1, 0, address(this), address(renderer), "IIF", "IIF"
    );
    vm.expectRevert(FundingCore.InvalidParameter.selector);
    new DirectFunding(
      1, 1, uint256(type(uint80).max) + 1, 1, 1, 0, address(this), address(renderer), "IIF", "IIF"
    );
    vm.expectRevert(FundingCore.InvalidParameter.selector);
    new DirectFunding(
      uint256(type(uint64).max) + 1, 1, 1, 1, 1, 0, address(this), address(renderer), "IIF", "IIF"
    );
  }

  function testZeroFeeAndOneWeiPrincipalConserveEveryWei() public {
    funding = deploy(1, 1, 0, 9999, 185 days, fee);
    start();
    mint(alice, 1);
    assertEq(funding.MINT_PRICE(), 1);
    assertEq(funding.INITIAL_PAYOUT_PER_TOKEN(), 0);
    assertEq(funding.roundingSurplus(), 0);
    funding.finalize();
    funding.startPeriod();
    FundingCouncil council = funding.council();
    for (uint256 cycle = 1; cycle <= 7; ++cycle) {
      vm.warp(council.reviewStart(cycle) + 7 days);
      funding.claimOwnerShareForCycle(cycle);
      funding.claimOwnerShareForCycle(cycle);
    }
    assertEq(funding.ownerPaidAmount(), 1);
    assertEq(address(funding).balance, 0);
  }

  function testReviewDeadlineAndMintDeadlineBoundaries() public {
    start();
    vm.warp(funding.mintStartTime() + funding.MINT_PERIOD());
    mint(alice, 1); // SeaDrop's endTime is inclusive.
    vm.expectRevert(FundingCore.MintNotComplete.selector);
    funding.finalize();
    vm.warp(block.timestamp + 1);
    mintReverts(alice, 1);
    funding.finalize();
    funding.startPeriod();
    FundingCouncil council = funding.council();
    vm.warp(council.reviewDeadline(1) - 1);
    vm.prank(alice);
    council.voteReview(1, ids(1), true);
    vm.expectRevert(FundingCouncil.ReviewNotApproved.selector);
    funding.claimOwnerShareForCycle(1);
    vm.warp(council.reviewDeadline(1));
    vm.prank(alice);
    vm.expectRevert(FundingCouncil.VotingClosed.selector);
    council.voteReview(1, ids(1), false);
    funding.claimOwnerShareForCycle(1);
    assertGt(funding.lastPaidVestedPerToken(), 0);
  }

  function testLargestSupportedPrincipalAndDurationDoNotOverflow() public {
    funding = deploy(1, type(uint80).max, 0, 0, type(uint48).max, fee);
    start();
    vm.deal(alice, type(uint80).max);
    mint(alice, 1);
    funding.finalize();
    funding.startPeriod();
    FundingCouncil council = funding.council();
    uint256 finalCycle = council.reviewCount();
    vm.warp(council.reviewStart(finalCycle));
    vm.prank(alice);
    council.voteReview(finalCycle, ids(1), true);
    vm.warp(council.reviewDeadline(finalCycle));
    funding.claimOwnerShare();
    assertEq(funding.ownerPaidAmount(), type(uint80).max);
    assertEq(address(funding).balance, 0);
  }

  function testWindDownReserveHandlesEntireUint256Balance() public {
    start();
    mint(alice, 1);
    funding.closeMint();
    vm.warp(funding.council().publicWindDownAt());
    // Artificial balance stresses arithmetic; real ETH supply is vastly smaller.
    vm.deal(address(funding), type(uint256).max);
    funding.windDown();
    assertEq(funding.windDownOwnerReserve(), type(uint256).max / 20);
    assertEq(funding.totalUnvested(), type(uint256).max - type(uint256).max / 20);
  }

  /// @notice Independent installment bitmap model catches repeat/out-of-order checkpoint bugs.
  function testFuzzInstallmentModel(uint256 seed, uint80 rawPrice, uint16 rawFee, uint16 rawUpfront)
    public
  {
    uint256 price = bound(rawPrice, 10000, type(uint80).max);
    uint16 fees = uint16(bound(rawFee, 0, 9999));
    uint256 upfront = bound(rawUpfront, 0, 9999);
    funding = deploy(1, price, fees, upfront, 185 days, fee);
    start();
    vm.deal(alice, price);
    mint(alice, 1);
    funding.finalize();
    funding.startPeriod();
    FundingCouncil council = funding.council();
    uint256 locked = funding.LOCKED_PER_TOKEN();
    uint256[8] memory outcomes;
    bool[8] memory settled;
    uint256 expected;
    for (uint256 cycle = 1; cycle <= 7; ++cycle) {
      outcomes[cycle] = (seed >> (cycle * 2)) % 3; // 0 silent, 1 approved, 2 rejected
      if (outcomes[cycle] != 0) {
        vm.warp(council.reviewStart(cycle));
        vm.prank(alice);
        council.voteReview(cycle, ids(1), outcomes[cycle] == 1);
      }
      vm.warp(council.reviewStart(cycle) + 7 days);
      // Repeat old and current claims; the independent model stores paid installments,
      // never the implementation's checkpoints or prefix-sum data structure.
      for (uint256 action; action < 5; ++action) {
        seed = uint256(keccak256(abi.encode(seed, cycle, action)));
        uint256 chosen = seed % cycle + 1;
        if (outcomes[chosen] == 2) {
          vm.expectRevert(FundingCouncil.ReviewNotApproved.selector);
          funding.claimOwnerShareForCycle(chosen);
        } else {
          uint256 first = outcomes[chosen] == 1 ? 1 : chosen;
          for (uint256 i = first; i <= chosen; ++i) {
            if (!settled[i]) {
              uint256 end = i * 30 days;
              if (end > 185 days) end = 185 days;
              expected += locked * end / 185 days - locked * ((i - 1) * 30 days) / 185 days;
              settled[i] = true;
            }
          }
          funding.claimOwnerShareForCycle(chosen);
        }
        assertEq(funding.lastPaidVestedPerToken(), expected);
        assertEq(funding.ownerPaidAmount() + address(funding).balance, funding.totalNetReceived());
      }
    }
    vm.warp(council.publicWindDownAt());
    funding.windDown();
    uint256 refund = funding.getRemainingLockedEth(1);
    vm.prank(alice);
    funding.burn(1);
    funding.claimWindDownShare();
    assertEq(funding.ownerPaidAmount() + refund, funding.totalNetReceived());
    assertEq(address(funding).balance, 0);
  }

  receive() external payable { }
}
