// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { File, BytecodeSlice } from "ethfs/packages/contracts/src/File.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";

/// @dev Validate the renderer's asset policy before reading the upstream ETHFS file.
library CardFiles {
  struct Asset {
    address pointer;
    bytes32 hash;
  }
  error InvalidAsset();
  uint256 internal constant LIMIT = 512 * 1024;

  function checkedLength(address pointer) private view returns (uint256 length) {
    length = pointer.code.length;
    uint256 prefix;
    assembly ("memory-safe") {
      extcodecopy(pointer, 0, 0, 1)
      prefix := byte(0, mload(0))
    }
    if (length <= 1 || prefix != 0) revert InvalidAsset();
  }

  function read(Asset memory asset) internal view returns (bytes memory data) {
    uint256 size = checkedLength(asset.pointer) - 1;
    // abi.encode(File) has four header words followed by three words per slice.
    if (size < 224 || size > 128 + 96 * 32) revert InvalidAsset();
    bytes memory encoded = SSTORE2.read(asset.pointer);
    uint256 tupleOffset;
    uint256 arrayOffset;
    uint256 sliceCount;
    assembly ("memory-safe") {
      tupleOffset := mload(add(encoded, 32))
      arrayOffset := mload(add(encoded, 96))
      sliceCount := mload(add(encoded, 128))
    }
    if (
      tupleOffset != 32 || arrayOffset != 64 || sliceCount == 0 || sliceCount > 32
        || size != 128 + 96 * sliceCount
    ) revert InvalidAsset();
    File memory file = abi.decode(encoded, (File));
    if (file.size == 0 || file.size > LIMIT || file.slices.length == 0 || file.slices.length > 32) {
      revert InvalidAsset();
    }
    uint256 offset;
    for (uint256 i; i < file.slices.length; ++i) {
      BytecodeSlice memory s = file.slices[i];
      if (s.start == 0 || s.start >= s.end || s.end > checkedLength(s.pointer)) {
        revert InvalidAsset();
      }
      uint256 count = s.end - s.start;
      if (count > file.size - offset) revert InvalidAsset();
      offset += count;
    }
    if (offset != file.size) revert InvalidAsset();
    data = bytes(file.read());
    if (keccak256(data) != asset.hash) revert InvalidAsset();
  }
}
