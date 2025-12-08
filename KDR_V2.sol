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
    // Wallets
    address public treasuryWallet;
    address public governanceWallet;
    address public developersWallet;
    address public liquidityWallet;
    address public baytAlMalWallet;

    // Minting engine
    address public citizenMintingEngine;

    // Citizen vault
    uint256 public lockedForCitizens;
    mapping(address => uint256) public lifetimeClaims;

    // Claim caps (basis points)
    uint256 public maxSingleClaimBP;
    uint256 public maxLifetimeClaimBP;
    uint256 public constant MAX_ALLOWED_SINGLE_BP = 500;   // 5%
    uint256 public constant MAX_ALLOWED_LIFETIME_BP = 2000; // 20%

    // Minting schedule
    uint256 public launchTimestamp;
    uint256 public distributedToday;
    uint256 public dayStart;
    uint256 public manualDailyLimit;

    // Upgrade timelock
    uint256 public upgradeTimelock;
    uint256 public constant UPGRADE_DELAY = 7 days;

    // Controls
    bool public unclaimedFrozen;

    // Events
    event CitizenMintingEngineSet(address indexed engine);
    event CitizenTokensClaimed(address indexed to, uint256 amount);
    event DailyPoolUsed(uint256 amount);
    event UnclaimedSwept(address indexed to, uint256 amount);

    function initializeV2(
        uint256 _launchTimestamp
    ) external reinitializer(2) {
        require(_launchTimestamp > 0, "Invalid launch timestamp");

        launchTimestamp = _launchTimestamp;
        dayStart = block.timestamp;
        manualDailyLimit = 0;

        // Note: with denominator 10000, 5 = 0.05%, 100 = 1%
        maxSingleClaimBP = 5;
        maxLifetimeClaimBP = 100;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {
        require(upgradeTimelock != 0, "Upgrade not scheduled");
        require(block.timestamp >= upgradeTimelock, "Timelock active");
        require(newImplementation != address(0), "Zero implementation");

        upgradeTimelock = 0;
    }

    function scheduleUpgrade() external onlyOwner {
        upgradeTimelock = block.timestamp + UPGRADE_DELAY;
    }

    function setCitizenMintingEngine(address engine) external onlyOwner {
        require(engine != address(0), "Zero address");
        citizenMintingEngine = engine;
        emit CitizenMintingEngineSet(engine);
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

    function claimForCitizen(address to, uint256 amount)
        external
        nonReentrant
    {
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
        emit CitizenTokensClaimed(to, amount);
    }

    function getDailyLimit() public view returns (uint256) {
        if (launchTimestamp == 0 || block.timestamp < launchTimestamp) return 0;

        // Renamed from `years` -> `elapsedYears` to avoid reserved keyword conflict
        uint256 elapsedYears = (block.timestamp - launchTimestamp) / 365 days;

        if (elapsedYears < 2) return 50000 * 1e18;
        if (elapsedYears < 4) return 25000 * 1e18;
        if (elapsedYears < 6) return 12500 * 1e18;
        return 6250 * 1e18;
    }

    function sweepUnclaimed() external onlyOwner {
        uint256 bal = balanceOf(address(this));
        require(bal > 0, "Nothing to sweep");
        lockedForCitizens = 0;
        _transfer(address(this), baytAlMalWallet, bal);
        emit UnclaimedSwept(baytAlMalWallet, bal);
    }
}
