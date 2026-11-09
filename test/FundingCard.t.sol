// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import { Test } from "forge-std/Test.sol";
import { File, BytecodeSlice } from "ethfs/packages/contracts/src/File.sol";
import { FundingCore } from "../src/FundingCore.sol";
import { CardFiles } from "../src/CardFiles.sol";
import { FundingCardRenderer } from "../src/FundingCardRenderer.sol";
import { IndustrialImaginationFunding as Funding } from "../src/IndustrialImaginationFunding.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { LibString } from "solady/utils/LibString.sol";
import { Base64 } from "solady/utils/Base64.sol";

contract FundingCardTest is Test {
  Funding funding;
  FundingCardRenderer renderer;
  CardFiles.Asset asset;
  address alice = address(0xabc);

  function setUp() public {
    bytes memory contents = bytes("QUJD");
    BytecodeSlice[] memory slices = new BytecodeSlice[](2);
    slices[0] = BytecodeSlice(SSTORE2.write(bytes("XQU")), 2, 4);
    slices[1] = BytecodeSlice(SSTORE2.write(bytes("JD!")), 1, 3);
    asset = CardFiles.Asset(
      SSTORE2.write(abi.encode(File(contents.length, slices))), keccak256(contents)
    );
    renderer = new FundingCardRenderer(asset, asset, asset);
    funding = new Funding(
      3, 3, 100003, 100, 1000, 3000, address(this), address(renderer), 'Lab "A"', "IIF"
    );
    funding.enableMint();
    funding.enablePublicMint();
    vm.deal(alice, 300009);
  }

  function mint() private {
    vm.prank(alice);
    funding.mint{ value: 300009 }(3);
  }

  function testMetadata() public {
    vm.expectRevert(bytes4(keccak256("TokenDoesNotExist()")));
    funding.tokenURI(0);
    mint();
    string memory json = string(Base64.decode(LibString.slice(funding.tokenURI(1), 29)));
    assertEq(vm.parseJsonString(json, ".name"), 'Lab "A" #1');
    string memory two = string(Base64.decode(LibString.slice(funding.tokenURI(2), 29)));
    assertEq(vm.parseJsonString(json, ".animation_url"), vm.parseJsonString(two, ".animation_url"));
    assertEq(vm.parseJsonString(json, ".image"), vm.parseJsonString(two, ".image"));
    funding.finalize();
    vm.prank(alice);
    funding.burn(1);
    vm.expectRevert(bytes4(keccak256("TokenDoesNotExist()")));
    funding.tokenURI(1);
  }

  function testOwnerCanReplaceRendererAfterFinalization() public {
    vm.expectRevert(FundingCore.InvalidParameter.selector);
    funding.setMetadataRenderer(alice);

    bytes memory preview = bytes("REVG");
    BytecodeSlice[] memory slices = new BytecodeSlice[](1);
    slices[0] = BytecodeSlice(SSTORE2.write(preview), 1, 5);
    CardFiles.Asset memory replacementPreview =
      CardFiles.Asset(SSTORE2.write(abi.encode(File(preview.length, slices))), keccak256(preview));
    FundingCardRenderer next = new FundingCardRenderer(asset, asset, replacementPreview);
    mint();
    funding.finalize();
    string memory originalURI = funding.tokenURI(1);

    vm.prank(alice);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.setMetadataRenderer(address(next));
    funding.setMetadataRenderer(address(next));
    assertEq(funding.tokenURI(1), next.tokenURI(1, funding.name()));
    assertNotEq(funding.tokenURI(1), originalURI);

    funding.setMetadataRenderer(address(renderer));
    assertEq(funding.tokenURI(1), originalURI);
  }

  function testCorruptHash() public {
    CardFiles.Asset memory wrong = asset;
    wrong.hash = 0;
    vm.expectRevert(CardFiles.InvalidAsset.selector);
    new FundingCardRenderer(asset, wrong, asset);
  }

  function testSliceBoundsAndPrefix() public {
    BytecodeSlice[] memory slices = new BytecodeSlice[](1);
    address chunk = SSTORE2.write(bytes("QUJD"));
    for (uint256 i; i < 5; i++) {
      slices[0] = BytecodeSlice(chunk, uint32(i == 0 ? 0 : 1), uint32(i == 1 ? 6 : i == 2 ? 1 : 5));
      if (i == 4) vm.etch(chunk, hex"ff51554a44");
      CardFiles.Asset memory invalid =
        CardFiles.Asset(SSTORE2.write(abi.encode(File(i == 3 ? 7 : 4, slices))), asset.hash);
      vm.expectRevert(CardFiles.InvalidAsset.selector);
      new FundingCardRenderer(invalid, asset, asset);
    }
  }

  function testEOAAndDescriptorPrefix() public {
    CardFiles.Asset memory invalid = CardFiles.Asset(alice, asset.hash);
    vm.expectRevert(CardFiles.InvalidAsset.selector);
    new FundingCardRenderer(invalid, asset, asset);
    vm.etch(alice, hex"ff112233");
    vm.expectRevert(CardFiles.InvalidAsset.selector);
    new FundingCardRenderer(invalid, asset, asset);
  }

  function testSoulboundAndBurnGates() public {
    mint();
    vm.startPrank(alice);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.transferFrom(alice, address(this), 1);
    vm.expectRevert(FundingCore.NotAllowed.selector);
    funding.approve(address(this), 1);
    vm.expectRevert(FundingCore.CannotBurn.selector);
    funding.burn(1);
    vm.stopPrank();
    vm.prank(address(77));
    funding.finalize();
    vm.expectRevert(FundingCore.NotTokenOwner.selector);
    funding.burn(1);
  }

  function testFuzzBurnAccounting(uint16 first, uint16 second, bool reverse) public {
    mint();
    funding.finalize();
    uint256 start = funding.vestingStartTime();
    uint256 t1 = bound(first, 0, 1000);
    uint256 t2 = bound(second, t1, 1001);
    uint256 refunds;
    for (uint256 i; i < 3; i++) {
      vm.warp(start + (i == 0 ? t1 : t2));
      uint256 id = reverse ? 3 - i : 1 + i;
      uint256 expected = funding.LOCKED_PER_TOKEN(); // per-token principal
      uint256 elapsed = i == 0 ? t1 : t2;
      refunds += expected - expected * (elapsed > 1000 ? 1000 : elapsed) / 1000;
      vm.prank(alice);
      funding.burn(id);
    }
    assertEq(alice.balance, refunds);
    assertEq(funding.ownerPaidAmount() + refunds, 300009);
    assertEq(address(funding).balance, 0);
    assertEq(funding.activeSupply(), 0);
  }

  function testAggregateAndSliceCaps() public {
    bytes memory page = new bytes(8192);
    address chunk = SSTORE2.write(page);
    BytecodeSlice[] memory slices = new BytecodeSlice[](24);
    for (uint256 n; n < slices.length; n++) {
      slices[n] = BytecodeSlice(chunk, 1, 8193);
    }
    bytes memory all = new bytes(24 * 8192);
    CardFiles.Asset memory large =
      CardFiles.Asset(SSTORE2.write(abi.encode(File(all.length, slices))), keccak256(all));
    vm.expectRevert(CardFiles.InvalidAsset.selector);
    new FundingCardRenderer(large, large, large);
    slices = new BytecodeSlice[](33);
    large.pointer = SSTORE2.write(abi.encode(File(33, slices)));
    vm.expectRevert(CardFiles.InvalidAsset.selector);
    new FundingCardRenderer(large, asset, asset);
  }

  function testMidstreamClaimAndFinalBurn() public {
    mint();
    funding.finalize();
    uint256 start = funding.vestingStartTime();
    vm.warp(start + 250);
    funding.claimOwnerShare();
    uint256 quarter = funding.LOCKED_PER_TOKEN() * 250 / 1000;
    assertEq(funding.ownerPaidAmount(), 3 * (funding.INITIAL_PAYOUT_PER_TOKEN() + quarter));
    vm.prank(alice);
    funding.burn(2);
    uint256 refund = alice.balance;
    assertEq(refund, funding.LOCKED_PER_TOKEN() - quarter);
    vm.warp(start + 1000);
    funding.claimOwnerShare();
    vm.prank(alice);
    funding.burn(1);
    assertEq(alice.balance, refund);
    assertEq(funding.ownerPaidAmount() + refund, 300009);
    assertEq(address(funding).balance, 0);
  }

  /// @notice JSON escaping covers control characters, quotes, backslashes and Unicode together.
  function testMetadataEscapesControlCharactersAndUnicode() public view {
    string memory label = string.concat(unicode'Industrial "🌙" \\ ', string(hex"0008090a0c0d1f"));
    string memory json = string(Base64.decode(LibString.slice(renderer.tokenURI(17, label), 29)));
    assertEq(vm.parseJsonString(json, ".name"), string.concat(label, " #17"));
  }

  /// @notice ABI offsets and descriptor length are checked before allocating/reading slices.
  function testMalformedDescriptorHeadersAndTrailingData() public {
    BytecodeSlice[] memory slices = new BytecodeSlice[](1);
    slices[0] = BytecodeSlice(SSTORE2.write(bytes("QUJD")), 1, 5);
    for (uint256 word; word < 4; ++word) {
      bytes memory encoded = abi.encode(File(4, slices));
      if (word == 3) {
        encoded = bytes.concat(encoded, hex"00");
      } else {
        uint256 offset = word == 0 ? 32 : word == 1 ? 96 : 128;
        assembly ("memory-safe") { mstore(add(encoded, offset), not(0)) }
      }
      CardFiles.Asset memory malformed =
        CardFiles.Asset(SSTORE2.write(encoded), keccak256(bytes("QUJD")));
      vm.expectRevert(CardFiles.InvalidAsset.selector);
      new FundingCardRenderer(malformed, asset, asset);
    }
  }

  /// @notice Hashes are rechecked on reads as well as constructor validation.
  function testChangedAssetBytesAreRejectedAtRead() public {
    mint();
    File memory descriptor = abi.decode(SSTORE2.read(asset.pointer), (File));
    vm.etch(descriptor.slices[0].pointer, hex"00585858");
    vm.expectRevert(CardFiles.InvalidAsset.selector);
    funding.tokenURI(1);
  }

  receive() external payable { }
}
