// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import { Base64 } from "solady/utils/Base64.sol";
import { LibString } from "solady/utils/LibString.sol";
import { CardFiles } from "./CardFiles.sol";
import { PlayerTemplate as Player } from "./PlayerTemplate.sol";

/// @notice Constructor-only asset configuration. The funding contract verifies this
/// exact runtime code, so a proxy or a renderer with setters cannot be frozen.
contract FundingCardRenderer {
  CardFiles.Asset public three;
  CardFiles.Asset public card;
  CardFiles.Asset public preview;

  constructor(
    CardFiles.Asset memory libraryFile,
    CardFiles.Asset memory runtimeFile,
    CardFiles.Asset memory previewFile
  ) {
    uint256 size = CardFiles.read(libraryFile).length + CardFiles.read(runtimeFile).length
      + CardFiles.read(previewFile).length;
    if (size > CardFiles.LIMIT) revert CardFiles.InvalidAsset();
    three = libraryFile;
    card = runtimeFile;
    preview = previewFile;
  }

  function tokenURI(uint256 id, string calldata collectionName)
    external
    view
    returns (string memory)
  {
    string memory poster = Base64.encode(CardFiles.read(preview));
    bytes memory svg = abi.encodePacked(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 900"><image width="900" height="900" href="data:image/webp;base64,',
      poster,
      '"/></svg>'
    );
    bytes memory html = abi.encodePacked(
      Player.PART0,
      poster,
      Player.PART1,
      CardFiles.read(three),
      Player.PART2,
      CardFiles.read(card),
      Player.PART3
    );
    bytes memory json = abi.encodePacked(
      '{"name":"',
      LibString.escapeJSON(collectionName),
      " #",
      LibString.toString(id),
      '","description":"A platinum funding card for Industrial Imagination.","image":"data:image/svg+xml;base64,',
      Base64.encode(svg),
      '","animation_url":"data:text/html;charset=utf-8,',
      html,
      '"}'
    );
    return string.concat("data:application/json;base64,", Base64.encode(json));
  }
}
