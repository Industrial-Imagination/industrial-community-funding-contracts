// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal interface; this helper never receives custody of funding proceeds.
interface IRecoveryFunding {
  function owner() external view returns (address);
  function mintEnabled() external view returns (bool);
  function ownershipEpoch() external view returns (uint256);
  function recoverOwnership(address replacement) external;
}

/// @notice Consensual backup designation before minting, followed by cancellable seven-day recovery.
contract FundingRecovery {
  /// @notice Fixed delay between a backup's request and its execution.
  uint256 public constant DELAY = 7 days;
  /// @notice The deploying collection; it alone can be recovered through this helper.
  IRecoveryFunding public immutable funding;
  /// @dev Epoch binds all designations and requests to one uninterrupted ownership tenure.
  uint256 private _epoch;
  /// @dev Proposed wallet, which must accept before minting starts.
  address private _nominee;
  /// @dev Accepted wallet. A completed ownership change invalidates this value through the epoch.
  address private _backup;
  /// @dev Earliest execution timestamp; zero means no pending request.
  uint256 private _readyAt;

  error Unauthorized();
  error InvalidBackup();
  error ConfigurationClosed();
  error RecoveryNotReady();
  event BackupNominated(address indexed wallet, uint256 indexed epoch);
  event BackupAccepted(address indexed wallet, uint256 indexed epoch);
  event RecoveryRequested(address indexed wallet, uint256 readyAt);
  event RecoveryCancelled();
  event RecoveryExecuted(address indexed previousOwner, address indexed replacement);

  /// @notice Bind permanently to the collection that creates this helper.
  constructor() {
    funding = IRecoveryFunding(msg.sender);
  }

  /// @dev Epoch checking also prevents stale authority if ownership leaves and later returns.
  function _current() private view returns (bool) {
    return _epoch == funding.ownershipEpoch();
  }

  /// @notice Effective nomination, or zero after an ownership change.
  function nominee() external view returns (address) {
    return _current() ? _nominee : address(0);
  }

  /// @notice Effective accepted backup, or zero after an ownership change.
  function backup() public view returns (address) {
    return _current() ? _backup : address(0);
  }

  /// @notice Effective recovery deadline, or zero when no valid request exists.
  function readyAt() external view returns (uint256) {
    return _current() ? _readyAt : 0;
  }

  /// @notice Owner proposes a distinct backup before minting. Zero clears the designation.
  /// @dev Replacing a nomination invalidates the old acceptance and pending request immediately.
  function nominateBackup(address wallet) external {
    if (msg.sender != funding.owner()) revert Unauthorized();
    if (funding.mintEnabled()) revert ConfigurationClosed();
    if (wallet == msg.sender || wallet == address(this) || wallet == address(funding)) {
      revert InvalidBackup();
    }
    _epoch = funding.ownershipEpoch();
    _nominee = wallet;
    _backup = address(0);
    _readyAt = 0;
    emit BackupNominated(wallet, _epoch);
  }

  /// @notice The nominated wallet confirms control and consent before minting begins.
  function acceptBackup() external {
    if (!_current() || msg.sender != _nominee || msg.sender == address(0)) revert Unauthorized();
    if (funding.mintEnabled()) revert ConfigurationClosed();
    _backup = msg.sender;
    _nominee = address(0);
    emit BackupAccepted(msg.sender, _epoch);
  }

  /// @notice Only the accepted backup can start a fresh seven-day recovery request.
  function requestRecovery() external {
    if (msg.sender != backup() || msg.sender == address(0)) revert Unauthorized();
    if (_readyAt != 0) revert RecoveryNotReady();
    _readyAt = block.timestamp + DELAY;
    emit RecoveryRequested(msg.sender, _readyAt);
  }

  /// @notice Current owner may cancel even after the deadline, until execution occurs.
  /// @dev Cancellation consumes this request; a retry starts a full new seven-day delay.
  function cancelRecovery() external {
    if (msg.sender != funding.owner()) revert Unauthorized();
    _readyAt = 0;
    emit RecoveryCancelled();
  }

  /// @notice Backup executes after the delay. No payment or refund authorization is changed.
  /// @dev Effects precede the trusted collection call; its ownership epoch invalidates this backup.
  function executeRecovery() external {
    if (msg.sender != backup() || msg.sender == address(0)) revert Unauthorized();
    if (_readyAt == 0 || block.timestamp < _readyAt) revert RecoveryNotReady();
    address previous = funding.owner();
    _readyAt = 0;
    funding.recoverOwnership(msg.sender);
    emit RecoveryExecuted(previous, msg.sender);
  }
}
