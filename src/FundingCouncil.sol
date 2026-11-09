// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICouncilFunding {
  function owner() external view returns (address);
  function ownerOf(uint256 tokenId) external view returns (address);
  function mintedBy(address wallet) external view returns (uint256);
  function totalMinted() external view returns (uint256);
  function VESTING_PERIOD() external view returns (uint256);
  function LOCKED_PER_TOKEN() external view returns (uint256);
  function activateEscape() external;
}

/// @notice Holder voting, installment authorization, and terminal exit for one funding collection.
contract FundingCouncil {
  /// @notice Length of each accrual cycle.
  uint256 public constant CYCLE = 30 days;
  /// @notice Duration of a review or escape ballot.
  uint256 public constant VOTING = 72 hours;
  /// @notice Time from review opening until a below-quorum installment may be claimed.
  uint256 public constant SILENCE_DELAY = 7 days;
  /// @notice Required time without a majority review decision for an owner wind-down.
  uint256 public constant WIND_DOWN_DELAY = 90 days;
  /// @notice Public backstop when the period never starts.
  uint256 public constant UNSTARTED_BACKSTOP = 180 days;
  /// @notice Collection that holds the NFTs and proceeds.
  ICouncilFunding public immutable funding;
  /// @notice Mint finalization timestamp, before any upfront ETH transfer.
  uint256 public finalizedAt;
  /// @notice Start of the accrual schedule and snapshot of voting eligibility.
  uint256 public periodStart;
  /// @notice Number of scheduled reviews, including any final partial installment.
  uint256 public reviewCount;
  /// @notice Funding owner excluded from voting at the start snapshot.
  address public excludedOwner;
  /// @notice Number of eligible NFTs at the start snapshot.
  uint256 public eligibleSupply;
  /// @notice Minimum votes cast, rounded up from 10% of eligible NFTs.
  uint256 public quorum;
  /// @notice Terminal state shared by holder escape and timed wind-down.
  bool public escapeActivated;
  /// @notice Timestamp used to freeze accrual on a terminal exit.
  uint256 public escapeActivatedAt;

  /// @dev Silence retains its ABI value/name but includes all below-quorum fallback outcomes.
  enum Outcome {
    Unresolved,
    Approved,
    Rejected,
    Silence
  }

  struct Ballot {
    /// @dev Yes and no counts include one vote per eligible NFT.
    uint256 yes;
    uint256 no;
    /// @dev Token IDs already used on this ballot, independent of wallet balance.
    mapping(uint256 => bool) voted;
  }

  struct EscapeBallot {
    /// @dev Opening timestamp and second rejected cycle that qualified this round.
    uint256 startedAt;
    uint256 rejectedCycle;
    /// @dev A recorded approval through the rejected pair closed by this round's deadline.
    bool superseded;
    Ballot votes;
  }

  /// @dev Latest review with any votes. Earlier reviews are recorded when a later review receives a vote.
  uint256 private _latestVotedCycle;
  /// @dev Last review processed into the decision and authorization checkpoints.
  uint256 private _recordedCycle;
  /// @dev Highest recorded explicit approval and latest pair of consecutive rejections.
  uint256 private _approvedThrough;
  uint256 private _lastRejectedPair;
  /// @dev Closing time of the latest review with a decisive, quorate majority.
  uint256 private _lastMajorityDecisionAt;
  /// @notice Highest cycle already settled under a cumulative approval.
  uint256 public paidThroughCycle;
  /// @notice Tracks isolated silence claims so an installment cannot be paid twice.
  mapping(uint256 => bool) public silencePaid;
  /// @dev Fenwick tree of silence payments per token. Prefix sums deduct already paid installments
  /// from later cumulative approvals in logarithmic time, regardless of how many cycles elapsed.
  mapping(uint256 => uint256) private _silencePaidTree;
  /// @dev Per-cycle ballots and individually tracked escape rounds.
  mapping(uint256 => Ballot) private _reviews;
  mapping(uint256 => EscapeBallot) private _escapeBallots;
  /// @notice Latest escape round, or zero before one is opened.
  uint256 public escapeRound;

  error Unauthorized();
  error InvalidPeriod();
  error VotingClosed();
  error AlreadyVoted();
  error ReviewNotApproved();
  error EscapeNotEligible();
  error EscapeHasPriority();
  error EscapeVoteActive();
  error Escaped();
  event PeriodStarted(uint256 start, uint256 eligibleSupply, uint256 quorum, address excludedOwner);
  event ReviewVote(
    uint256 indexed cycle, address indexed voter, uint256 indexed tokenId, bool approve
  );
  event EscapeVoteOpened(uint256 indexed round, uint256 indexed rejectedCycle, uint256 deadline);
  event EscapeVote(
    uint256 indexed round, address indexed voter, uint256 indexed tokenId, bool activate
  );
  event EscapeActivated(uint256 indexed round, uint256 activatedAt);

  /// @notice Bind to the deploying collection.
  constructor() {
    funding = ICouncilFunding(msg.sender);
  }

  modifier onlyFunding() {
    if (msg.sender != address(funding)) revert Unauthorized();
    _;
  }

  modifier live() {
    if (escapeActivated) revert Escaped();
    _;
  }

  /// @notice Anchor the unstarted and owner-inactivity deadlines at mint finalization.
  function noteFinalization() external onlyFunding {
    if (finalizedAt != 0) revert InvalidPeriod();
    finalizedAt = block.timestamp;
  }

  /// @notice Start reviews and snapshot eligible supply after minting is permanently closed.
  /// @dev Soulbound tokens cannot move or burn during voting, so ownership needs no per-token snapshot.
  function startPeriod() external onlyFunding live {
    if (finalizedAt == 0 || periodStart != 0 || publicWindDownReady()) revert InvalidPeriod();
    periodStart = block.timestamp;
    reviewCount = (funding.VESTING_PERIOD() - 1) / CYCLE + 1;
    excludedOwner = funding.owner();
    eligibleSupply = funding.totalMinted() - funding.mintedBy(excludedOwner);
    quorum = (eligibleSupply + 9) / 10;
    emit PeriodStarted(periodStart, eligibleSupply, quorum, excludedOwner);
  }

  /// @notice Scheduled public backstop timestamp, or zero before finalization.
  function publicWindDownAt() public view returns (uint256) {
    if (finalizedAt == 0) return 0;
    if (periodStart == 0) return finalizedAt + UNSTARTED_BACKSTOP;
    return reviewDeadline(reviewCount) + WIND_DOWN_DELAY;
  }

  /// @notice Whether the public deadline has arrived and ordinary payments must stop.
  function publicWindDownReady() public view returns (bool) {
    uint256 deadline = publicWindDownAt();
    return deadline != 0 && block.timestamp >= deadline;
  }

  /// @notice Validate the public backstop or owner inactivity route and permanently stop voting.
  function authorizeWindDown(bool ownerCall) external onlyFunding live {
    if (finalizedAt == 0) revert InvalidPeriod();
    EscapeBallot storage ballot = _escapeBallots[escapeRound];
    if (_escapePassed(ballot)) revert EscapeHasPriority();
    if (publicWindDownReady()) {
      if (block.timestamp < ballot.startedAt + VOTING && _escapeEligible(ballot.rejectedCycle)) {
        revert EscapeVoteActive();
      }
    } else {
      _recordLatestReview();
      uint256 lastDecision = _lastMajorityDecisionAt;
      if (lastDecision < finalizedAt) lastDecision = finalizedAt;
      if (!ownerCall || block.timestamp < lastDecision + WIND_DOWN_DELAY) revert InvalidPeriod();
      if (_escapeEligible(_lastRejectedPair)) revert EscapeHasPriority();
    }
    escapeActivated = true;
    escapeActivatedAt = block.timestamp;
  }

  /// @notice Opening timestamp of a scheduled review.
  function reviewStart(uint256 cycle) public view returns (uint256) {
    if (cycle == 0 || cycle > reviewCount) revert InvalidPeriod();
    return periodStart + cycle * CYCLE;
  }

  /// @notice Exclusive voting deadline of a scheduled review.
  function reviewDeadline(uint256 cycle) public view returns (uint256) {
    return reviewStart(cycle) + VOTING;
  }

  /// @notice Current yes and no counts for a review.
  function reviews(uint256 cycle) external view returns (uint256 yes, uint256 no) {
    Ballot storage ballot = _reviews[cycle];
    return (ballot.yes, ballot.no);
  }

  /// @notice Whether a token already voted on a review.
  function hasVotedReview(uint256 cycle, uint256 tokenId) external view returns (bool) {
    return _reviews[cycle].voted[tokenId];
  }

  /// @notice Cast one vote per owned eligible NFT, in one transaction.
  function voteReview(uint256 cycle, uint256[] calldata tokenIds, bool approve) external live {
    uint256 start = reviewStart(cycle);
    if (block.timestamp < start || block.timestamp >= start + VOTING) revert VotingClosed();
    if (cycle != _latestVotedCycle) {
      _recordLatestReview();
      _latestVotedCycle = cycle;
    }
    _cast(_reviews[cycle], tokenIds, approve);
    for (uint256 i; i < tokenIds.length; i++) {
      emit ReviewVote(cycle, msg.sender, tokenIds[i], approve);
    }
  }

  /// @notice Final review result. Below-quorum turnout becomes fallback-eligible after seven days.
  /// @dev Quorate ties remain unresolved. Zero eligible supply retains the zero-vote fallback.
  function outcome(uint256 cycle) public view returns (Outcome) {
    uint256 start = reviewStart(cycle);
    if (block.timestamp < start + VOTING) return Outcome.Unresolved;
    Ballot storage ballot = _reviews[cycle];
    if (ballot.yes + ballot.no >= quorum) {
      if (ballot.yes > ballot.no) return Outcome.Approved;
      if (ballot.no > ballot.yes) return Outcome.Rejected;
    }
    if (
      (ballot.yes + ballot.no < quorum || ballot.yes + ballot.no == 0)
        && block.timestamp >= start + SILENCE_DELAY
    ) {
      return Outcome.Silence;
    }
    return Outcome.Unresolved;
  }

  /// @notice Highest explicit approval. Includes the latest closed review without a keeper transaction.
  function approvedThroughCycle() public view returns (uint256) {
    if (_latestVotedCycle > _recordedCycle && outcome(_latestVotedCycle) == Outcome.Approved) {
      return _latestVotedCycle;
    }
    return _approvedThrough;
  }

  /// @notice Closing time of the latest quorate majority decision, or zero if none.
  function lastMajorityDecisionAt() external view returns (uint256) {
    if (_latestVotedCycle > _recordedCycle) {
      Outcome result = outcome(_latestVotedCycle);
      if (result == Outcome.Approved || result == Outcome.Rejected) {
        return reviewDeadline(_latestVotedCycle);
      }
    }
    return _lastMajorityDecisionAt;
  }

  /// @dev Persist the latest closed voted review before moving to a later one or mutating authorization.
  function _recordLatestReview() private {
    uint256 cycle = _latestVotedCycle;
    if (cycle == _recordedCycle || block.timestamp < reviewDeadline(cycle)) return;
    _recordedCycle = cycle;
    Outcome result = outcome(cycle);
    if (result == Outcome.Approved || result == Outcome.Rejected) {
      _lastMajorityDecisionAt = reviewDeadline(cycle);
    }
    if (result == Outcome.Approved) {
      _approvedThrough = cycle;
      EscapeBallot storage ballot = _escapeBallots[escapeRound];
      if (_approvalSupersedes(ballot, cycle)) ballot.superseded = true;
    }
    if (result == Outcome.Rejected && cycle >= 2 && outcome(cycle - 1) == Outcome.Rejected) {
      _lastRejectedPair = cycle;
    }
  }

  /// @notice Wei per token payable by a default claim. Explicit claims can select an older below-quorum review.
  function pendingPerToken() external view returns (uint256) {
    if (periodStart == 0 || escapeActivated || publicWindDownReady()) return 0;
    if (_escapePassed(_escapeBallots[escapeRound])) return 0;
    (, uint256 amount,) = _payment(0);
    return amount;
  }

  /// @notice Consume one authorization and return its payable wei per token to the collection.
  /// @dev Default claims prioritize explicit cumulative approvals, then the latest matured below-quorum review.
  function authorizeClaim(uint256 cycle) external onlyFunding live returns (uint256 amount) {
    if (periodStart == 0) revert ReviewNotApproved();
    if (publicWindDownReady()) revert Escaped();
    if (_escapePassed(_escapeBallots[escapeRound])) revert EscapeHasPriority();
    _recordLatestReview();
    (uint256 through, uint256 payableAmount, bool silence) = _payment(cycle);
    if (through == 0) revert ReviewNotApproved();
    if (silence) {
      silencePaid[through] = true;
      for (uint256 i = through; i <= reviewCount; i += i & (~i + 1)) {
        _silencePaidTree[i] += payableAmount;
      }
    } else if (through > paidThroughCycle) {
      paidThroughCycle = through;
    }
    return payableAmount;
  }

  /// @dev Resolve which authorization applies. Silence can never authorize a preceding installment.
  function _payment(uint256 cycle)
    private
    view
    returns (uint256 through, uint256 amount, bool silence)
  {
    uint256 approved = approvedThroughCycle();
    if (cycle == 0 && approved > paidThroughCycle) {
      return (approved, _cumulativePayment(approved), false);
    }
    if (cycle == 0) {
      uint256 elapsed = block.timestamp - periodStart;
      if (elapsed < CYCLE + SILENCE_DELAY) return (approved, 0, false);
      cycle = (elapsed - SILENCE_DELAY) / CYCLE;
      if (cycle > reviewCount) cycle = reviewCount;
      if (outcome(cycle) != Outcome.Silence) return (approved, 0, false);
    }
    Outcome result = outcome(cycle);
    if (result == Outcome.Approved) {
      return (cycle, cycle > paidThroughCycle ? _cumulativePayment(cycle) : 0, false);
    }
    if (result != Outcome.Silence) return (0, 0, false);
    // A repeated silence claim remains an isolated payment, even when it pays zero.
    // Labeling it cumulative would advance paidThroughCycle past unpaid or rejected
    // installments and incorrectly deduct those installments from a later approval.
    if (cycle <= paidThroughCycle || silencePaid[cycle]) return (cycle, 0, true);
    return (cycle, _vested(cycle) - _vested(cycle - 1), true);
  }

  /// @dev Deduct only previously claimed fallback installments within the newly approved range.
  function _cumulativePayment(uint256 through) private view returns (uint256) {
    return _vested(through) - _vested(paidThroughCycle)
      - (_silencePrefix(through) - _silencePrefix(paidThroughCycle));
  }

  /// @dev Sum isolated silence payments through a cycle without iterating the full schedule.
  function _silencePrefix(uint256 cycle) private view returns (uint256 amount) {
    for (uint256 i = cycle; i != 0; i &= i - 1) {
      amount += _silencePaidTree[i];
    }
  }

  /// @dev Cumulative scheduled principal per token, capped at the stream duration.
  function _vested(uint256 cycle) private view returns (uint256) {
    uint256 duration = funding.VESTING_PERIOD();
    uint256 elapsed = cycle * CYCLE;
    if (elapsed > duration) elapsed = duration;
    return funding.LOCKED_PER_TOKEN() * elapsed / duration;
  }

  /// @notice Current escape ballot timing, rejected pair and vote counts.
  function escapeBallots(uint256 round)
    external
    view
    returns (uint256 startedAt, uint256 rejectedCycle, uint256 yes, uint256 no)
  {
    EscapeBallot storage ballot = _escapeBallots[round];
    return (ballot.startedAt, ballot.rejectedCycle, ballot.votes.yes, ballot.votes.no);
  }

  /// @notice Whether a token already voted on an escape ballot.
  function hasVotedEscape(uint256 round, uint256 tokenId) external view returns (bool) {
    return _escapeBallots[round].votes.voted[tokenId];
  }

  /// @notice An eligible holder opens a separate escape ballot after two consecutive rejections.
  function openEscapeVote(uint256 secondRejectedCycle, uint256 tokenId) external live {
    if (publicWindDownReady()) revert VotingClosed();
    _requireEligible(tokenId);
    _recordLatestReview();
    if (!_escapeEligible(secondRejectedCycle)) revert EscapeNotEligible();
    EscapeBallot storage previous = _escapeBallots[escapeRound];
    if (
      _escapePassed(previous)
        || (block.timestamp < previous.startedAt + VOTING
          && _escapeEligible(previous.rejectedCycle))
    ) revert EscapeVoteActive();
    uint256 round = ++escapeRound;
    EscapeBallot storage ballot = _escapeBallots[round];
    ballot.startedAt = block.timestamp;
    ballot.rejectedCycle = secondRejectedCycle;
    emit EscapeVoteOpened(round, secondRejectedCycle, block.timestamp + VOTING);
  }

  /// @notice Cast holder votes during the escape window. The result is final only after it closes.
  function voteEscape(uint256 round, uint256[] calldata tokenIds, bool activate) external live {
    EscapeBallot storage ballot = _escapeBallots[round];
    if (round == 0 || round != escapeRound || block.timestamp >= ballot.startedAt + VOTING) {
      revert VotingClosed();
    }
    if (!_escapeEligible(ballot.rejectedCycle)) revert EscapeNotEligible();
    _cast(ballot.votes, tokenIds, activate);
    for (uint256 i; i < tokenIds.length; i++) {
      emit EscapeVote(round, msg.sender, tokenIds[i], activate);
    }
  }

  /// @notice Anyone may execute a closed, quorate escape ballot with a majority in favor.
  function executeEscape(uint256 round) external live {
    EscapeBallot storage ballot = _escapeBallots[round];
    if (round == 0 || round != escapeRound || block.timestamp < ballot.startedAt + VOTING) {
      revert VotingClosed();
    }
    if (!_escapePassed(ballot)) revert EscapeNotEligible();
    escapeActivated = true;
    escapeActivatedAt = block.timestamp;
    funding.activateEscape();
    emit EscapeActivated(round, block.timestamp);
  }

  /// @dev An approval through the rejected pair can supersede this round only by its close.
  function _approvalSupersedes(EscapeBallot storage ballot, uint256 cycle)
    private
    view
    returns (bool)
  {
    return ballot.startedAt != 0 && cycle >= ballot.rejectedCycle
      && reviewDeadline(cycle) <= ballot.startedAt + VOTING;
  }

  /// @dev A winning ballot locks in at close. Check the latest review even before it is recorded.
  function _escapePassed(EscapeBallot storage ballot) private view returns (bool) {
    if (
      ballot.startedAt == 0 || block.timestamp < ballot.startedAt + VOTING || ballot.superseded
        || !_escapeApproved(ballot)
    ) return false;
    return !(_latestVotedCycle > _recordedCycle && _approvalSupersedes(ballot, _latestVotedCycle)
        && outcome(_latestVotedCycle) == Outcome.Approved);
  }

  /// @dev Only an explicit approval can supersede rejected installments and clear eligibility.
  function _escapeEligible(uint256 cycle) private view returns (bool) {
    return cycle >= 2 && cycle <= reviewCount && approvedThroughCycle() < cycle
      && outcome(cycle - 1) == Outcome.Rejected && outcome(cycle) == Outcome.Rejected;
  }

  /// @dev Escape requires both turnout and a strict yes majority. Silence never authorizes it.
  function _escapeApproved(EscapeBallot storage ballot) private view returns (bool) {
    return ballot.votes.yes + ballot.votes.no >= quorum && ballot.votes.yes > ballot.votes.no;
  }

  /// @dev Reject empty batches, duplicate token IDs and votes from ineligible wallets atomically.
  function _cast(Ballot storage ballot, uint256[] calldata tokenIds, bool approve) private {
    if (tokenIds.length == 0) revert Unauthorized();
    for (uint256 i; i < tokenIds.length; i++) {
      uint256 tokenId = tokenIds[i];
      _requireEligible(tokenId);
      if (ballot.voted[tokenId]) revert AlreadyVoted();
      ballot.voted[tokenId] = true;
    }
    if (approve) ballot.yes += tokenIds.length;
    else ballot.no += tokenIds.length;
  }

  /// @dev Only the current owner of an eligible soulbound NFT can exercise that vote.
  function _requireEligible(uint256 tokenId) private view {
    if (msg.sender == excludedOwner || funding.ownerOf(tokenId) != msg.sender) {
      revert Unauthorized();
    }
  }
}
