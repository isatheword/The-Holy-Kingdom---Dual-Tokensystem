// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IKDR {
    function claimForCitizen(address to, uint256 amount) external;
    function getDailyLimit() external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IKCP {
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
}

contract CitizenRewardEngine is Ownable, Pausable, ReentrancyGuard {
    
    IKDR public immutable kdr;
    IKCP public immutable kcp;
    
    uint256 public claimStartDay;
    uint256 public minimumBaseShare;
    bool public emergencyMode;
    
    mapping(uint256 => uint256) public lastClaimDay;
    mapping(uint256 => uint256) public currentStreak;
    mapping(uint256 => uint256) public longestStreak;
    
    mapping(uint256 => bool) public milestone7Claimed;
    mapping(uint256 => bool) public milestone30Claimed;
    mapping(uint256 => bool) public milestone90Claimed;
    mapping(uint256 => bool) public milestone365Claimed;
    
    mapping(uint256 => uint256) public totalClaimsMade;
    mapping(uint256 => uint256) public totalKDRMinted;
    
    event Claimed(address indexed claimer, uint256 indexed tokenId, uint256 dayIndex, uint256 totalReward, uint256 newStreak);
    event Milestone(uint256 indexed tokenId, uint256 milestone, uint256 bonus);
    event StreakReset(uint256 indexed tokenId, uint256 oldStreak);
    event EmergencyModeSet(bool enabled);
    
    error EmergencyModeActive();
    error NotTokenOwner();
    error ClaimingNotStarted();
    error AlreadyClaimedToday();
    error PoolNotReady();
    error NoCitizenship();
    
    constructor(
        address kdrAddress,
        address kcpAddress,
        address initialOwner,
        uint256 claimStartTimestamp
    ) Ownable(initialOwner) {
        require(kdrAddress != address(0), "Zero KDR");
        require(kcpAddress != address(0), "Zero KCP");
        
        kdr = IKDR(kdrAddress);
        kcp = IKCP(kcpAddress);
        
        claimStartDay = claimStartTimestamp == 0 
            ? block.timestamp / 1 days 
            : claimStartTimestamp / 1 days;
        
        minimumBaseShare = 1 * 10 ** kdr.decimals();
    }
    
    function claim(uint256 tokenId) external whenNotPaused nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
        if (kcp.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        
        uint256 today = currentDayIndex();
        if (today < claimStartDay) revert ClaimingNotStarted();
        if (lastClaimDay[tokenId] >= today) revert AlreadyClaimedToday();
        
        (uint256 dailyPool, uint256 totalCitizens, uint256 baseShare) = getCurrentPoolInfo();
        if (dailyPool == 0 || totalCitizens == 0 || baseShare < minimumBaseShare) {
            revert PoolNotReady();
        }
        
        _updateStreak(tokenId, today);
        
        uint256 streak = currentStreak[tokenId];
        uint256 streakPercent = streak > 100 ? 100 : streak;
        uint256 streakBonus = (baseShare * streakPercent) / 100;
        uint256 milestoneBonus = _checkMilestones(tokenId);
        uint256 totalReward = baseShare + streakBonus + milestoneBonus;
        
        lastClaimDay[tokenId] = today;
        totalClaimsMade[tokenId] += 1;
        totalKDRMinted[tokenId] += totalReward;
        
        kdr.claimForCitizen(msg.sender, totalReward);
        
        emit Claimed(msg.sender, tokenId, today, totalReward, streak);
    }
    
    function _updateStreak(uint256 tokenId, uint256 today) internal {
        uint256 lastClaim = lastClaimDay[tokenId];
        
        if (lastClaim == 0) {
            currentStreak[tokenId] = 1;
        } else if (lastClaim == today - 1) {
            currentStreak[tokenId] += 1;
        } else {
            if (currentStreak[tokenId] > 0) {
                emit StreakReset(tokenId, currentStreak[tokenId]);
            }
            currentStreak[tokenId] = 1;
        }
        
        if (currentStreak[tokenId] > longestStreak[tokenId]) {
            longestStreak[tokenId] = currentStreak[tokenId];
        }
    }
    
    function _checkMilestones(uint256 tokenId) internal returns (uint256 bonus) {
        uint256 streak = currentStreak[tokenId];
        uint256 unit = 10 ** kdr.decimals();
        bonus = 0;
        
        if (streak >= 7 && !milestone7Claimed[tokenId]) {
            milestone7Claimed[tokenId] = true;
            bonus += 5 * unit;
            emit Milestone(tokenId, 7, 5 * unit);
        }
        
        if (streak >= 30 && !milestone30Claimed[tokenId]) {
            milestone30Claimed[tokenId] = true;
            bonus += 15 * unit;
            emit Milestone(tokenId, 30, 15 * unit);
        }
        
        if (streak >= 90 && !milestone90Claimed[tokenId]) {
            milestone90Claimed[tokenId] = true;
            bonus += 50 * unit;
            emit Milestone(tokenId, 90, 50 * unit);
        }
        
        if (streak >= 365 && !milestone365Claimed[tokenId]) {
            milestone365Claimed[tokenId] = true;
            bonus += 150 * unit;
            emit Milestone(tokenId, 365, 150 * unit);
        }
    }
    
    function currentDayIndex() public view returns (uint256) {
        return block.timestamp / 1 days;
    }
    
    function getCurrentPoolInfo() public view returns (
        uint256 dailyPool,
        uint256 totalCitizens,
        uint256 baseShare
    ) {
        dailyPool = kdr.getDailyLimit();
        totalCitizens = kcp.totalSupply();
        
        if (totalCitizens > 0 && dailyPool > 0) {
            baseShare = dailyPool / totalCitizens;
            if (baseShare < minimumBaseShare) {
                baseShare = minimumBaseShare;
            }
        }
    }
    
    function getStreakInfo(uint256 tokenId) external view returns (
        uint256 streak,
        uint256 longest,
        uint256 bonusPercent,
        uint256 lastClaim,
        bool canClaim
    ) {
        streak = currentStreak[tokenId];
        longest = longestStreak[tokenId];
        bonusPercent = streak > 100 ? 100 : streak;
        lastClaim = lastClaimDay[tokenId];
        
        uint256 today = currentDayIndex();
        canClaim = (today >= claimStartDay && lastClaim < today && !emergencyMode);
    }
    
    function getTokenIdOf(address user) external view returns (uint256) {
        if (kcp.balanceOf(user) == 0) revert NoCitizenship();
        return kcp.tokenOfOwnerByIndex(user, 0);
    }
    
    function setClaimStartDay(uint256 timestamp) external onlyOwner {
        claimStartDay = timestamp / 1 days;
    }
    
    function setMinimumBaseShare(uint256 newMinimum) external onlyOwner {
        require(newMinimum > 0, "Min must > 0");
        minimumBaseShare = newMinimum;
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