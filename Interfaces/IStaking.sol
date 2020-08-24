pragma solidity ^0.6.0;


interface IStaking {
    function shareOf(address _addr) external view returns (uint256, uint256);
    
    // to be added..
}