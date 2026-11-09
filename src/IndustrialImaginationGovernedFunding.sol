// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import { IndustrialImaginationSeaDropFunding } from "./IndustrialImaginationSeaDropFunding.sol";
import { FundingRecovery } from "./FundingRecovery.sol";
import { FundingCouncil } from "./FundingCouncil.sol";
import { TokenDoesNotExist } from "./FundingCore.sol";

/// @notice Net-funded SeaDrop collection with monthly holder-authorized claims
/// and irreversible council escape or timed wind-down into holder refunds.
contract IndustrialImaginationGovernedFunding is IndustrialImaginationSeaDropFunding {
  /// @notice Dedicated council that authorizes payments and tracks terminal exits.
  FundingCouncil public immutable council;
  /// @notice Dedicated non-upgradeable backup authorization helper; never holds proceeds.
  FundingRecovery public immutable recovery;
  /// @notice Monotonic ownership tenure identifier, invalidating all prior backup authority.
  uint256 public ownershipEpoch;
  /// @notice Share of the balance reserved at wind-down, expressed in basis points (5%).
  uint256 public constant WIND_DOWN_OWNER_BPS = 500;
  /// @notice Unclaimed wind-down reserve. Holder refunds always exclude this amount.
  uint256 public windDownOwnerReserve;
  /// @notice Owner at activation, whose reserve entitlement survives later ownership transfers.
  address public windDownBeneficiary;
  /// @notice Holder pool recorded when an exit activates. A wind-down excludes the reserved 5%.
  /// @dev Later refunds and unsolicited ETH change the live pool without changing this snapshot.
  uint256 public escapePoolAtActivation;
  error PeriodNotReady();
  error RefundUnavailable();
  error OwnerPaymentsStopped();
  /// @notice Records the exact balance split without requiring either recipient to accept ETH.
  event WindDownActivated(
    address indexed caller, address indexed beneficiary, uint256 reserve, uint256 refunds
  );
  /// @notice Emitted when the beneficiary's separately reserved share is successfully paid.
  event WindDownShareClaimed(address indexed beneficiary, uint256 amount);
  event EscapePoolOpened(uint256 pool, uint256 activeTokens);
  /// @notice Records excess ETH sent to the current owner after all refund rights have ended.
  event ExcessETHSwept(address indexed recipient, uint256 amount);

  /// @notice Deploy a fixed-term SeaDrop collection and its dedicated holder voting contract.
  /// @param supply Maximum number of NFTs that can be minted.
  /// @param walletCap Lifetime mint limit per wallet.
  /// @param grossPrice Price per NFT before SeaDrop fees, in wei.
  /// @param mintPeriod Duration of the original mint window, in seconds.
  /// @param vestingPeriod Stream duration, in seconds. Final partial cycles round up for review timing.
  /// @param upfrontBps Basis points of net principal paid at finalization.
  /// @param owner_ Initial owner and recipient of upfront and authorized cycle payments.
  /// @param renderer Immutable-asset metadata renderer selected for the collection.
  /// @param name_ ERC721 collection name.
  /// @param symbol_ ERC721 collection symbol.
  /// @param seaDrop Authorized SeaDrop minting contract.
  /// @param feeBps Basis points charged by SeaDrop against each mint's gross payment.
  /// @param feeRecipient Recipient of the SeaDrop mint fee.
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
    IndustrialImaginationSeaDropFunding(
      supply,
      walletCap,
      grossPrice,
      mintPeriod,
      vestingPeriod,
      upfrontBps,
      owner_,
      renderer,
      name_,
      symbol_,
      seaDrop,
      feeBps,
      feeRecipient
    )
  {
    council = new FundingCouncil();
    recovery = new FundingRecovery();
  }

  /// @dev Every completed handover, including recovery, invalidates previous backup requests.
  function _transferOwnership(address replacement) internal override {
    ownershipEpoch++;
    super._transferOwnership(replacement);
  }

  /// @notice Only the dedicated helper can execute an authenticated, matured recovery.
  /// @dev Clear an outstanding normal handover so its nominee cannot take ownership afterward.
  function recoverOwnership(address replacement) external {
    if (msg.sender != address(recovery)) revert NotAllowed();
    delete potentialOwner;
    emit PotentialOwnerUpdated(address(0));
    _transferOwnership(replacement);
  }

  /// @dev Record the finalization clock before upfront transfer. The sequential stream starts separately.
  /// This hook also runs for an owner closing the mint early.
  function _startVestingClock() internal override {
    council.noteFinalization();
  }

  /// @notice Owner starts the review clock once after finalization and before the unstarted backstop.
  /// @dev Council validation is atomic with setting the timestamp. A terminal exit blocks the start.
  function startPeriod() external onlyOwner {
    if (!vestingStarted || vestingStartTime != 0) revert PeriodNotReady();
    vestingStartTime = block.timestamp;
    council.startPeriod();
  }

  /// @notice Whether finalization has paid the accrued upfront allocation, independently of period start.
  function mintFinalized() external view returns (bool) {
    return vestingStarted;
  }

  /// @notice Claim cumulative authorized payments, or the latest eligible below-quorum installment.
  /// @dev Ordinary claims stop at the public backstop, even before someone executes wind-down.
  function claimOwnerShare() external override onlyOwner nonReentrant {
    _claim(0);
  }

  /// @notice Claim against an explicit approved or below-quorum cycle, including older cycles.
  /// @param cycle One-based accrual cycle whose authorization should be synchronized.
  function claimOwnerShareForCycle(uint256 cycle) external onlyOwner nonReentrant {
    _claim(cycle);
  }

  /// @dev Consume the council authorization before paying the owner. A transfer failure rolls it back.
  /// @param cycle Zero selects the default claim, otherwise an explicit review.
  function _claim(uint256 cycle) private {
    if (council.escapeActivated()) revert OwnerPaymentsStopped();
    uint256 perToken = council.authorizeClaim(cycle);
    uint256 amount = activeSupply() * perToken;
    if (amount == 0) return;
    lastPaidVestedPerToken += perToken;
    ownerPaidAmount += amount;
    emit OwnerShareClaimed(amount);
    _sendETH(owner(), amount);
  }

  /// @dev Quote the next default claim using the same authorization logic as the council.
  function _pendingOwnerShare() internal view override returns (uint256) {
    return activeSupply() * council.pendingPerToken();
  }

  /// @dev Elapsed streaming principal per token. This measures accrual rather than council approval.
  /// A terminal exit freezes the accrual clock at its activation time.
  function _vestedPerToken() internal view override returns (uint256) {
    if (vestingStartTime == 0) return 0;
    uint256 end = council.escapeActivatedAt();
    if (end == 0) end = block.timestamp;
    uint256 elapsed = end - vestingStartTime;
    if (elapsed >= VESTING_PERIOD) return LOCKED_PER_TOKEN;
    return LOCKED_PER_TOKEN * elapsed / VESTING_PERIOD;
  }

  /// @notice Stream end, shortened by a terminal exit, or zero if the period never started.
  function vestingEndTime() external view override returns (uint256) {
    if (vestingStartTime == 0) return 0;
    uint256 end = vestingStartTime + VESTING_PERIOD;
    uint256 escaped = council.escapeActivatedAt();
    return escaped != 0 && escaped < end ? escaped : end;
  }

  /// @notice Permanently wind down after owner inactivity eligibility or the public backstop.
  /// @dev Reserves 5% of the actual remaining ETH, including approved but unpaid proceeds.
  /// The upfront payout and any earlier payments have already left the pool and are excluded.
  /// No ETH is sent here, allowing holder refunds even when the beneficiary rejects transfers.
  function windDown() external nonReentrant {
    council.authorizeWindDown(msg.sender == owner());
    // Snapshot actual funds once. Subsequent donations go to holders without another owner levy.
    uint256 pool = address(this).balance;
    windDownBeneficiary = owner();
    // Exactly floor(pool * 500 / 10_000), without overflowing the multiplication
    // even if unsolicited ETH makes the live balance larger than mint principal.
    windDownOwnerReserve = pool / (BPS / WIND_DOWN_OWNER_BPS);
    escapePoolAtActivation = pool - windDownOwnerReserve;
    emit WindDownActivated(
      msg.sender, windDownBeneficiary, windDownOwnerReserve, escapePoolAtActivation
    );
    emit EscapePoolOpened(escapePoolAtActivation, activeSupply());
  }

  /// @notice Anyone may send the reserved 5% to the owner recorded at wind-down activation.
  /// @dev Clear the reserve before interacting. The shared helper can force-send to a rejecting wallet.
  /// Any failure rolls back this claim alone, preserving the reserve and independent holder refunds.
  function claimWindDownShare() external nonReentrant {
    // Read the reserved entitlement once, then clear it before the external ETH transfer.
    uint256 amount = windDownOwnerReserve;
    if (amount == 0) return;
    windDownOwnerReserve = 0;
    ownerPaidAmount += amount;
    _sendETH(windDownBeneficiary, amount);
    emit WindDownShareClaimed(windDownBeneficiary, amount);
  }

  /// @notice Anyone can send excess ETH to the current owner after exit and all burns.
  /// @dev The wind-down reserve remains payable separately to its recorded beneficiary.
  function sweepExcessETH() external nonReentrant {
    if (!council.escapeActivated() || activeSupply() != 0) revert NotAllowed();
    uint256 amount = _refundPool();
    if (amount == 0) return;
    address recipient = owner();
    emit ExcessETHSwept(recipient, amount);
    _sendETH(recipient, amount);
  }

  /// @dev Balance available to holders. Late unsolicited ETH joins their pool in full.
  function _refundPool() private view returns (uint256) {
    return address(this).balance - windDownOwnerReserve;
  }

  /// @notice Called atomically when a holder majority activates escape.
  function activateEscape() external nonReentrant {
    if (msg.sender != address(council) || !council.escapeActivated()) revert NotAllowed();
    escapePoolAtActivation = address(this).balance;
    emit EscapePoolOpened(escapePoolAtActivation, activeSupply());
  }

  /// @notice Burn an owned NFT after exit and claim its share of the remaining holder pool.
  /// @param tokenId Existing token owned by the caller.
  /// @dev Reserve subtraction makes refunds independent of whether the owner has claimed the 5%.
  /// Integer division leaves dust for later holders, and the final holder receives all remaining dust.
  function _burnForRefund(uint256 tokenId) internal override {
    if (!council.escapeActivated()) revert RefundUnavailable();
    if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
    // Divide the current pool among remaining tokens. The final claimant gets
    // integer rounding remainder, and every refund reduces both pool and supply.
    uint256 refund = _refundPool() / activeSupply();
    burnedTokenCount++;
    _destroyFundingToken(tokenId);
    emit Burned(msg.sender, tokenId, refund);
    if (refund != 0) _sendETH(msg.sender, refund);
  }

  /// @notice Refund currently available for an existing NFT after a terminal exit.
  /// @param tokenId Existing token whose refund should be quoted, regardless of caller identity.
  function getRemainingLockedEth(uint256 tokenId) public view override returns (uint256) {
    if (!_exists(tokenId)) revert TokenDoesNotExist();
    return council.escapeActivated() ? _refundPool() / activeSupply() : 0;
  }

  /// @notice Holder refund pool after exit, excluding any unclaimed owner reserve.
  /// Before exit this retains the legacy elapsed-time estimate of unstreamed principal.
  function totalUnvested() external view override returns (uint256) {
    return council.escapeActivated()
      ? _refundPool()
      : activeSupply() * (LOCKED_PER_TOKEN - _vestedPerToken());
  }
}
