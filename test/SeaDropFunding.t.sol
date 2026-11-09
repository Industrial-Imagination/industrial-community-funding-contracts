// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import { Test } from "forge-std/Test.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { MerkleProofLib } from "solady/utils/MerkleProofLib.sol";
import { File, BytecodeSlice } from "ethfs/packages/contracts/src/File.sol";
import { FundingCore } from "../src/FundingCore.sol";
import { CardFiles } from "../src/CardFiles.sol";
import { FundingCardRenderer } from "../src/FundingCardRenderer.sol";
import {
  IndustrialImaginationSeaDropFunding as Funding
} from "../src/IndustrialImaginationSeaDropFunding.sol";
import { PublicDrop, AllowListData, MintParams } from "seadrop/src/lib/SeaDropStructs.sol";

contract SeaDropHarness {
  mapping(address => PublicDrop) public sales;
  mapping(address => address) public payout;
  mapping(address => bytes32) public roots;
  mapping(address => mapping(address => bool)) public allowedFees;

  function updatePublicDrop(PublicDrop calldata p) external {
    sales[msg.sender] = p;
  }

  function updateAllowList(AllowListData calldata p) external {
    roots[msg.sender] = p.merkleRoot;
  }

  function getCreatorPayoutAddress(address token) external view returns (address) {
    return payout[token];
  }

  function updateCreatorPayoutAddress(address p) external {
    payout[msg.sender] = p;
  }

  function updateAllowedFeeRecipient(address r, bool yes) external {
    allowedFees[msg.sender][r] = yes;
  }
  function updatePayer(address, bool) external { }
  function updateDropURI(string calldata) external { }

  function mintPublic(address token, address fee, address recipient, uint256 q) external payable {
    PublicDrop memory p = sales[token];
    require(block.timestamp >= p.startTime && block.timestamp <= p.endTime && p.startTime != 0);
    require(msg.value == q * p.mintPrice);
    require(allowedFees[token][fee]);
    _pay(token, fee, recipient == address(0) ? msg.sender : recipient, q, p.feeBps, 0);
  }

  function mintAllowList(
    address token,
    address fee,
    address recipient,
    uint256 q,
    MintParams calldata p,
    bytes32[] calldata proof
  ) external payable {
    address minter = recipient == address(0) ? msg.sender : recipient;
    require(block.timestamp >= p.startTime && block.timestamp <= p.endTime);
    require(MerkleProofLib.verifyCalldata(proof, roots[token], keccak256(abi.encode(minter, p))));
    require(msg.value == q * p.mintPrice);
    require(allowedFees[token][fee]);
    _pay(token, fee, minter, q, p.feeBps, 0);
  }

  function wrongPayout(address token, address fee, address recipient, uint256 q, uint16 feeBps)
    external
    payable
  {
    _pay(token, fee, recipient, q, feeBps, 1);
  }

  function _pay(
    address token,
    address fee,
    address minter,
    uint256 q,
    uint256 fees,
    uint256 shortfall
  ) private {
    Funding(payable(token)).mintSeaDrop(minter, q);
    uint256 cut = msg.value * fees / 10000;
    if (cut != 0) {
      (bool sent,) = fee.call{ value: cut }("");
      require(sent);
    }
    (bool paid,) = payout[token].call{ value: msg.value - cut - shortfall }("");
    require(paid);
  }
}

contract CallbackProbe {
  Funding public funding;
  bool public mintBlocked;
  bool public feeBlocked;
  address public redirectDrop;

  function setFunding(Funding f) external {
    funding = f;
  }

  function setRedirectDrop(address drop) external {
    redirectDrop = drop;
  }

  function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
    if (redirectDrop != address(0)) {
      funding.updateCreatorPayoutAddress(redirectDrop, address(this));
    }
    try funding.finalize() {
      revert("Finalized before funding");
    } catch {
      mintBlocked = true;
    }
    return this.onERC721Received.selector;
  }

  receive() external payable {
    try funding.finalize() {
      revert("Finalized before fee settled");
    } catch {
      feeBlocked = true;
    }
  }
}

