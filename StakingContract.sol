// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/**
 * @title Kingdom Staking Vault
 * @notice Halal-compliant staking with transparent rewards and no owner extraction
 * @dev Rewards must be deposited - owner cannot drain reward pool
 */
contract KingdomStakingVault is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    IERC20Upgradeable public kdrToken;
    address public tokenizationContract;
    
    uint256 public totalStaked;
    uint256 public rewardRate;
    uint256 public constant MAX_REWARD_RATE = 5000;
    uint256 public constant TOKENIZATION_DELAY = 48 hours;
    uint256 public constant UPGRADE_DELAY = 72 hours;
    
    struct Stake {
        uint256 amount;
        uint256 timestamp;
    }
    
    mapping(address => Stake) public stakes;
    
    uint256 public tokenizationUpdateTimelock;
    address public proposedTokenizationContract;
    uint256 public upgradeTimelock;
    address public proposedUpgradeImplementation;
    
    event Staked(address indexed user, uint256 amount, uint256 timestamp);
    event Unstaked(address indexed user, uint256 amount, uint256 remainingStake);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event RewardsDeposited(address indexed depositor, uint256 amount, uint256 newBalance);
    event TokenizationUpdateProposed(address indexed newContract, uint256 executeAfter);
    event TokenizationUpdateExecuted(address indexed newContract);
    event UpgradeProposed(address indexed newImplementation, uint256 executeAfter);
    event UpgradeExecuted(address indexed newImplementation);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address _kdrToken, uint256 _rewardRate) public initializer {
        require(_kdrToken != address(0), "Zero address");
        require(_rewardRate <= MAX_REWARD_RATE, "Rate too high");
        
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        kdrToken = IERC20Upgradeable(_kdrToken);
        rewardRate = _rewardRate;
    }
    
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        
        if (stakes[msg.sender].amount > 0) {
            _claimRewards(msg.sender);
        }
        
        require(kdrToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        stakes[msg.sender].amount += amount;
        stakes[msg.sender].timestamp = block.timestamp;
        totalStaked += amount;
        
        emit Staked(msg.sender, amount, block.timestamp);
    }
    
    function unstake(uint256 amount) external nonReentrant {
        require(stakes[msg.sender].amount >= amount, "Insufficient stake");
        
        _claimRewards(msg.sender);
        
        stakes[msg.sender].amount -= amount;
        totalStaked -= amount;
        
        require(kdrToken.transfer(msg.sender, amount), "Transfer failed");
        
        emit Unstaked(msg.sender, amount, stakes[msg.sender].amount);
    }
    
    function claimRewards() external nonReentrant {
        _claimRewards(msg.sender);
    }
    
    function _claimRewards(address user) internal {
        uint256 pending = pendingRewards(user);
        if (pending == 0) return;
        
        uint256 contractBalance = kdrToken.balanceOf(address(this));
        uint256 availableRewards = contractBalance > totalStaked ? contractBalance - totalStaked : 0;
        
        require(availableRewards >= pending, "Insufficient reward pool");
        
        stakes[user].timestamp = block.timestamp;
        
        require(kdrToken.transfer(user, pending), "Reward transfer failed");
        emit RewardsClaimed(user, pending);
    }
    
    function pendingRewards(address user) public view returns (uint256) {
        Stake memory userStake = stakes[user];
        if (userStake.amount == 0) return 0;
        
        uint256 timeStaked = block.timestamp - userStake.timestamp;
        uint256 reward = (userStake.amount * rewardRate * timeStaked) / (10000 * 365 days);
        
        return reward;
    }
    
    function depositRewards(uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(kdrToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        uint256 newBalance = kdrToken.balanceOf(address(this));
        emit RewardsDeposited(msg.sender, amount, newBalance);
    }
    
    function setRewardRate(uint256 newRate) external onlyOwner {
        require(newRate <= MAX_REWARD_RATE, "Rate too high");
        uint256 oldRate = rewardRate;
        rewardRate = newRate;
        emit RewardRateUpdated(oldRate, newRate);
    }
    
    function proposeTokenizationUpdate(address newContract) external onlyOwner {
        require(newContract != address(0), "Zero address");
        proposedTokenizationContract = newContract;
        tokenizationUpdateTimelock = block.timestamp + TOKENIZATION_DELAY;
        emit TokenizationUpdateProposed(newContract, tokenizationUpdateTimelock);
    }
    
    function executeTokenizationUpdate() external onlyOwner {
        require(proposedTokenizationContract != address(0), "No proposal");
        require(block.timestamp >= tokenizationUpdateTimelock, "Timelock active");
        
        tokenizationContract = proposedTokenizationContract;
        emit TokenizationUpdateExecuted(proposedTokenizationContract);
        
        proposedTokenizationContract = address(0);
        tokenizationUpdateTimelock = 0;
    }
    
    function proposeUpgrade(address newImplementation) external onlyOwner {
        require(newImplementation != address(0), "Zero address");
        proposedUpgradeImplementation = newImplementation;
        upgradeTimelock = block.timestamp + UPGRADE_DELAY;
        emit UpgradeProposed(newImplementation, upgradeTimelock);
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        require(proposedUpgradeImplementation == newImplementation, "Not proposed");
        require(block.timestamp >= upgradeTimelock, "Timelock active");
        emit UpgradeExecuted(newImplementation);
        
        proposedUpgradeImplementation = address(0);
        upgradeTimelock = 0;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
}