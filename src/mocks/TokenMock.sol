// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenMock is ERC20 {
    constructor(address _owner) ERC20("TokenMock", "TM") {
        _mint(_owner, 21 * 10**9 * 10**18); // 21 billion tokens, assuming 18 decimals
    }
}
