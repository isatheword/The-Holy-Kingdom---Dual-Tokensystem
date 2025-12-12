// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IKDR {
    function claimForCitizen(address to, uint256 amount) external;
    function decimals() external view returns (uint8);
}

interface IKCP {
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
}

/**
 * @title CitizenRewardEngine V3
 * @notice Lazy minting with 7-year halving schedule, fixed pool distribution, and Bayt al-Mal sweeping
 * @dev Fair distribution with daily snapshots - prevents mid-day manipulation
 * 
 * KEY IMPROVEMENTS:
 * - Daily snapshot of citizen count (first claim locks the divisor)
 * - Daily snapshot of pool amount (immutable once day starts)
 * - Pool divided by TOTAL citizens (not claim order) - prevents over-distribution
 * - 70% base pool + 30% bonus pool - sustainable streak rewards
 * - Unclaimed funds swept to treasury (Bayt al-Mal) after each day
 * - Hard cap prevents any daily pool exhaustion
 */
contract CitizenRewardEngineV3 is Ownable, Pausable, ReentrancyGuard {
    
    IKDR public immutable kdr;
    IKCP public immutable kcp;
    
    uint256 public immutable launchTimestamp;
    uint256 public constant SECONDS_PER_DAY = 86400;
    
    // Halving schedule: 7 years total, halving every 2 years
    uint256 public constant PHASE_1_END = 730 days;   // Years 0-2: 30,336 KDR/day
    uint256 public constant PHASE_2_END = 1460 days;  // Years 2-4: 15,168 KDR/day
    uint256 public constant PHASE_3_END = 2190 days;  // Years 4-6: 7,584 KDR/day
    uint256 public constant PHASE_4_END = 2555 days;  // Years 6-7: 3,792 KDR/day
    
    uint256 public constant PHASE_1_POOL = 30336e18;
    uint256 public constant PHASE_2_POOL = 15168e18;
    uint256 public constant PHASE_3_POOL = 7584e18;
    uint256 public constant PHASE_4_POOL = 3792e18;
    
    // Total allocated: ~55M KDR over 7 years
    // 70% base distribution, 30% streak bonus rewards
    uint256 public constant BASE_POOL_PERCENT = 70;
    uint256 public constant BONUS_POOL_PERCENT = 30;
    
    // Per-citizen data
    mapping(uint256 => uint256) public accumulatedBalance;
    mapping(uint256 => uint256) public lastClaimDay;
    mapping(uint256 => uint256) public currentStreak;
    mapping(uint256 => uint256) public longestStreak;
    mapping(uint256 => uint256) public totalClaimsMade;
    mapping(uint256 => uint256) public totalKDRAccumulated;
    mapping(uint256 => uint256) public totalKDRWithdrawn;
    mapping(uint256 => bool) public hasEverClaimed; // Fix for dayIndex 0 issue
    
    // Daily tracking
    mapping(uint256 => uint256) public dailyClaimCount;
    mapping(uint256 => uint256) public dailyPoolDistributed;
    mapping(uint256 => bool) public daySwept;
    
    // Daily snapshots (locked on first claim of the day)
    mapping(uint256 => uint256) public citizensSnapshot; // Total KCP supply for the day
    mapping(uint256 => uint256) public poolSnapshot; // Pool amount for the day
    mapping(uint256 => bool) public dayInitialized; // Has day been snapshotted yet
    
    // Treasury address for unclaimed rewards (Bayt al-Mal)
    address public treasury;
    
    bool public emergencyMode;
    
    event DailyClaimed(
        address indexed user,
        uint256 indexed tokenId,
        uint256 dayIndex,
        uint256 baseShare,
        uint256 streakBonus,
        uint256 totalClaimed,
        uint256 newStreak
    );
    
    event Withdrawn(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 remainingBalance
    );
    
    event DayInitialized(uint256 dayIndex, uint256 citizenCount, uint256 dailyPool);
    event StreakReset(uint256 indexed tokenId, uint256 oldStreak);
    event EmergencyModeSet(bool enabled);
    event UnclaimedSwept(uint256 dayIndex, uint256 amount, address treasury);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    
    error EmergencyModeActive();
    error NotTokenOwner();
    error MintingNotStarted();
    error MintingEnded();
    error AlreadyClaimedToday();
    error InsufficientBalance();
    error InvalidAmount();
    error NoCitizenship();
    error DailyPoolExhausted();
    error DayNotComplete();
    error AlreadySwept();
    error ZeroAddress();
    
    constructor(
        address kdrAddress,
        address kcpAddress,
        address initialOwner,
        address _treasury,
        uint256 _launchTimestamp
    ) Ownable(initialOwner) {
        require(kdrAddress != address(0), "Zero KDR");
        require(kcpAddress != address(0), "Zero KCP");
        require(_treasury != address(0), "Zero treasury");
        
        kdr = IKDR(kdrAddress);
        kcp = IKCP(kcpAddress);
        treasury = _treasury;
        
        launchTimestamp = _launchTimestamp == 0 ? block.timestamp : _launchTimestamp;
    }
    
    /**
     * @notice Daily claim - accumulates KDR balance on-chain
     * @dev Fair distribution with daily snapshots - first claim locks citizen count and pool
     * @param tokenId The KCP token ID
     */
    function claimDaily(uint256 tokenId) external whenNotPaused nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
        if (kcp.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        
        uint256 currentDay = getCurrentDayIndex();
        
        // Check timing
        if (block.timestamp < launchTimestamp) revert MintingNotStarted();
        uint256 daysSinceLaunch = getDaysSinceLaunch();
        if (daysSinceLaunch >= PHASE_4_END / SECONDS_PER_DAY) revert MintingEnded();
        if (hasEverClaimed[tokenId] && lastClaimDay[tokenId] == currentDay) revert AlreadyClaimedToday();
        
        // Initialize day on first claim (snapshot citizen count and pool)
        if (!dayInitialized[currentDay]) {
            _initializeDay(currentDay);
        }
        
        // Get snapshotted values for the day
        uint256 dailyPool = poolSnapshot[currentDay];
        uint256 totalCitizens = citizensSnapshot[currentDay];
        
        uint256 basePoolBudget = (dailyPool * BASE_POOL_PERCENT) / 100;
        uint256 bonusPoolBudget = (dailyPool * BONUS_POOL_PERCENT) / 100;
        
        // Fair distribution: divide by total citizens (snapshotted at day start)
        uint256 baseShare = basePoolBudget / totalCitizens;
        
        // Update streak
        _updateStreak(tokenId, currentDay);
        
        // Calculate streak bonus from bonus pool (1% per day, max 100%)
        uint256 streak = currentStreak[tokenId];
        uint256 streakPercent = streak > 100 ? 100 : streak;
        uint256 bonusPerCitizen = bonusPoolBudget / totalCitizens;
        uint256 streakBonus = (bonusPerCitizen * streakPercent) / 100;
        
        uint256 totalReward = baseShare + streakBonus;
        
        // SAFETY: Hard cap to prevent any over-distribution
        require(
            dailyPoolDistributed[currentDay] + totalReward <= dailyPool,
            "Daily pool exhausted"
        );
        
        // Update state
        hasEverClaimed[tokenId] = true;
        lastClaimDay[tokenId] = currentDay;
        dailyClaimCount[currentDay] += 1;
        dailyPoolDistributed[currentDay] += totalReward;
        
        accumulatedBalance[tokenId] += totalReward;
        totalClaimsMade[tokenId] += 1;
        totalKDRAccumulated[tokenId] += totalReward;
        
        emit DailyClaimed(
            msg.sender,
            tokenId,
            currentDay,
            baseShare,
            streakBonus,
            totalReward,
            streak
        );
    }
    
    /**
     * @notice Initialize a day with citizen and pool snapshots
     * @dev Called on first claim of the day - locks values for fairness
     */
    function _initializeDay(uint256 dayIndex) internal {
        uint256 totalCitizens = kcp.totalSupply();
        require(totalCitizens > 0, "No citizens");
        
        uint256 dailyPool = getCurrentDailyPool();
        
        citizensSnapshot[dayIndex] = totalCitizens;
        poolSnapshot[dayIndex] = dailyPool;
        dayInitialized[dayIndex] = true;
        
        emit DayInitialized(dayIndex, totalCitizens, dailyPool);
    }
    
    /**
     * @notice Withdraw accumulated KDR balance
     * @param tokenId The KCP token ID
     * @param amount Amount to withdraw (0 = withdraw all)
     */
    function withdraw(uint256 tokenId, uint256 amount) external whenNotPaused nonReentrant {
        if (kcp.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        
        uint256 balance = accumulatedBalance[tokenId];
        if (balance == 0) revert InsufficientBalance();
        
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        if (withdrawAmount > balance) revert InsufficientBalance();
        
        accumulatedBalance[tokenId] -= withdrawAmount;
        totalKDRWithdrawn[tokenId] += withdrawAmount;
        
        kdr.claimForCitizen(msg.sender, withdrawAmount);
        
        emit Withdrawn(msg.sender, tokenId, withdrawAmount, accumulatedBalance[tokenId]);
    }
    
    /**
     * @notice Sweep unclaimed rewards to treasury (Bayt al-Mal) after day ends
     * @dev Can only sweep yesterday's unclaimed funds, uses snapshotted pool
     * @param dayIndex The day index to sweep (must be yesterday or earlier)
     */
    function sweepUnclaimed(uint256 dayIndex) external onlyOwner nonReentrant {
        uint256 currentDay = getCurrentDayIndex();
        
        // Can only sweep completed days
        if (dayIndex >= currentDay) revert DayNotComplete();
        if (daySwept[dayIndex]) revert AlreadySwept();
        
        // If day was never initialized (no one claimed), initialize it now for accurate sweep
        if (!dayInitialized[dayIndex]) {
            // Use the pool at that historical day
            uint256 historicalPool = _getDailyPoolForDay(dayIndex);
            poolSnapshot[dayIndex] = historicalPool;
            // Note: we don't need citizen snapshot for sweeping, just pool
        }
        
        // Calculate unclaimed amount using snapshotted pool
        uint256 dailyPool = poolSnapshot[dayIndex];
        uint256 distributed = dailyPoolDistributed[dayIndex];
        
        if (distributed >= dailyPool) {
            // Nothing to sweep
            daySwept[dayIndex] = true;
            return;
        }
        
        uint256 unclaimed = dailyPool - distributed;
        
        // Mark as swept
        daySwept[dayIndex] = true;
        
        // Send to treasury (Bayt al-Mal)
        kdr.claimForCitizen(treasury, unclaimed);
        
        emit UnclaimedSwept(dayIndex, unclaimed, treasury);
    }
    
    function _updateStreak(uint256 tokenId, uint256 currentDay) internal {
        if (!hasEverClaimed[tokenId]) {
            // First claim ever
            currentStreak[tokenId] = 1;
        } else {
            uint256 lastClaim = lastClaimDay[tokenId];
            
            if (lastClaim == currentDay - 1) {
                // Consecutive day
                currentStreak[tokenId] += 1;
            } else {
                // Streak broken
                if (currentStreak[tokenId] > 0) {
                    emit StreakReset(tokenId, currentStreak[tokenId]);
                }
                currentStreak[tokenId] = 1;
            }
        }
        
        // Update longest streak if needed
        if (currentStreak[tokenId] > longestStreak[tokenId]) {
            longestStreak[tokenId] = currentStreak[tokenId];
        }
    }
    
    /**
     * @notice Get current daily pool based on halving schedule
     */
    function getCurrentDailyPool() public view returns (uint256) {
        uint256 elapsed = block.timestamp - launchTimestamp;
        
        if (elapsed < PHASE_1_END) {
            return PHASE_1_POOL;
        } else if (elapsed < PHASE_2_END) {
            return PHASE_2_POOL;
        } else if (elapsed < PHASE_3_END) {
            return PHASE_3_POOL;
        } else if (elapsed < PHASE_4_END) {
            return PHASE_4_POOL;
        } else {
            return 0;
        }
    }
    
    /**
     * @notice Get daily pool for a specific day (for sweeping)
     */
    function _getDailyPoolForDay(uint256 dayIndex) internal view returns (uint256) {
        uint256 dayTimestamp = dayIndex * SECONDS_PER_DAY;
        if (dayTimestamp < launchTimestamp) return 0;
        
        uint256 elapsed = dayTimestamp - launchTimestamp;
        
        if (elapsed < PHASE_1_END) {
            return PHASE_1_POOL;
        } else if (elapsed < PHASE_2_END) {
            return PHASE_2_POOL;
        } else if (elapsed < PHASE_3_END) {
            return PHASE_3_POOL;
        } else if (elapsed < PHASE_4_END) {
            return PHASE_4_POOL;
        } else {
            return 0;
        }
    }
    
    function getDaysSinceLaunch() public view returns (uint256) {
        if (block.timestamp < launchTimestamp) return 0;
        return (block.timestamp - launchTimestamp) / SECONDS_PER_DAY;
    }
    
    function getCurrentDayIndex() public view returns (uint256) {
        return block.timestamp / SECONDS_PER_DAY;
    }
    
    function getCurrentPhase() public view returns (uint256 phase, uint256 daysLeft) {
        uint256 elapsed = block.timestamp - launchTimestamp;
        
        if (elapsed < PHASE_1_END) {
            phase = 1;
            daysLeft = (PHASE_1_END - elapsed) / SECONDS_PER_DAY;
        } else if (elapsed < PHASE_2_END) {
            phase = 2;
            daysLeft = (PHASE_2_END - elapsed) / SECONDS_PER_DAY;
        } else if (elapsed < PHASE_3_END) {
            phase = 3;
            daysLeft = (PHASE_3_END - elapsed) / SECONDS_PER_DAY;
        } else if (elapsed < PHASE_4_END) {
            phase = 4;
            daysLeft = (PHASE_4_END - elapsed) / SECONDS_PER_DAY;
        } else {
            phase = 0;
            daysLeft = 0;
        }
    }
    
    /**
     * @notice Get complete info for a citizen
     */
    function getCitizenInfo(uint256 tokenId) external view returns (
        uint256 accumulated,
        uint256 withdrawn,
        uint256 streak,
        uint256 longest,
        uint256 lastClaim,
        uint256 totalClaims,
        bool canClaimToday
    ) {
        accumulated = accumulatedBalance[tokenId];
        withdrawn = totalKDRWithdrawn[tokenId];
        streak = currentStreak[tokenId];
        longest = longestStreak[tokenId];
        lastClaim = lastClaimDay[tokenId];
        totalClaims = totalClaimsMade[tokenId];
        
        uint256 today = getCurrentDayIndex();
        bool alreadyClaimed = hasEverClaimed[tokenId] && lastClaimDay[tokenId] == today;
        canClaimToday = (!alreadyClaimed && !emergencyMode && getCurrentDailyPool() > 0);
    }
    
    /**
     * @notice Get pool statistics
     */
    function getPoolStats() external view returns (
        uint256 currentPool,
        uint256 currentPhase,
        uint256 daysLeftInPhase,
        uint256 daysSinceLaunch,
        uint256 totalCitizens
    ) {
        currentPool = getCurrentDailyPool();
        (currentPhase, daysLeftInPhase) = getCurrentPhase();
        daysSinceLaunch = getDaysSinceLaunch();
        totalCitizens = kcp.totalSupply();
    }
    
    /**
     * @notice Get unclaimed amount for a specific day
     */
    function getUnclaimedForDay(uint256 dayIndex) external view returns (uint256) {
        uint256 dailyPool;
        
        if (dayInitialized[dayIndex]) {
            dailyPool = poolSnapshot[dayIndex];
        } else {
            dailyPool = _getDailyPoolForDay(dayIndex);
        }
        
        uint256 distributed = dailyPoolDistributed[dayIndex];
        
        if (distributed >= dailyPool) return 0;
        return dailyPool - distributed;
    }
    
    function getTokenIdOf(address user) external view returns (uint256) {
        if (kcp.balanceOf(user) == 0) revert NoCitizenship();
        return kcp.tokenOfOwnerByIndex(user, 0);
    }
    
    // Admin functions
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
    
    function setEmergencyMode(bool enabled) external onlyOwner {
        emergencyMode = enabled;
        emit EmergencyModeSet(enabled);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
}