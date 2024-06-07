// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { TokenMock } from "../src/Mocks/TokenMock.sol";
import { VaultV1 } from "../src/VaultV1.sol";

contract All is Script {
    function run() public {
        vm.broadcast();

        TokenMock token = new TokenMock(address(this));
        console.log("Token deployed to:", address(token));

        uint256[4] memory governancePublicKey;

        address vault = Upgrades.deployUUPSProxy(
            "VaultV1.sol",
            abi.encodeCall(VaultV1.initialize, (address(0), governancePublicKey))
        );
        console.log("VaultV1 deployed to:", vault);

        token.approve(vault, 1 ether);
        uint256 synthesizerId = 101;
        VaultV1(payable(vault)).stakeERC20(address(token), 1 ether, synthesizerId);
    }
}
