// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract DopamineVault is Pausable {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    // Define custom errors
    error InsufficientAmount();
    error InsufficientBalance();
    error AllowanceNotSet();
    error NoStakedETHFound();
    error NoStakedTokensFound();
    error Unauthorized();
    error InsufficientStake();
    error InvalidSignature();

    struct Stake {
        address user;
        uint256 amount;
        uint256 blockNumber;
        address token;
        uint256 synthesizerId;
    }

    // Global nonce counter
    Counters.Counter private stakeNonce;
    // Nonce => Stake
    mapping(uint256 => Stake) public stakes;

    address public registryPublicKey; // Public key of the ICP canister for verification
    address public daoPublicKey; // Public key of the DAO for BLS verification

    constructor(address _registryPublicKey, address _daoPublicKey) {
        registryPublicKey = _registryPublicKey;
        daoPublicKey = _daoPublicKey;
    }

    function stakeETH(uint256 synthesizerId) external payable whenNotPaused {
        if (msg.value == 0) revert InsufficientAmount();
        uint256 nonce = stakeNonce.current();
        stakeNonce.increment();
        stakes[nonce] = Stake({
            user: msg.sender,
            amount: msg.value,
            blockNumber: block.number,
            token: address(0),
            synthesizerId: synthesizerId
        });

        emit Staked(msg.sender, address(0), msg.value, synthesizerId, nonce);
    }

    function stakeERC20(address token, uint256 amount, uint256 synthesizerId) external whenNotPaused {
        if (amount == 0) revert InsufficientAmount();
        if (IERC20(token).balanceOf(msg.sender) < amount) revert InsufficientBalance();
        if (IERC20(token).allowance(msg.sender, address(this)) < amount) revert AllowanceNotSet();

        uint256 nonce = stakeNonce.current();
        stakeNonce.increment();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        stakes[nonce] = Stake({
            user: msg.sender,
            amount: amount,
            blockNumber: block.number,
            token: token,
            synthesizerId: synthesizerId
        });

        emit Staked(msg.sender, token, amount, synthesizerId, nonce);
    }

    function unstakeETH(uint256 nonce, uint256 slashAmount, bytes32 r, bytes32 s, uint8 v) external whenNotPaused {
        Stake memory stakeInfo = stakes[nonce];
        if (stakeInfo.user != msg.sender || stakeInfo.token != address(0)) revert NoStakedETHFound();

        verifySignature(msg.sender, address(0), stakeInfo.amount, nonce, slashAmount, r, s, v);

        uint256 amountToUnstake = stakeInfo.amount;
        if (amountToUnstake < slashAmount) revert InsufficientStake();
        uint256 amountAfterSlash = amountToUnstake - slashAmount;
        uint256 synthesizerId = stakeInfo.synthesizerId;
        delete stakes[nonce];

        if (slashAmount > 0) {
            // Burn the slashed amount (can send to a burn address or treasury)
            (bool burnSuccess, ) = address(0).call{value: slashAmount}("");
            require(burnSuccess, "Burn failed");
        }

        (bool success, ) = msg.sender.call{value: amountAfterSlash}("");
        require(success, "Transfer failed");

        emit Unstaked(msg.sender, address(0), amountAfterSlash, synthesizerId);
    }

    function unstakeERC20(uint256 nonce, uint256 slashAmount, bytes32 r, bytes32 s, uint8 v) external whenNotPaused {
        Stake memory stakeInfo = stakes[nonce];
        if (stakeInfo.user != msg.sender || stakeInfo.token != token) revert NoStakedTokensFound();

        verifySignature(msg.sender, stakeInfo.token, stakeInfo.amount, nonce, slashAmount, r, s, v);

        uint256 amountToUnstake = stakeInfo.amount;
        if (amountToUnstake < slashAmount) revert InsufficientStake();
        uint256 amountAfterSlash = amountToUnstake - slashAmount;
        uint256 synthesizerId = stakeInfo.synthesizerId;
        delete stakes[nonce];

        if (slashAmount > 0) {
            // Burn the slashed amount (can send to a burn address or treasury)
            IERC20(stakeInfo.token).safeTransfer(address(0), slashAmount);
        }

        IERC20(stakeInfo.token).safeTransfer(msg.sender, amountAfterSlash);

        emit Unstaked(msg.sender, stakeInfo.token, amountAfterSlash, synthesizerId);
    }

    function verifySignature(
        address user,
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 slashAmount,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) internal view {
        bytes32 messageHash = keccak256(abi.encodePacked(user, token, amount, nonce, slashAmount));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        if (ecrecover(ethSignedMessageHash, v, r, s) != registryPublicKey) {
            revert Unauthorized();
        }
    }

    // BLS Signature verification placeholder
    function verifyBLS(bytes32 messageHash, bytes memory blsSignature) internal view returns (bool) {
        // Implement BLS signature verification here
        // This is a placeholder function
        // Return true if the signature is valid, false otherwise
        return true;
    }

    // Governance functions

    function pause(bytes32 messageHash, bytes memory blsSignature) external {
        if (!verifyBLS(messageHash, blsSignature)) revert InvalidSignature();
        _pause();
    }

    function unpause(bytes32 messageHash, bytes memory blsSignature) external {
        if (!verifyBLS(messageHash, blsSignature)) revert InvalidSignature();
        _unpause();
    }

    function setRegistryPublicKey(address newRegistryPublicKey, bytes32 messageHash, bytes memory blsSignature) external {
        if (!verifyBLS(messageHash, blsSignature)) revert InvalidSignature();
        registryPublicKey = newRegistryPublicKey;
    }

    function recoveryUnstakeETH(uint256 nonce, bytes32 messageHash, bytes memory blsSignature) external {
        if (!verifyBLS(messageHash, blsSignature)) revert InvalidSignature();
        Stake memory stakeInfo = stakes[nonce];
        if (stakeInfo.token != address(0)) revert NoStakedETHFound();

        uint256 amount = stakeInfo.amount;
        uint256 synthesizerId = stakeInfo.synthesizerId;
        address user = stakeInfo.user;
        delete stakes[nonce];

        (bool success, ) = user.call{value: amount}("");
        require(success, "Transfer failed");

        emit Recovered(user, address(0), amount, synthesizerId);
    }

    function recoveryUnstakeERC20(uint256 nonce, bytes32 messageHash, bytes memory blsSignature) external {
        if (!verifyBLS(messageHash, blsSignature)) revert InvalidSignature();
        Stake memory stakeInfo = stakes[nonce];
        address token = stakeInfo.token;
        if (token == address(0)) revert NoStakedTokensFound();

        uint256 amount = stakeInfo.amount;
        uint256 synthesizerId = stakeInfo.synthesizerId;
        address user = stakeInfo.user;
        delete stakes[nonce];

        IERC20(token).safeTransfer(user, amount);

        emit Recovered(user, token, amount, synthesizerId);
    }

    // Prevent receiving ETH directly without calling stakeETH
    receive() external payable {
        revert("Use stakeETH to stake ETH");
    }

    event Staked(address indexed user, address indexed token, uint256 amount, uint256 synthesizerId, uint256 nonce);
    event Unstaked(address indexed user, address indexed token, uint256 amount, uint256 synthesizerId);
    event Recovered(address indexed user, address indexed token, uint256 amount, uint256 synthesizerId);
}
