// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import { FundingCardRenderer } from "./FundingCardRenderer.sol";
import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

error TokenDoesNotExist();

/// @title Shared funding ledger
/// @notice Accounts for upfront principal, mint limits and metadata for soulbound funding NFTs.
/// @dev The default hooks implement continuous vesting and unvested-principal refunds.
/// IndustrialImaginationGovernedFunding overrides those hooks with holder-authorized
/// installments and terminal-exit refunds. SeaDrop supplies net-of-fee principal.
/// Derived from TokenWorks' FundingWorks contract (MIT).

abstract contract FundingCore is ReentrancyGuard {
  /* ═════════════════════════════════════════════════════ */
  /*                      CONSTANTS                        */
  /* ═════════════════════════════════════════════════════ */

  /// @dev Exact renderer runtime hash computed once at deployment.
  bytes32 private immutable _rendererCodeHash;

  /// @notice Basis-points denominator (10_000 = 100%)
  uint256 public constant BPS = 10_000;

  /// @notice Release parameters bundled for convenient reading by frontends
  struct ReleaseInfo {
    uint256 maxSupply;
    uint256 maxPerWallet;
    uint256 tokensMinted;
    uint256 activeSupply;
    uint256 mintPrice;
    uint256 mintPeriod;
    uint256 vestingPeriod;
    uint256 initialPayoutBps;
  }

  /* ═════════════════════════════════════════════════════ */
  /*                  IMMUTABLE PARAMETERS                 */
  /* ═════════════════════════════════════════════════════ */

  /// @notice Maximum number of tokens that can ever be minted
  uint256 public immutable MAX_SUPPLY;
  /// @notice Maximum number of tokens a single wallet can mint in total (burns do not free quota)
  uint256 public immutable MAX_PER_WALLET;
  /// @notice Price in wei for one token
  uint256 public immutable MINT_PRICE;
  /// @notice Length of the mint window in seconds, counted from `enableMint()`
  uint256 public immutable MINT_PERIOD;
  /// @notice Stream duration; the governed collection starts its clock separately after finalization.
  uint256 public immutable VESTING_PERIOD;
  /// @notice Share of each mint price paid to the owner at finalize, in basis points
  uint256 public immutable INITIAL_PAYOUT_BPS;
  /// @notice Wei per token paid to the owner at finalize (MINT_PRICE * INITIAL_PAYOUT_BPS / BPS)
  uint256 public immutable INITIAL_PAYOUT_PER_TOKEN;
  /// @notice Wei per token that is locked and vests over VESTING_PERIOD (MINT_PRICE - INITIAL_PAYOUT_PER_TOKEN)
  uint256 public immutable LOCKED_PER_TOKEN;

  /* ═════════════════════════════════════════════════════ */
  /*                    STATE VARIABLES                    */
  /* ═════════════════════════════════════════════════════ */

  /// @notice Shared onchain artwork renderer.
  FundingCardRenderer public metadataRenderer;

  /// @notice Legacy direct-mint allowlist root. The production SeaDrop collection keeps this zero.
  bytes32 public merkleRoot;
  /// @notice True once public minting is open to everyone
  bool public publicMintEnabled;
  /// @notice True once the owner has started the mint window
  bool public mintEnabled;
  /// @notice Timestamp when the mint window opened
  uint256 public mintStartTime;
  /// @notice True when the entire supply has been minted
  bool public mintComplete;

  /// @notice Total tokens ever minted (token ids are 1..totalMinted)
  uint256 public totalMinted;
  /// @notice Number of tokens burned so far
  uint256 public burnedTokenCount;
  /// @notice Tokens minted per wallet, counted against MAX_PER_WALLET
  mapping(address => uint256) public mintedBy;

  /// @notice True once finalization has settled upfront funds; governed period start is separate.
  bool public vestingStarted;
  /// @notice Timestamp when vesting started
  uint256 public vestingStartTime;

  /// @notice Upfront payout accrued during the mint, paid to the owner once at `finalize()`
  uint256 public initialPayoutAccrued;
  /// @notice Per-token vested amount (wei) as of the last owner payout; used to compute the next payout
  uint256 public lastPaidVestedPerToken;
  /// @notice Total wei paid to the owner so far (upfront payout + vested streams)
  uint256 public ownerPaidAmount;

  /* ═════════════════════════════════════════════════════ */
  /*                        ERRORS                         */
  /* ═════════════════════════════════════════════════════ */

  /// @notice msg.value does not equal MINT_PRICE * quantity
  error WrongAmount();
  /// @notice The requested quantity would exceed MAX_SUPPLY
  error ExceedsMaxSupply();
  /// @notice The requested quantity would exceed MAX_PER_WALLET for this wallet
  error ExceedsWalletLimit();
  /// @notice Quantity must be greater than zero
  error ZeroQuantity();
  /// @notice Caller does not own the token
  error NotTokenOwner();
  /// @notice Burning is not possible yet (vesting has not started)
  error CannotBurn();
  /// @notice The contract balance cannot cover a payout (should never happen)
  error InsufficientContractBalance();
  /// @notice Minting has not been enabled
  error MintNotEnabled();
  /// @notice Public minting has not been enabled
  error PublicMintNotEnabled();
  /// @notice The mint window has ended
  error MintPeriodEnded();
  /// @notice Vesting has already started
  error VestingAlreadyStarted();
  /// @notice The mint is still running (not sold out and window not over)
  error MintNotComplete();
  /// @notice Caller is not on the allowlist
  error NotAllowlisted();
  /// @notice Minting was already enabled
  error MintAlreadyEnabled();
  /// @notice A value that must be non-zero was zero
  error CannotBeZero();
  /// @notice Operation is not allowed (transfers, approvals, renouncing ownership, direct ETH)
  error NotAllowed();
  /// @notice A constructor parameter is invalid
  error InvalidParameter();

  /* ═════════════════════════════════════════════════════ */
  /*                        EVENTS                         */
  /* ═════════════════════════════════════════════════════ */

  /// @notice Emitted when public minting is opened
  event PublicMintEnabled();

  /// @notice Emitted when the mint window opens
  /// @param startTime Start of the mint window
  /// @param endTime End of the mint window
  event MintStarted(uint256 startTime, uint256 endTime);

  /// @notice Emitted when tokens are minted
  /// @param minter Wallet that minted
  /// @param quantity Number of tokens minted
  /// @param firstTokenId First token id of the batch (ids are consecutive)
  event Minted(address indexed minter, uint256 quantity, uint256 firstTokenId);

  /// @notice Emitted when the mint is finalized and vesting begins
  /// @param vestingStartTime Timestamp vesting started
  /// @param vestingEndTime Timestamp vesting ends
  /// @param upfrontPayout Wei paid to the owner at finalize
  event Finalized(uint256 vestingStartTime, uint256 vestingEndTime, uint256 upfrontPayout);

  /// @notice Emitted when vested funds are paid to the owner
  /// @param amount Wei paid
  event OwnerShareClaimed(uint256 amount);

  /// @notice Emitted when a holder burns a token and recovers the unvested funds
  /// @param holder The holder who burned
  /// @param tokenId The burned token id
  /// @param refund Wei refunded to the holder
  event Burned(address indexed holder, uint256 indexed tokenId, uint256 refund);

  /// @notice A validated onchain renderer was selected.
  event MetadataRendererUpdated(address indexed renderer);

  /* ═════════════════════════════════════════════════════ */
  /*                      CONSTRUCTOR                      */
  /* ═════════════════════════════════════════════════════ */

  /// @param _maxSupply Maximum number of tokens (must be > 0)
  /// @param _maxPerWallet Maximum tokens one wallet may mint (must be > 0; use `_maxSupply` for no effective cap)
  /// @param _mintPrice Price per token in wei (must be > 0)
  /// @param _mintPeriod Mint window length in seconds (must be > 0)
  /// @param _vestingPeriod Vesting length in seconds (must be > 0)
  /// @param _initialPayoutBps Upfront share in basis points, e.g. 3000 = 30% (must be < 10_000)
  /// @param _owner Address that owns the contract and receives all funds (use a multisig)
  /// @param _renderer Address of a configured FundingCardRenderer
  constructor(
    uint256 _maxSupply,
    uint256 _maxPerWallet,
    uint256 _mintPrice,
    uint256 _mintPeriod,
    uint256 _vestingPeriod,
    uint256 _initialPayoutBps,
    address _owner,
    address _renderer
  ) {
    if (
      _maxSupply == 0 || _maxPerWallet == 0 || _maxPerWallet > _maxSupply || _mintPrice == 0
        || _mintPeriod == 0 || _vestingPeriod == 0 || _initialPayoutBps >= BPS
        || _owner == address(0)
    ) revert InvalidParameter();

    // Bound intermediate products, not just their final quotients. Total principal
    // fits in 144 bits (80-bit price * 64-bit supply); time-based per-token products
    // fit in 128 bits (80-bit principal * 48-bit duration). This also bounds the
    // governed review schedule and its logarithmic silence-payment index.
    if (
      _maxSupply > type(uint64).max || _mintPrice > type(uint80).max
        || _mintPeriod > type(uint48).max || _vestingPeriod > type(uint48).max
    ) revert InvalidParameter();

    MAX_SUPPLY = _maxSupply;
    MAX_PER_WALLET = _maxPerWallet;
    MINT_PRICE = _mintPrice;
    MINT_PERIOD = _mintPeriod;
    VESTING_PERIOD = _vestingPeriod;
    INITIAL_PAYOUT_BPS = _initialPayoutBps;

    uint256 upfront = (_mintPrice * _initialPayoutBps) / BPS;
    INITIAL_PAYOUT_PER_TOKEN = upfront;
    LOCKED_PER_TOKEN = _mintPrice - upfront;

    _rendererCodeHash = keccak256(type(FundingCardRenderer).runtimeCode);
    _selectRenderer(_renderer);
  }

  /// @dev Resolve the owner through the concrete token's ownership implementation.
  function _fundingOwner() internal view virtual returns (address);

  /// @dev Authorize shared funding administration against the concrete owner.
  modifier onlyFundingOwner() {
    if (msg.sender != _fundingOwner()) revert NotAllowed();
    _;
  }

  /// @dev Resolve token ownership and existence through the concrete token implementation.
  function _fundingTokenOwner(uint256 tokenId) internal view virtual returns (address);
  function _fundingTokenExists(uint256 tokenId) internal view virtual returns (bool);

  /// @dev Mint a batch and destroy a single token through the concrete token implementation.
  function _issueTokens(address minter, uint256 firstTokenId, uint256 quantity) internal virtual;
  function _destroyFundingToken(uint256 tokenId) internal virtual;

  /* ═════════════════════════════════════════════════════ */
  /*                    ADMIN FUNCTIONS                    */
  /* ═════════════════════════════════════════════════════ */

  /// @notice Sets the allowlist Merkle root
  /// @param _merkleRoot Root of the allowlist tree (leaf = keccak256(abi.encodePacked(address)))
  function setMerkleRoot(bytes32 _merkleRoot) external virtual onlyFundingOwner {
    if (_merkleRoot == bytes32(0)) revert CannotBeZero();
    merkleRoot = _merkleRoot;
  }

  /// @notice Opens public minting. Only the legacy direct-mint fixture supports an allowlist.
  function enablePublicMint() public virtual onlyFundingOwner {
    publicMintEnabled = true;
    emit PublicMintEnabled();
  }

  /// @notice Starts the mint window. Can only be called once.
  function enableMint() public virtual onlyFundingOwner {
    if (mintEnabled) revert MintAlreadyEnabled();
    mintEnabled = true;
    mintStartTime = block.timestamp;
    emit MintStarted(mintStartTime, mintStartTime + MINT_PERIOD);
  }

  /// @notice Pays vested funds to the owner. Owner-only so the owner controls when payouts happen.
  /// @dev Burns also trigger a payout of everything vested up to that moment, so holders are never short-changed.
  function claimOwnerShare() external virtual onlyFundingOwner nonReentrant {
    uint256 share = _settleOwnerShare();
    if (share > 0) _sendETH(_fundingOwner(), share);
  }

  /// @notice Select an instance of this build's immutable-asset renderer.
  function setMetadataRenderer(address renderer) external onlyFundingOwner {
    _selectRenderer(renderer);
  }

  /// @dev Reject EOAs, proxies and different runtime implementations, including mutable renderers.
  function _selectRenderer(address renderer) private {
    if (renderer.codehash != _rendererCodeHash) {
      revert InvalidParameter();
    }
    metadataRenderer = FundingCardRenderer(renderer);
    emit MetadataRendererUpdated(renderer);
  }

  /// @notice Ends the mint and starts vesting. Callable by ANYONE once the mint is sold out or the window has ended,
  ///         so a founder cannot stall vesting (and therefore holder exits).
  /// @dev Pays the accumulated upfront share to the owner exactly once.
  function finalize() public virtual nonReentrant {
    _finalize(false);
  }

  function _finalize(bool closeEarly) internal virtual {
    if (!mintEnabled) revert MintNotEnabled();
    if (vestingStarted) revert VestingAlreadyStarted();
    if (!closeEarly && !mintComplete && block.timestamp <= mintStartTime + MINT_PERIOD) {
      revert MintNotComplete();
    }

    vestingStarted = true;
    _startVestingClock();

    uint256 upfront = initialPayoutAccrued;
    initialPayoutAccrued = 0;
    ownerPaidAmount += upfront;

    emit Finalized(
      vestingStartTime, vestingStartTime == 0 ? 0 : vestingStartTime + VESTING_PERIOD, upfront
    );
    if (upfront > 0) _sendETH(_fundingOwner(), upfront);
  }

  /// @notice Burns a token and returns its still-unvested ETH to the caller.
  /// @dev Pays the owner everything vested so far first, so the owner receives exactly the vested part of this
  ///      token and the holder receives exactly the rest.
  /// @param tokenId Token to burn (caller must own it)
  function _burnForRefund(uint256 tokenId) internal virtual {
    if (!vestingStarted) revert CannotBurn();
    if (_fundingTokenOwner(tokenId) != msg.sender) revert NotTokenOwner();

    // Effects: settle the owner's vested share while this token is still counted as active.
    uint256 ownerShare = _settleOwnerShare();
    uint256 refund = LOCKED_PER_TOKEN - _vestedPerToken();

    burnedTokenCount++;
    _destroyFundingToken(tokenId);

    emit Burned(msg.sender, tokenId, refund);

    // Interactions
    if (ownerShare > 0) _sendETH(_fundingOwner(), ownerShare);
    if (refund > 0) _sendETH(msg.sender, refund);
  }

  /* ═════════════════════════════════════════════════════ */
  /*                     VIEW FUNCTIONS                    */
  /* ═════════════════════════════════════════════════════ */

  /// @notice Scheduled mint deadline (0 if the mint has not started)
  function mintEndTime() external view returns (uint256) {
    return mintEnabled ? mintStartTime + MINT_PERIOD : 0;
  }

  /// @notice Timestamp when vesting ends (0 if vesting has not started)
  function vestingEndTime() external view virtual returns (uint256) {
    return vestingStarted ? vestingStartTime + VESTING_PERIOD : 0;
  }

  /// @notice Number of tokens currently in existence (minted minus burned)
  function activeSupply() public view returns (uint256) {
    return totalMinted - burnedTokenCount;
  }

  /// @notice Wei vested so far per token (0 before vesting starts, LOCKED_PER_TOKEN after it ends)
  function vestedPerToken() external view returns (uint256) {
    return _vestedPerToken();
  }

  /// @notice Wei a holder would receive by burning `tokenId` right now
  /// @param tokenId Token to check
  function getRemainingLockedEth(uint256 tokenId) public view virtual returns (uint256) {
    if (!_fundingTokenExists(tokenId)) revert TokenDoesNotExist();
    return LOCKED_PER_TOKEN - _vestedPerToken();
  }

  /// @notice Wei vested to the owner but not yet paid out
  function pendingOwnerShare() external view returns (uint256) {
    return _pendingOwnerShare();
  }

  /// @notice Total wei still backing holders' refund rights (what holders could collectively burn out right now)
  function totalUnvested() external view virtual returns (uint256) {
    return activeSupply() * (LOCKED_PER_TOKEN - _vestedPerToken());
  }

  /// @notice All release parameters in one call
  function getReleaseInfo() external view returns (ReleaseInfo memory) {
    return ReleaseInfo({
      maxSupply: MAX_SUPPLY,
      maxPerWallet: MAX_PER_WALLET,
      tokensMinted: totalMinted,
      activeSupply: activeSupply(),
      mintPrice: MINT_PRICE,
      mintPeriod: MINT_PERIOD,
      vestingPeriod: VESTING_PERIOD,
      initialPayoutBps: INITIAL_PAYOUT_BPS
    });
  }

  /* ═════════════════════════════════════════════════════ */
  /*                   INTERNAL FUNCTIONS                  */
  /* ═════════════════════════════════════════════════════ */

  /// @dev Mints `quantity` consecutive tokens to the caller and accrues the upfront payout.
  function _mintTokens(address minter, uint256 quantity) internal returns (uint256 firstTokenId) {
    firstTokenId = totalMinted + 1;
    totalMinted += quantity;
    mintedBy[minter] += quantity;
    initialPayoutAccrued += INITIAL_PAYOUT_PER_TOKEN * quantity;

    _issueTokens(minter, firstTokenId, quantity);

    if (totalMinted == MAX_SUPPLY) mintComplete = true;
    emit Minted(minter, quantity, firstTokenId);
  }

  function _startVestingClock() internal virtual {
    vestingStartTime = block.timestamp;
  }

  /// @dev Cumulative wei vested per token at the current time. Linear over VESTING_PERIOD, capped at LOCKED_PER_TOKEN.
  ///      Both the owner's payouts and holders' refunds are derived from this single function, which is why they
  ///      always add up to exactly LOCKED_PER_TOKEN per token.
  function _vestedPerToken() internal view virtual returns (uint256) {
    if (!vestingStarted) return 0;
    uint256 elapsed = block.timestamp - vestingStartTime;
    if (elapsed >= VESTING_PERIOD) return LOCKED_PER_TOKEN;
    return (LOCKED_PER_TOKEN * elapsed) / VESTING_PERIOD;
  }

  /// @dev Vested-but-unpaid amount for the owner across all active tokens.
  function _pendingOwnerShare() internal view virtual returns (uint256) {
    if (!vestingStarted) return 0;
    return activeSupply() * (_vestedPerToken() - lastPaidVestedPerToken);
  }

  /// @dev Updates accounting for the owner's pending share and returns it. The caller must send the ETH.
  function _settleOwnerShare() internal virtual returns (uint256 share) {
    share = _pendingOwnerShare();
    if (share == 0) return 0;
    if (address(this).balance < share) revert InsufficientContractBalance();
    lastPaidVestedPerToken = _vestedPerToken();
    ownerPaidAmount += share;
    emit OwnerShareClaimed(share);
  }

  /// @dev Sends ETH without letting a reverting recipient block the caller (uses Solady's force-send).
  function _sendETH(address to, uint256 amount) internal {
    SafeTransferLib.forceSafeTransferETH(to, amount);
  }

  /// @notice Direct calls with unknown data are rejected
  fallback() external {
    revert NotAllowed();
  }
}
