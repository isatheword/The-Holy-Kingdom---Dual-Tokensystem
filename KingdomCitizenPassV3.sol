// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract KingdomCitizenPass is 
    Initializable, 
    ERC721EnumerableUpgradeable, 
    OwnableUpgradeable, 
    UUPSUpgradeable 
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    uint256 private _tokenIdCounter;
    address public signer;
    string public defaultTokenURI;
    
    mapping(address => bool) public hasMinted;
    mapping(uint256 => bool) public usedNonces;

    event CitizenMinted(address indexed to, uint256 tokenId);
    event CitizenRevoked(address indexed from, uint256 tokenId);
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);

    error AlreadyMinted();
    error InvalidSignature();
    error SignatureExpired();
    error NonceAlreadyUsed();
    error SoulboundToken();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address initialOwner,
        address initialSigner,
        string memory _defaultTokenURI
    ) public initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialSigner == address(0)) revert ZeroAddress();
        
        __ERC721_init("Kingdom Citizen Pass", "KCP");
        __ERC721Enumerable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        
        signer = initialSigner;
        defaultTokenURI = _defaultTokenURI;
        _tokenIdCounter = 1;
    }

    function claimCitizenship(
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external {
        if (hasMinted[msg.sender]) revert AlreadyMinted();
        if (block.timestamp > expiry) revert SignatureExpired();
        if (usedNonces[nonce]) revert NonceAlreadyUsed();
        
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this),
            block.chainid,
            msg.sender,
            nonce,
            expiry
        ));
        
        // CRITICAL: Uses EIP-191 prefix to match backend signMessage()
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address recoveredSigner = ethSignedHash.recover(signature);
        
        if (recoveredSigner != signer) revert InvalidSignature();
        
        usedNonces[nonce] = true;
        hasMinted[msg.sender] = true;
        
        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;
        _safeMint(msg.sender, tokenId);
        
        emit CitizenMinted(msg.sender, tokenId);
    }

    function adminMint(address to) external onlyOwner {
        if (hasMinted[to]) revert AlreadyMinted();
        hasMinted[to] = true;
        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;
        _safeMint(to, tokenId);
        emit CitizenMinted(to, tokenId);
    }

    function batchAdminMint(address[] calldata recipients) external onlyOwner {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!hasMinted[recipients[i]]) {
                hasMinted[recipients[i]] = true;
                uint256 tokenId = _tokenIdCounter;
                _tokenIdCounter++;
                _safeMint(recipients[i], tokenId);
                emit CitizenMinted(recipients[i], tokenId);
            }
        }
    }

    function _update(address to, uint256 tokenId, address auth) 
        internal virtual override returns (address) 
    {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert SoulboundToken();
        return super._update(to, tokenId, auth);
    }

    function totalSupply() public view override returns (uint256) {
        return super.totalSupply();
    }

    function totalCitizens() external view returns (uint256) {
        return totalSupply();
    }

    function getCitizenInfo(address user) external view returns (
        uint256 tokenId, string memory uri
    ) {
        if (balanceOf(user) == 0) return (0, "");
        tokenId = tokenOfOwnerByIndex(user, 0);
        uri = tokenURI(tokenId);
    }

    function isCitizen(address account) public view returns (bool) {
        return balanceOf(account) > 0;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return defaultTokenURI;
    }

    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit SignerUpdated(signer, newSigner);
        signer = newSigner;
    }

    function setDefaultTokenURI(string memory uri) external onlyOwner {
        defaultTokenURI = uri;
    }

    function revokeCitizenship(uint256 tokenId) external onlyOwner {
        address owner = ownerOf(tokenId);
        hasMinted[owner] = false;
        _burn(tokenId);
        emit CitizenRevoked(owner, tokenId);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function supportsInterface(bytes4 interfaceId) 
        public view override returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }
}