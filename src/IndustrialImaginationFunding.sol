// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "solady/tokens/ERC721.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { MerkleProofLib } from "solady/utils/MerkleProofLib.sol";
import { FundingCore } from "./FundingCore.sol";

/// @notice Direct-mint funding collection with linear vesting and soulbound refund rights.
contract IndustrialImaginationFunding is FundingCore, ERC721, Ownable {
  string private _tokenName;
  string private _tokenSymbol;

  constructor(
    uint256 supply,
    uint256 walletCap,
    uint256 price,
    uint256 mintPeriod,
    uint256 vestingPeriod,
    uint256 upfrontBps,
    address owner_,
    address renderer,
    string memory name_,
    string memory symbol_
  ) FundingCore(supply, walletCap, price, mintPeriod, vestingPeriod, upfrontBps, owner_, renderer) {
    _tokenName = name_;
    _tokenSymbol = symbol_;
    _initializeOwner(owner_);
  }

  function name() public view override returns (string memory) {
    return _tokenName;
  }

  function symbol() public view override returns (string memory) {
    return _tokenSymbol;
  }

  function _fundingOwner() internal view override returns (address) {
    return owner();
  }

  function _fundingTokenOwner(uint256 id) internal view override returns (address) {
    return ownerOf(id);
  }

  function _fundingTokenExists(uint256 id) internal view override returns (bool) {
    return _exists(id);
  }

  function _issueTokens(address minter, uint256 first, uint256 quantity) internal override {
    for (uint256 i; i < quantity; ++i) {
      _mint(minter, first + i);
    }
  }

  function _destroyFundingToken(uint256 id) internal override {
    _burn(id);
  }

  /// @notice Burn an owned NFT and settle its current refund.
  function burn(uint256 id) external nonReentrant {
    _burnForRefund(id);
  }

  /// @notice Disabled. Renouncing would set the owner to the zero address and burn the vesting stream.
  function renounceOwnership() public payable override onlyOwner {
    revert NotAllowed();
  }

  /* ═════════════════════════════════════════════════════ */
  /*                    PUBLIC FUNCTIONS                   */
  /* ═════════════════════════════════════════════════════ */

  /// @notice Mints `quantity` tokens to the caller during the public phase
  /// @param quantity Number of tokens to mint
  /// @return firstTokenId Id of the first token minted (ids are consecutive)
  function mint(uint256 quantity) external payable nonReentrant returns (uint256 firstTokenId) {
    _preMintChecks(quantity, msg.value);
    if (!publicMintEnabled) revert PublicMintNotEnabled();
    return _mintTokens(msg.sender, quantity);
  }

  /// @notice Mints `quantity` tokens to the caller if they are on the allowlist
  /// @param quantity Number of tokens to mint
  /// @param proof Merkle proof for the caller's address
  /// @return firstTokenId Id of the first token minted (ids are consecutive)
  function allowlistMint(uint256 quantity, bytes32[] calldata proof)
    external
    payable
    nonReentrant
    returns (uint256 firstTokenId)
  {
    _preMintChecks(quantity, msg.value);
    if (!MerkleProofLib.verifyCalldata(proof, merkleRoot, keccak256(abi.encodePacked(msg.sender))))
    {
      revert NotAllowlisted();
    }
    return _mintTokens(msg.sender, quantity);
  }

  /// @dev Validates a mint: window open, quantity valid, payment exact, supply and wallet limits respected.
  function _preMintChecks(uint256 quantity, uint256 amountSent) private view {
    if (!mintEnabled) revert MintNotEnabled();
    if (block.timestamp > mintStartTime + MINT_PERIOD) revert MintPeriodEnded();
    if (quantity == 0) revert ZeroQuantity();
    if (amountSent != MINT_PRICE * quantity) revert WrongAmount();
    if (totalMinted + quantity > MAX_SUPPLY) revert ExceedsMaxSupply();
    if (mintedBy[msg.sender] + quantity > MAX_PER_WALLET) revert ExceedsWalletLimit();
  }

  /// @notice Fully onchain metadata for an existing token
  /// @param tokenId Token to check (must exist)
  function tokenURI(uint256 tokenId) public view override returns (string memory) {
    if (!_exists(tokenId)) revert TokenDoesNotExist();
    return metadataRenderer.tokenURI(tokenId, name());
  }

  /// @dev Only mints (from == 0) and burns (to == 0) are allowed; every other transfer reverts.
  function _beforeTokenTransfer(address from, address to, uint256 tokenId)
    internal
    virtual
    override
  {
    if (from != address(0) && to != address(0)) revert NotAllowed();
    super._beforeTokenTransfer(from, to, tokenId);
  }

  /// @notice Disabled: tokens are soulbound
  function setApprovalForAll(address, bool) public virtual override {
    revert NotAllowed();
  }

  /// @notice Disabled: tokens are soulbound
  function approve(address, uint256) public payable virtual override {
    revert NotAllowed();
  }

  /// @notice Direct ETH transfers are rejected; ETH enters only through mint functions
  receive() external payable virtual {
    revert NotAllowed();
  }
}
