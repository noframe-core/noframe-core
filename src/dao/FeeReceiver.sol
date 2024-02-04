// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../core/BaseNoFrame.sol";

contract FeeReceiver is BaseNoFrame {
    using SafeERC20 for IERC20;

    constructor(address _addressProvider) BaseNoFrame(_addressProvider) {}

    function transferToken(IERC20 token, address receiver, uint256 amount) external onlyOwner {
        token.safeTransfer(receiver, amount);
    }

    function setTokenApproval(IERC20 token, address spender, uint256 amount) external onlyOwner {
        token.forceApprove(spender, amount);
    }
}