contract SeaDropFundingTest is Test {
  SeaDropHarness drop;
  Funding funding;
  FundingCardRenderer renderer;
  address alice = address(0xabc);
  address fee = address(0xfee);

  function setUp() public {
    drop = new SeaDropHarness();
    BytecodeSlice[] memory slices = new BytecodeSlice[](1);
    slices[0] = BytecodeSlice(SSTORE2.write(bytes("QUJD")), 1, 5);
    CardFiles.Asset memory a =
      CardFiles.Asset(SSTORE2.write(abi.encode(File(4, slices))), keccak256(bytes("QUJD")));
    renderer = new FundingCardRenderer(a, a, a);
    funding = release(100003, 333, fee, 3);
    vm.deal(alice, 100 ether);
  }

  function release(uint256 price, uint16 fees, address recipient, uint256 cap)
    internal
    returns (Funding)
  {
    return new Funding(
      cap,
      cap,
      price,
      100,
      1000,
      3000,
      address(this),
      address(renderer),
      "IIF",
      "IIF",
      address(drop),
      fees,
      recipient
    );
  }

  function start() internal {
    funding.enableMint();
    funding.enablePublicMint();
  }

  function mint(uint256 q) internal {
    uint256 value = q * funding.GROSS_MINT_PRICE();
    vm.prank(alice);
    drop.mintPublic{ value: value }(address(funding), fee, address(0), q);
  }

  function testBatchFeesAndNetVesting() public {
    start();
    mint(3);
    uint256 gross = 300009;
    uint256 net = gross - gross * 333 / 10000;
    assertEq(address(funding).balance, net);
    assertEq(funding.totalNetReceived(), net);
    assertEq(funding.pendingNetProceeds(), 0);
    assertEq(funding.roundingSurplus(), net - 3 * funding.MINT_PRICE());
    vm.prank(address(77));
    funding.finalize();
    assertEq(
      funding.ownerPaidAmount(), 3 * funding.INITIAL_PAYOUT_PER_TOKEN() + funding.roundingSurplus()
    );
    vm.warp(funding.vestingStartTime() + 500);
    uint256 refund = funding.getRemainingLockedEth(1);
    vm.prank(alice);
    funding.burn(1);
    uint256 received = alice.balance;
    vm.warp(funding.vestingStartTime() + 1000);
    funding.claimOwnerShare();
    assertEq(alice.balance, received);
    assertGt(refund, 0);
    assertEq(funding.ownerPaidAmount() + refund, net);
    assertEq(address(funding).balance, 0);
    vm.prank(alice);
    funding.burn(2);
    assertEq(alice.balance, received);
  }

  function testNoBypassAndUnauthorizedReceipt() public {
    start();
    vm.expectRevert();
    funding.mintSeaDrop(alice, 1);
    (bool directMint,) =
      address(funding).call{ value: 100003 }(abi.encodeWithSignature("mint(uint256)", 1));
    assertFalse(directMint);
    (bool directAllowlistMint,) = address(funding).call{ value: 100003 }(
      abi.encodeWithSignature("allowlistMint(uint256,bytes32[])", 1, new bytes32[](0))
    );
    assertFalse(directAllowlistMint);
    vm.deal(address(this), 1 ether);
    (bool paid,) = address(funding).call{ value: 1 }("");
    assertFalse(paid);
    funding.updateCreatorPayoutAddress(address(drop), alice);
    vm.prank(alice);
    vm.expectRevert(Funding.InvalidSeaDropConfiguration.selector);
    drop.mintPublic{ value: 100003 }(address(funding), fee, address(0), 1);
    assertEq(funding.totalMinted(), 0);
    assertEq(funding.pendingNetProceeds(), 0);
    funding.updateCreatorPayoutAddress(address(drop), address(funding));
    vm.expectRevert();
    funding.updatePublicDrop(address(drop), PublicDrop(0, 0, 0, 0, 0, false));
  }

  function testUnderpaymentRollsBackAllState() public {
    start();
    vm.expectRevert();
    drop.wrongPayout{ value: 100003 }(address(funding), fee, alice, 1, 333);
    assertEq(funding.totalMinted(), 0);
    assertEq(funding.pendingNetProceeds(), 0);
    assertEq(funding.totalNetReceived(), 0);
    assertEq(fee.balance, 0);
  }

  function testPublicMintsShareLifetimeWalletLimit() public {
    start();
    mint(1);
    mint(2);
    vm.prank(alice);
    vm.expectRevert();
    drop.mintPublic{ value: 100003 }(address(funding), fee, address(0), 1);
    assertEq(funding.mintedBy(alice), 3);
  }

  function testReceiverAndFeeCallbacksCannotFinalizeUnpaidSale() public {
    CallbackProbe probe = new CallbackProbe();
    funding = release(100003, 333, address(probe), 1);
    probe.setFunding(funding);
    start();
    drop.mintPublic{ value: 100003 }(address(funding), address(probe), address(probe), 1);
    assertTrue(probe.mintBlocked());
    assertTrue(probe.feeBlocked());
    assertFalse(funding.vestingStarted());
    funding.finalize();
    assertTrue(funding.vestingStarted());
  }

  function testOwnerReceiverCannotRedirectPendingMintProceeds() public {
    CallbackProbe probe = new CallbackProbe();
    probe.setFunding(funding);
    probe.setRedirectDrop(address(drop));
    start();
    funding.transferOwnership(address(probe));
    vm.prank(address(probe));
    funding.acceptOwnership();

    vm.expectRevert(Funding.InvalidSeaDropConfiguration.selector);
    drop.mintPublic{ value: 100003 }(address(funding), fee, address(probe), 1);
    assertEq(funding.totalSupply(), 0);
    assertEq(funding.totalMinted(), 0);
    assertEq(funding.pendingNetProceeds(), 0);
    assertEq(drop.payout(address(funding)), address(funding));
  }

  function testUpstreamSupplyTransfersAndBurnsRespectFundingRules() public {
    start();
    mint(1);
    assertEq(funding.ownerOf(1), alice);
    assertEq(funding.totalSupply(), 1);
    assertEq(funding.maxSupply(), funding.MAX_SUPPLY());
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.setMaxSupply(9);
    vm.startPrank(alice);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.transferFrom(alice, fee, 1);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.approve(fee, 1);
    vm.expectRevert(FundingCore.CannotBurn.selector);
    funding.burn(1);
    vm.stopPrank();
    funding.closeMint();
    vm.prank(fee);
    vm.expectRevert(FundingCore.NotTokenOwner.selector);
    funding.burn(1);
    vm.prank(alice);
    funding.burn(1);
    assertEq(funding.totalSupply(), 0);
    assertEq(funding.activeSupply(), 0);
  }

  function testFuzzConservation(uint80 rawPrice, uint16 rawFee, uint8 rawQty, bool split) public {
    uint256 price = bound(rawPrice, 10000, 1e20);
    uint16 fees = uint16(bound(rawFee, 0, 9999));
    uint256 q = bound(rawQty, 1, 12);
    vm.deal(alice, price * q);
    funding = release(price, fees, fee, q);
    start();
    if (split) {
      for (uint256 i; i < q; i++) {
        mint(1);
      }
    } else {
      mint(q);
    }
    uint256 actual = funding.totalNetReceived();
    funding.finalize();
    vm.warp(funding.vestingStartTime() + 317);
    uint256 before = alice.balance;
    for (uint256 i = 1; i <= q; i++) {
      vm.prank(alice);
      funding.burn(i);
    }
    assertEq(funding.ownerPaidAmount() + alice.balance - before, actual);
    assertEq(address(funding).balance, 0);
  }
  receive() external payable { }
}
