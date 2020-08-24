pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../Library/Roles.sol";

contract MinterRole is Ownable {
    using Roles for Roles.Role;

    Roles.Role private _minters;
    uint32 private _minterCounts = 0;

    constructor () internal {}

    function _addMinter(address account) internal {
        _minters.add(account);
        _minterCounts = _minterCounts + 1;

        emit MinterAdded(account);
    }

    function addMinter(address account) public onlyOwner {
        _addMinter(account);
    }

    function addMinter(address[] memory accounts) public onlyOwner {
        for (uint256 index = 0; index < accounts.length; index++) {
            _addMinter(accounts[index]);
        }
    }

    function _delMinter(address account) internal {
        _minters.remove(account);

        if(_minterCounts > 0) {
            _minterCounts = _minterCounts - 1;
        }

        emit MinterRemoved(account);
    }

    function renounceMinter() public {
        _delMinter(msg.sender);
    }

    function delMinter(address account) public onlyOwner {
        _delMinter(account);
    }

    function getMintersLength() public view returns (uint256) {
        return _minterCounts;
    }

    function isMinter(address account) public view returns (bool) {
        return _minters.has(account);
    }


    modifier onlyMinter() {
        require(isMinter(msg.sender), "MinterRole: caller does not have the Minter role");
        _;
    }


    event MinterAdded(address indexed account);
    event MinterRemoved(address indexed account);
}