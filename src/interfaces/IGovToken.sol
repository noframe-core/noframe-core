// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IGovToken is IERC20 {
    function increaseAllowance(address spender, uint256 amount) external returns (bool);

    function transferToLocker(address sender, uint amount) external returns (bool);
}
