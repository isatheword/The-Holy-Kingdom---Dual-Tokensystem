// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title KDRTrustlessVestingVault
 * @notice Trustless, non-revocable vesting vault for KDR. 
 *         Once a vesting is created, it cannot be removed or altered.
 *         Owner cannot withdraw tokens or revoke vestings.
 *         This contract cannot mint, drain, or access any supply from KDR.
 */
contract KDRTrustlessVestingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable kdr;

    struct Vesting {
        uint256 amount;       // total vested amount
        uint256 claimed;      // already claimed
        uint64  releaseTime;  // timestamp when beneficiary can claim full amount
        bool    exists;       // true if vesting exists
    }

    // One vesting per wallet (pure, simple trust model)
    mapping(address => Vesting) public vestings;

    // Optional: helpful global accounting
    uint256 public totalAllocated;
    uint256 public totalClaimed;

    event VestingCreated(address indexed beneficiary, uint256 amount, uint64 releaseTime);
    event VestingClaimed(address indexed beneficiary, uint256 amount);

    constructor(address kdrTokenAddress, address initialOwner) Ownable(initialOwner) {
        require(kdrTokenAddress != address(0), "Zero KDR address");
        require(initialOwner != address(0), "Zero owner");
        kdr = IERC20(kdrTokenAddress);
    }

    /**
     * @notice Fund the vault with KDR tokens.
     * @dev Requires prior approval from sender:
     *      KDR.approve(vault, amount);
     */
    function fundVault(uint256 amount) external {
        require(amount > 0, "Zero amount");
        kdr.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Creates a new one-time vesting for a beneficiary.
     * @dev NON-REVOCABLE — cannot be undone. Be certain before calling.
     */
    function createVesting(
        address beneficiary,
        uint256 amount,
        uint64 releaseTime
    ) public onlyOwner {
        require(beneficiary != address(0), "Zero beneficiary");
        require(!vestings[beneficiary].exists, "Vesting exists");
        require(amount > 0, "Zero amount");
        require(releaseTime > block.timestamp, "Release in past");

        vestings[beneficiary] = Vesting({
            amount: amount,
            claimed: 0,
            releaseTime: releaseTime,
            exists: true
        });

        totalAllocated += amount;

        emit VestingCreated(beneficiary, amount, releaseTime);
    }

    /**
     * @notice Batch creates multiple vestings.
     */
    function batchCreateVestings(
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        uint64[] calldata releaseTimes
    ) external onlyOwner {
        uint256 len = beneficiaries.length;
        require(len == amounts.length && len == releaseTimes.length, "Length mismatch");

        for (uint256 i = 0; i < len; i++) {
            createVesting(beneficiaries[i], amounts[i], releaseTimes[i]);
        }
    }

    /**
     * @notice Claim all unlocked tokens for the caller.
     * @dev Full cliff: once releaseTime is reached, 100% becomes claimable.
     */
    function claim() external nonReentrant {
        Vesting storage v = vestings[msg.sender];
        require(v.exists, "No vesting");
        require(block.timestamp >= v.releaseTime, "Still locked");

        uint256 claimable = v.amount - v.claimed;
        require(claimable > 0, "Nothing to claim");

        v.claimed = v.amount;
        totalClaimed += claimable;

        kdr.safeTransfer(msg.sender, claimable);

        emit VestingClaimed(msg.sender, claimable);
    }

    /**
     * @notice View the current claimable amount for a beneficiary.
     */
    function claimableAmount(address beneficiary) external view returns (uint256) {
        Vesting memory v = vestings[beneficiary];
        if (!v.exists || block.timestamp < v.releaseTime) return 0;
        return v.amount - v.claimed;
    }

    /**
     * @notice Returns total remaining obligations.
     */
    function totalUnclaimed() external view returns (uint256) {
        return totalAllocated - totalClaimed;
    }

    /**
     * @notice Quick helper to check if the vault has enough tokens for all vestings.
     */
    function isFullyFunded() external view returns (bool) {
        uint256 obligations = totalAllocated - totalClaimed;
        uint256 bal = kdr.balanceOf(address(this));
        return bal >= obligations;
    }
}
