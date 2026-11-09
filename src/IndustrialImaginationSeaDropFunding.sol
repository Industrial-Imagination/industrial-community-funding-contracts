// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import { FundingCore, TokenDoesNotExist } from "./FundingCore.sol";
import {
  ERC721ContractMetadata,
  ISeaDropTokenContractMetadata
} from "seadrop/src/ERC721ContractMetadata.sol";
import { ERC721SeaDrop } from "seadrop/src/ERC721SeaDrop.sol";
import { ISeaDrop } from "seadrop/src/interfaces/ISeaDrop.sol";
import {
  PublicDrop,
  AllowListData,
  TokenGatedDropStage,
  SignedMintValidationParams
} from "seadrop/src/lib/SeaDropStructs.sol";

/// @notice SeaDrop sale with a fixed, net-of-fee per-token funding principal.
/// @dev MINT_PRICE inherited from Funding is the conservative net principal.
/// GROSS_MINT_PRICE is the supporter-facing SeaDrop price. Transaction fee rounding
/// surplus is received and accounted for in the final upfront payout.
contract IndustrialImaginationSeaDropFunding is ERC721SeaDrop, FundingCore {
  /// @notice Fixed mint engine and sole accepted source of mint settlement ETH.
  address public immutable SEA_DROP;
  /// @notice Only fee recipient enabled for the public mint stage.
  address public immutable FEE_RECIPIENT;
  /// @notice Gross wei paid per NFT before the SeaDrop fee.
  uint256 public immutable GROSS_MINT_PRICE;
  /// @notice Fixed fee rate out of 10,000, applied by SeaDrop to each transaction.
  uint16 public immutable SEADROP_FEE_BPS;
  /// @notice Exact ETH expected after a mint callback; zero between completed mints.
  uint256 public pendingNetProceeds;
  /// @dev Conservative per-token principal represented by the unsettled batch.
  uint256 private _pendingPrincipal;
  /// @notice Total settled ETH after SeaDrop fees, including fee-rounding surplus.
  uint256 public totalNetReceived;
  /// @notice Cumulative surplus from transaction-level rounding, paid with the upfront share.
  uint256 public roundingSurplus;
  
  error InvalidSeaDropConfiguration();
  error PaymentPending();
  error UnauthorizedSeaDrop();
  event NetProceedsReceived(uint256 amount, uint256 rounding);

  /// @notice Configure upstream ERC721SeaDrop and bind its single mint engine to the funding ledger.
  /// @dev The deployer must verify the SeaDrop runtime; checking code existence alone is not authentication.
  /// All economics are fixed. Owner handovers use upstream two-step acceptance.
  constructor(
    uint256 supply,
    uint256 walletCap,
    uint256 grossPrice,
    uint256 mintPeriod,
    uint256 vestingPeriod,
    uint256 upfrontBps,
    address owner_,
    address renderer,
    string memory name_,
    string memory symbol_,
    address seaDrop,
    uint16 feeBps,
    address feeRecipient
  )
    ERC721SeaDrop(name_, symbol_, _singleSeaDrop(seaDrop))
    FundingCore(
      supply,
      walletCap,
      _netPrice(grossPrice, feeBps),
      mintPeriod,
      vestingPeriod,
      upfrontBps,
      owner_,
      renderer
    )
  {
    if (
      seaDrop.code.length == 0 || feeRecipient == address(0) || feeRecipient == address(this)
        || feeRecipient == seaDrop || supply > type(uint64).max || grossPrice > type(uint80).max
        || walletCap > type(uint16).max || mintPeriod > type(uint48).max
    ) {
      revert InvalidSeaDropConfiguration();
    }
    super.setMaxSupply(supply);
    _transferOwnership(owner_);
    SEA_DROP = seaDrop;
    SEADROP_FEE_BPS = feeBps;
    FEE_RECIPIENT = feeRecipient;
    GROSS_MINT_PRICE = grossPrice;
  }

  /// @dev The funding ledger is bound to a single SeaDrop payout source.
  function _singleSeaDrop(address drop) private pure returns (address[] memory allowed) {
    allowed = new address[](1);
    allowed[0] = drop;
  }

  /// @dev Resolve the shared ledger's beneficiary through upstream ownership.
  function _fundingOwner() internal view override returns (address) {
    return owner();
  }

  /// @dev ERC721A ownership lookup also rejects nonexistent and burned tokens.
  function _fundingTokenOwner(uint256 id) internal view override returns (address) {
    return ownerOf(id);
  }

  /// @dev Bridge the shared ledger to ERC721A existence checks.
  function _fundingTokenExists(uint256 id) internal view override returns (bool) {
    return _exists(id);
  }

  /// @notice Serve the funding renderer for existing tokens.
  function tokenURI(uint256 id) public view override returns (string memory) {
    if (!_exists(id)) revert TokenDoesNotExist();
    return metadataRenderer.tokenURI(id, name());
  }

  /// @notice The funding principal and SeaDrop supply are fixed at deployment.
  function setMaxSupply(uint256)
    public
    pure
    override(ERC721ContractMetadata, ISeaDropTokenContractMetadata)
  {
    revert NotAllowed();
  }

  /// @notice Keep an owner to receive scheduled funding payments.
  function renounceOwnership() public pure override {
    revert NotAllowed();
  }

  /// @dev ERC721A calls this hook for transfers, mints and burns. Funding NFTs are soulbound.
  function _beforeTokenTransfers(address from, address to, uint256, uint256)
    internal
    pure
    override
  {
    if (from != address(0) && to != address(0)) revert NotAllowed();
  }

  /// @notice Soulbound transfers always fail. Reject at the entry point so the
  /// compiler need not retain ERC721A's unused transfer bookkeeping in this collection.
  function transferFrom(address, address, uint256) public pure override {
    revert NotAllowed();
  }

  /// @notice Safe transfers are disabled independently of recipient type.
  function safeTransferFrom(address, address, uint256) public pure override {
    revert NotAllowed();
  }

  /// @notice Supplying receiver callback data does not enable transfers.
  function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
    revert NotAllowed();
  }

  /// @notice Soulbound NFTs cannot authorize another wallet to transfer or burn them.
  function approve(address, uint256) public pure override {
    revert NotAllowed();
  }

  /// @notice Disable blanket operator authorization as well as individual approvals.
  function setApprovalForAll(address, bool) public pure override {
    revert NotAllowed();
  }

  /// @notice Soulbound tokens grant no operator approvals, including conduit preapprovals.
  function isApprovedForAll(address, address) public pure override returns (bool) {
    return false;
  }

  /// @dev The upstream public burn reaches this virtual hook. Apply funding and refund rules first.
  function _burn(uint256 id, bool) internal override nonReentrant {
    _burnForRefund(id);
  }

  /// @dev Only called by the refund flow after checking the holder and updating funding accounting.
  function _destroyFundingToken(uint256 id) internal override {
    super._burn(id, false);
  }

  /// @dev Floor the net principal per NFT. The exact transaction-level surplus is settled in receive().
  function _netPrice(uint256 price, uint16 fees) private pure returns (uint256) {
    if (fees >= 10000 || price > type(uint80).max) revert InvalidSeaDropConfiguration();
    return price * (10000 - fees) / 10000;
  }

  /// @notice Start the immutable public sale window and register fixed payout routing.
  function enableMint() public override onlyOwner {
    if (block.timestamp + MINT_PERIOD > type(uint48).max) revert InvalidSeaDropConfiguration();
    super.enableMint();
    ISeaDrop drop = ISeaDrop(SEA_DROP);
    drop.updateCreatorPayoutAddress(address(this));
    drop.updateAllowedFeeRecipient(FEE_RECIPIENT, true);
    if (publicMintEnabled) _updatePublicDrop();
  }

  /// @notice Enable public minting within the original window; finalization is irreversible.
  function enablePublicMint() public override onlyOwner {
    if (vestingStarted) revert MintPeriodEnded();
    super.enablePublicMint();
    if (mintEnabled) _updatePublicDrop();
  }

  /// @dev Cast only values bounded at construction and the timestamp checked in enableMint().
  function _updatePublicDrop() private {
    ISeaDrop(SEA_DROP)
      .updatePublicDrop(
        PublicDrop(
          uint80(GROSS_MINT_PRICE),
          uint48(mintStartTime),
          uint48(mintStartTime + MINT_PERIOD),
          uint16(MAX_PER_WALLET),
          SEADROP_FEE_BPS,
          true
        )
      );
  }

  /// @notice Issue funded NFTs only in response to the fixed SeaDrop engine.
  /// @dev Reserve the exact expected settlement before ERC721 receiver callbacks. Finalization
  /// stays blocked between this call and SeaDrop's subsequent ETH payout, even after the guard resets.
  function mintSeaDrop(address minter, uint256 quantity) external override nonReentrant {
    if (msg.sender != SEA_DROP) revert UnauthorizedSeaDrop();
    if (pendingNetProceeds != 0) revert PaymentPending();
    if (!mintEnabled) revert MintNotEnabled();
    if (vestingStarted || block.timestamp > mintStartTime + MINT_PERIOD) revert MintPeriodEnded();
    if (!publicMintEnabled) revert MintNotEnabled();
    if (quantity == 0) revert ZeroQuantity();
    if (totalMinted + quantity > MAX_SUPPLY) revert ExceedsMaxSupply();
    if (mintedBy[minter] + quantity > MAX_PER_WALLET) revert ExceedsWalletLimit();
    uint256 gross = GROSS_MINT_PRICE * quantity;
    pendingNetProceeds = gross - gross * SEADROP_FEE_BPS / BPS;
    _pendingPrincipal = quantity * MINT_PRICE;
    _mintTokens(minter, quantity);
    // Check after the receiver callback. The upstream payout setter cannot be overridden,
    // and the receiver may itself control the owner wallet.
    if (ISeaDrop(SEA_DROP).getCreatorPayoutAddress(address(this)) != address(this)) {
      revert InvalidSeaDropConfiguration();
    }
  }

  /// @dev Preserve upstream ERC721A safe-receiver checks and sequential token IDs.
  function _issueTokens(address minter, uint256, uint256 quantity) internal override {
    _safeMint(minter, quantity);
  }

  /// @notice Settle exactly one outstanding mint batch from the authorized SeaDrop contract.
  /// @dev SeaDrop uses CALL with available gas, not send/transfer's 2,300-gas stipend.
  /// This function has no external calls. Wrong sender, duplicate receipt or wrong value reverts.
  receive() external payable {
    if (msg.sender != SEA_DROP) revert UnauthorizedSeaDrop();
    uint256 expected = pendingNetProceeds;
    if (expected == 0 || msg.value != expected) revert WrongAmount();
    // All tokens have the same principal. Extra wei from batch fee rounding
    // belong to the upfront allocation and cannot inflate locked refund rights.
    uint256 rounding = msg.value - _pendingPrincipal;
    _pendingPrincipal = 0;
    totalNetReceived += msg.value;
    roundingSurplus += rounding;
    initialPayoutAccrued += rounding;
    pendingNetProceeds = 0;
    emit NetProceedsReceived(msg.value, rounding);
  }

  /// @notice Permanently closes the sale and settles the upfront payout in one transaction.
  function closeMint() external onlyOwner nonReentrant {
    _finalize(true);

    ISeaDrop drop = ISeaDrop(SEA_DROP);
    if (publicMintEnabled) {
      publicMintEnabled = false;
      PublicDrop memory disabledDrop;
      drop.updatePublicDrop(disabledDrop);
    }
  }

  /// @dev Never pay the upfront allocation while NFT issuance is still awaiting its ETH.
  function _finalize(bool closeEarly) internal override {
    if (pendingNetProceeds != 0) revert PaymentPending();
    super._finalize(closeEarly);
  }

  /// @notice Return the collection's fixed, single-entry SeaDrop allowlist.
  function getAllowedSeaDrop() external view returns (address[] memory) {
    return _singleSeaDrop(SEA_DROP);
  }

  // Sale-critical SeaDrop settings are derived from the immutable funding terms.
  // Public-stage updates accept only the fixed terms; other sale-changing entrypoints reject changes.
  function updateAllowedSeaDrop(address[] calldata) external pure override {
    revert NotAllowed();
  }

  /// @notice Register or reaffirm the public stage without changing the funding agreement.
  /// @dev Preserves upstream owner-or-self authorization for multiConfigure. The owner must
  /// start the fixed window with enableMint() first. A matching update also enables public
  /// minting locally, so SeaDrop and the funding callback agree that the stage is open.
  /// Expired or finalized sales cannot be reopened, even with otherwise matching settings.
  /// @param seaDropImpl The single immutable SeaDrop engine authorized to mint this collection.
  /// @param publicDrop Exact price, window, wallet cap and fee terms of the funding agreement.
  function updatePublicDrop(address seaDropImpl, PublicDrop calldata publicDrop) external override {
    _onlyOwnerOrSelf();
    _onlyAllowedSeaDrop(seaDropImpl);
    if (!mintEnabled) revert MintNotEnabled();
    if (vestingStarted || block.timestamp > mintStartTime + MINT_PERIOD) revert MintPeriodEnded();
    if (
      publicDrop.mintPrice != GROSS_MINT_PRICE || publicDrop.startTime != mintStartTime
        || publicDrop.endTime != mintStartTime + MINT_PERIOD
        || publicDrop.maxTotalMintableByWallet != MAX_PER_WALLET
        || publicDrop.feeBps != SEADROP_FEE_BPS || !publicDrop.restrictFeeRecipients
    ) revert InvalidSeaDropConfiguration();
    if (!publicMintEnabled) {
      publicMintEnabled = true;
      emit PublicMintEnabled();
    }
    ISeaDrop(seaDropImpl).updatePublicDrop(publicDrop);
  }

  function updateAllowList(address, AllowListData calldata) external pure override {
    revert NotAllowed();
  }

  function updateAllowedFeeRecipient(address, address, bool) external pure override {
    revert NotAllowed();
  }

  function updateTokenGatedDrop(address, address, TokenGatedDropStage calldata)
    external
    pure
    override
  {
    revert NotAllowed();
  }

  function updateSignedMintValidationParams(address, address, SignedMintValidationParams calldata)
    external
    pure
    override
  {
    revert NotAllowed();
  }

  function setMerkleRoot(bytes32) external pure override {
    revert NotAllowed();
  }
}
