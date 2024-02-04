// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import { IOFT } from "@layerzerolabs/solidity-examples/contracts/token/oft/v1/interfaces/IOFT.sol";
import "./IERC2612.sol";

interface IStablecoin is IOFT, IERC2612 {
    // --- Functions ---

    function mint(address _account, uint256 _amount) external;

    function mintWithGasCompensation(address _account, uint256 _amount) external returns (bool);

    function burnWithGasCompensation(address _account, uint256 _amount) external returns (bool);

    function burn(address _account, uint256 _amount) external;

    function sendToSP(address _sender, uint256 _amount) external;

    function returnFromPool(address poolAddress, address user, uint256 _amount) external;

    function enableCollateral(address _troveManager) external;
}
