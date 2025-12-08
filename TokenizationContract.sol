// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/**
 * @title Kingdom Asset Tokenization
 * @notice Sharia-compliant fractional asset ownership with transparent fee separation
 */
contract KingdomAssetTokenization is
    Initializable,
    ERC721Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    IERC20Upgradeable public kdrToken;
    
    uint256 private _tokenIdCounter;
    uint256 public platformFeeBP;
    uint256 public constant MAX_FEE_BP = 500;
    uint256 public constant UPGRADE_DELAY = 72 hours;
    
    uint256 public accumulatedFees;
    address public shariaAuditor;
    uint256 public upgradeTimelock;
    address public proposedUpgradeImplementation;
    
    struct Asset {
        string name;
        string assetType;
        uint256 totalValue;
        uint256 tokenSupply;
        uint256 pricePerToken;
        uint256 tokensSold;
        string shariaCertificateId;
        address creator;
        bool active;
        bool shariaCompliant;
    }
    
    mapping(uint256 => Asset) public assets;
    mapping(uint256 => mapping(address => uint256)) public holdings;
    
    event AssetTokenized(uint256 indexed tokenId, string name, uint256 totalValue, address indexed creator, string shariaCertificateId);
    event TokensPurchased(uint256 indexed tokenId, address indexed buyer, uint256 amount, uint256 cost, uint256 fee);
    event HoldingsUpdated(uint256 indexed tokenId, address indexed holder, uint256 newBalance);
    event FeesWithdrawn(address indexed owner, uint256 amount);
    event ShariaAuditorUpdated(address indexed oldAuditor, address indexed newAuditor);
    event AssetComplianceUpdated(uint256 indexed tokenId, bool compliant);
    event UpgradeProposed(address indexed newImplementation, uint256 executeAfter);
    event UpgradeExecuted(address indexed newImplementation);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address _kdrToken, uint256 _platformFeeBP) public initializer {
        require(_kdrToken != address(0), "Zero address");
        require(_platformFeeBP <= MAX_FEE_BP, "Fee too high");
        
        __ERC721_init("Kingdom Asset Token", "KAT");
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        kdrToken = IERC20Upgradeable(_kdrToken);
        platformFeeBP = _platformFeeBP;
    }
    
    function tokenizeAsset(
        string memory name,
        string memory assetType,
        uint256 totalValue,
        uint256 tokenSupply,
        string memory shariaCertId
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(bytes(name).length > 0, "Empty name");
        require(totalValue > 0 && tokenSupply > 0, "Invalid values");
        require(bytes(shariaCertId).length > 0, "No cert ID");
        
        uint256 tokenId = _tokenIdCounter++;
        _safeMint(msg.sender, tokenId);
        
        assets[tokenId] = Asset({
            name: name,
            assetType: assetType,
            totalValue: totalValue,
            tokenSupply: tokenSupply,
            pricePerToken: totalValue / tokenSupply,
            tokensSold: 0,
            shariaCertificateId: shariaCertId,
            creator: msg.sender,
            active: true,
            shariaCompliant: true
        });
        
        emit AssetTokenized(tokenId, name, totalValue, msg.sender, shariaCertId);
        return tokenId;
    }
    
    function purchaseTokens(uint256 tokenId, uint256 amount, uint256 maxPricePerToken) external nonReentrant whenNotPaused {
        Asset storage asset = assets[tokenId];
        require(asset.active, "Asset inactive");
        require(asset.shariaCompliant, "Not sharia compliant");
        require(asset.tokensSold + amount <= asset.tokenSupply, "Insufficient supply");
        require(asset.pricePerToken <= maxPricePerToken, "Price too high");
        
        uint256 cost = amount * asset.pricePerToken;
        uint256 fee = (cost * platformFeeBP) / 10000;
        uint256 creatorPayment = cost - fee;
        
        require(kdrToken.transferFrom(msg.sender, address(this), cost), "Payment failed");
        
        accumulatedFees += fee;
        require(kdrToken.transfer(asset.creator, creatorPayment), "Creator payment failed");
        
        holdings[tokenId][msg.sender] += amount;
        asset.tokensSold += amount;
        
        emit TokensPurchased(tokenId, msg.sender, amount, cost, fee);
        emit HoldingsUpdated(tokenId, msg.sender, holdings[tokenId][msg.sender]);
    }
    
    function withdrawFees() external onlyOwner nonReentrant {
        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees");
        
        accumulatedFees = 0;
        require(kdrToken.transfer(owner(), amount), "Transfer failed");
        
        emit FeesWithdrawn(owner(), amount);
    }
    
    function setAssetActive(uint256 tokenId, bool active) external {
        require(assets[tokenId].creator == msg.sender || msg.sender == owner() || msg.sender == shariaAuditor, "Not authorized");
        assets[tokenId].active = active;
    }
    
    function setShariaCompliance(uint256 tokenId, bool compliant) external {
        require(msg.sender == shariaAuditor || msg.sender == owner(), "Not authorized");
        assets[tokenId].shariaCompliant = compliant;
        emit AssetComplianceUpdated(tokenId, compliant);
    }
    
    function setShariaAuditor(address auditor) external onlyOwner {
        address oldAuditor = shariaAuditor;
        shariaAuditor = auditor;
        emit ShariaAuditorUpdated(oldAuditor, auditor);
    }
    
    function setPlatformFee(uint256 newFeeBP) external onlyOwner {
        require(newFeeBP <= MAX_FEE_BP, "Fee too high");
        platformFeeBP = newFeeBP;
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
    
    function getAsset(uint256 tokenId) external view returns (Asset memory) {
        return assets[tokenId];
    }
    
    function getHolding(uint256 tokenId, address holder) external view returns (uint256) {
        return holdings[tokenId][holder];
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
}