// SPDX-License-Identifier: MIT
// TODO: Add permit support
pragma solidity ^0.8.25;

// TODO: Use an interface later, permit and standard erc20 are separated in openzeppelin
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./bls/BLSOwnableUpgradeable.sol";

contract VaultV1 is Initializable, PausableUpgradeable, BLSOwnableUpgradeable {
    using SafeERC20 for ERC20Permit;

    error InsufficientAmount();
    error InsufficientBalance();
    error AllowanceNotSet();
    error NoStakedETHFound();
    error NoStakedTokensFound();
    error Unauthorized();
    error InsufficientStake();

    struct Stake {
        address user;
        uint256 amount;
        uint256 blockNumber;
        address token;
        uint256 synthesizerId;
        bool unstaked;
    }

    uint256 public stakeNonce;
    mapping(uint256 => Stake) public stakes;

    address public registryPublicKey; // Public key of the ICP canister for verification

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(
        address _registryPublicKey,
        uint256[4] memory _governancePublicKey
    ) public initializer {
        __Pausable_init();
        __BLSOwnable_init("Vault", "v1", _governancePublicKey);
        registryPublicKey = _registryPublicKey;
    }

    function stakeETH(uint256 synthesizerId) external payable whenNotPaused {
        if (msg.value == 0) revert InsufficientAmount();
        uint256 nonce = stakeNonce;
        stakes[nonce] = Stake({
            user: msg.sender,
            amount: msg.value,
            blockNumber: block.number,
            token: address(0),
            synthesizerId: synthesizerId,
            unstaked: false
        });
        stakeNonce++;

        emit Staked(msg.sender, address(0), msg.value, synthesizerId, nonce);
    }

    function stakeERC20(
        address token,
        uint256 amount,
        uint256 synthesizerId
    ) external whenNotPaused {
        if (amount == 0) revert InsufficientAmount();
        if (ERC20Permit(token).balanceOf(msg.sender) < amount) revert InsufficientBalance();
        if (ERC20Permit(token).allowance(msg.sender, address(this)) < amount) revert AllowanceNotSet();

        uint256 nonce = stakeNonce;
        ERC20Permit(token).safeTransferFrom(msg.sender, address(this), amount);
        stakes[nonce] = Stake({
            user: msg.sender,
            amount: amount,
            blockNumber: block.number,
            token: token,
            synthesizerId: synthesizerId,
            unstaked: false
        });
        stakeNonce++;

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
        stakes[nonce].unstaked = true;

        if (slashAmount > 0) {
            // Burn the slashed amount (can send to a burn address or treasury)
            (bool burnSuccess, ) = address(0).call{value: slashAmount}("");
            require(burnSuccess, "Burn failed");
        }

        (bool success, ) = msg.sender.call{value: amountAfterSlash}("");
        require(success, "Transfer failed");

        emit Unstaked(msg.sender, address(0), amountAfterSlash, synthesizerId, nonce);
    }

    function unstakeERC20(uint256 nonce, uint256 slashAmount, bytes32 r, bytes32 s, uint8 v) external whenNotPaused {
        Stake memory stakeInfo = stakes[nonce];
        if (nonce >= stakeNonce) revert NoStakedTokensFound();

        verifySignature(msg.sender, stakeInfo.token, stakeInfo.amount, nonce, slashAmount, r, s, v);

        uint256 amountToUnstake = stakeInfo.amount;
        if (amountToUnstake < slashAmount) revert InsufficientStake();
        uint256 amountAfterSlash = amountToUnstake - slashAmount;
        uint256 synthesizerId = stakeInfo.synthesizerId;
        stakes[nonce].unstaked = true;

        if (slashAmount > 0) {
            // Burn the slashed amount (can send to a burn address or treasury)
            ERC20Permit(stakeInfo.token).safeTransfer(address(0), slashAmount);
        }

        ERC20Permit(stakeInfo.token).safeTransfer(msg.sender, amountAfterSlash);

        emit Unstaked(msg.sender, stakeInfo.token, amountAfterSlash, synthesizerId, nonce);
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

    // Governance functions using bls signatures

    function pause(uint256[2] memory _blsSignature) external {
        bytes32 messageHash = keccak256("Pause");
        requireMessageVerified(messageHash, _blsSignature);
        _pause();
    }

    function unpause(uint256[2] memory _blsSignature) external {
        bytes32 messageHash = keccak256("Unpause");
        requireMessageVerified(messageHash, _blsSignature);
        _unpause();
    }

    function setRegistryPublicKey(address newRegistryPublicKey, uint256[2] memory _blsSignature) external {
        bytes32 messageHash = keccak256(abi.encodePacked("SetRegistryPublicKey", newRegistryPublicKey));
        requireMessageVerified(messageHash, _blsSignature);
        registryPublicKey = newRegistryPublicKey;
    }

    function recoveryUnstakeETH(uint256 nonce, uint256[2] memory _blsSignature) external {
        bytes32 messageHash = keccak256(abi.encodePacked("RecoveryUnstakeETH", nonce));
        requireMessageVerified(messageHash, _blsSignature);
        Stake memory stakeInfo = stakes[nonce];
        if (stakeInfo.token != address(0)) revert NoStakedETHFound();

        uint256 amount = stakeInfo.amount;
        uint256 synthesizerId = stakeInfo.synthesizerId;
        address user = stakeInfo.user;
        delete stakes[nonce];

        (bool success, ) = user.call{value: amount}("");
        require(success, "Transfer failed");

        emit Recovered(user, address(0), amount, synthesizerId, nonce);
    }

    function recoveryUnstakeERC20(uint256 nonce, uint256[2] memory _blsSignature) external {
        bytes32 messageHash = keccak256(abi.encodePacked("RecoveryUnstakeERC20", nonce));
        requireMessageVerified(messageHash, _blsSignature);
        Stake memory stakeInfo = stakes[nonce];
        address token = stakeInfo.token;
        if (token == address(0)) revert NoStakedTokensFound();

        uint256 amount = stakeInfo.amount;
        uint256 synthesizerId = stakeInfo.synthesizerId;
        address user = stakeInfo.user;
        delete stakes[nonce];

        ERC20Permit(token).safeTransfer(user, amount);

        emit Recovered(user, token, amount, synthesizerId, nonce);
    }

    // Prevent receiving ETH directly without calling stakeETH
    receive() external payable {
        revert("Use stakeETH to stake ETH");
    }

    event Staked(address indexed user, address indexed token, uint256 amount, uint256 synthesizerId, uint256 indexed nonce);
    event Unstaked(address indexed user, address indexed token, uint256 amount, uint256 synthesizerId, uint256 indexed nonce);
    event Recovered(address indexed user, address indexed token, uint256 amount, uint256 synthesizerId, uint256 indexed nonce);
}
