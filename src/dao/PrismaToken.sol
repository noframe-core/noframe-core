// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
    @title Prisma Governance Token
    @notice Given as an incentive for users of the protocol. Can be locked in `TokenLocker`
            to receive lock weight, which gives governance power within the Prisma DAO.
 */
contract PrismaToken is ERC20 {
    // --- ERC20 Data ---

    string internal constant _NAME = "Prisma Governance Token";
    string internal constant _SYMBOL = "PRISMA";
    string public constant version = "1";

    // --- EIP 2612 Data ---

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant permitTypeHash = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // Cache the domain separator as an immutable value, but also store the chain id that it
    // corresponds to, in order to invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;

    address public immutable locker;
    uint256 public immutable maxTotalSupply;

    mapping(address => uint256) private _nonces;

    // --- Functions ---

    constructor(
        address _treasury,
        address _layerZeroEndpoint,
        address _locker,
        uint256 __totalSupply
    ) ERC20(_NAME, _SYMBOL) {
        bytes32 hashedName = keccak256(bytes(_NAME));
        bytes32 hashedVersion = keccak256(bytes(version));

        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, hashedName, hashedVersion);

        _mint(_treasury, __totalSupply);
        maxTotalSupply = __totalSupply;
        locker = _locker;
    }

    // --- EIP 2612 functionality ---

    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    function permit(
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(deadline >= block.timestamp, "PRISMA: expired deadline");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator(),
                keccak256(abi.encode(permitTypeHash, owner, spender, amount, _nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress == owner, "PRISMA: invalid signature");
        _approve(owner, spender, amount);
    }

    function nonces(address owner) external view returns (uint256) {
        // FOR EIP 2612
        return _nonces[owner];
    }

    function transferToLocker(address sender, uint256 amount) external returns (bool) {
        require(msg.sender == locker, "Not locker");
        _transfer(sender, locker, amount);
        return true;
    }

    // --- Internal operations ---

    function _buildDomainSeparator(bytes32 typeHash, bytes32 name_, bytes32 version_) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, name_, version_, block.chainid, address(this)));
    }

    function transfer(address to, uint256 value) public virtual override returns (bool) {
        address owner = _msgSender();
        require(to != address(this), "ERC20: transfer to the token address");
        _transfer(owner, to, value);
        return true;
    }
}
