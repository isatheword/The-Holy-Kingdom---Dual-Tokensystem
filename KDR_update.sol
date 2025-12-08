// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/proxy/utils/Initializable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/token/ERC20/ERC20Upgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/security/PausableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/access/OwnableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/proxy/utils/UUPSUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/security/ReentrancyGuardUpgradeable.sol";

contract KhalifateDinarV2 is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    // KEEP EXACT SAME STORAGE LAYOUT AS V1
    address public treasuryWallet;
    address public governanceWallet;
    address public developersWallet;
    address public liquidityWallet;
    address public baytAlMalWallet;
    address public citizenMintingEngine;
    uint256 public lockedForCitizens;
    mapping(address => uint256) public lifetimeClaims;
    uint256 public maxSingleClaimBP;
    uint256 public maxLifetimeClaimBP;
    uint256 public constant MAX_ALLOWED_SINGLE_BP = 500;
    uint256 public constant MAX_ALLOWED_LIFETIME_BP = 2000;
    uint256 public launchTimestamp;
    uint256 public distributedToday;
    uint256 public dayStart;
    uint256 public manualDailyLimit;
    uint256 public upgradeTimelock;
    uint256 public constant UPGRADE_DELAY = 7 days;
    bool public unclaimedFrozen;

    // ADD MISSING FUNCTION FOR MINTING ENGINE
    function getDailyLimit() public view returns (uint256) {
        if (launchTimestamp == 0 || block.timestamp < launchTimestamp) return 0;
        
        uint256 elapsedYears = (block.timestamp - launchTimestamp) / 365 days;
        
        if (elapsedYears < 2) return 50000 * 10 ** decimals();
        if (elapsedYears < 4) return 25000 * 10 ** decimals();
        if (elapsedYears < 6) return 12500 * 10 ** decimals();
        return 6250 * 10 ** decimals();
    }

    // EXPLICIT DECIMALS (for Minting Engine)
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // KEEP ALL EXISTING FUNCTIONS FROM V1 (FIXED WARNINGS)
    function initializeV2() public reinitializer(2) {
        // No storage changes needed - just adding functions
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // FIXED: Remove unused parameter names to silence warnings
    function claimForCitizen(address to, uint256 amount) external nonReentrant {
        require(msg.sender == citizenMintingEngine, "Not engine");
        require(!unclaimedFrozen, "Claims frozen");
        require(to != address(0), "Zero address");
        require(amount > 0, "Zero amount");
        
        // Reset daily counters if a new 24h window started
        if (block.timestamp >= dayStart + 24 hours) {
            distributedToday = 0;
            dayStart = block.timestamp;
        }

        uint256 ts = totalSupply();

        // Single-claim cap
        uint256 maxSingle = (ts * maxSingleClaimBP) / 10000;
        require(amount <= maxSingle, "Single cap exceeded");

        // Lifetime cap
        uint256 maxLifetime = (ts * maxLifetimeClaimBP) / 10000;
        require(lifetimeClaims[to] + amount <= maxLifetime, "Lifetime cap");

        // Check vault
        require(lockedForCitizens >= amount, "Vault low");

        // Daily limit (manual override or schedule-based)
        uint256 limit = manualDailyLimit > 0 ? manualDailyLimit : getDailyLimit();
        require(distributedToday + amount <= limit, "Daily limit reached");

        distributedToday += amount;
        lockedForCitizens -= amount;
        lifetimeClaims[to] += amount;

        _transfer(address(this), to, amount);
    }

    function setCitizenMintingEngine(address engine) external onlyOwner {
        require(engine != address(0), "Zero address");
        citizenMintingEngine = engine;
    }

    function setUnclaimedFrozen(bool frozen) external onlyOwner {
        unclaimedFrozen = frozen;
    }

    function setClaimCaps(uint256 singleBP, uint256 lifetimeBP) external onlyOwner {
        require(singleBP <= MAX_ALLOWED_SINGLE_BP, "single cap too high");
        require(lifetimeBP <= MAX_ALLOWED_LIFETIME_BP, "lifetime cap too high");
        require(singleBP <= lifetimeBP, "single > lifetime");
        maxSingleClaimBP = singleBP;
        maxLifetimeClaimBP = lifetimeBP;
    }

    function setManualDailyLimit(uint256 limit) external onlyOwner {
        manualDailyLimit = limit;
    }

    function sweepUnclaimed() external onlyOwner {
        uint256 bal = balanceOf(address(this));
        require(bal > 0, "Nothing to sweep");
        lockedForCitizens = 0;
        _transfer(address(this), baytAlMalWallet, bal);
    }
}