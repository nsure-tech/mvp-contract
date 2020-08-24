pragma solidity ^0.6.0;

interface INSureToken {
    // taker mining
    function takerMining(uint amount, address account) external returns (bool);

    // maker(liquidity) deposit
    function liquidityDeposit(address account, uint amount) external returns (bool);

    // maker(liquidity) withdraw
    function liquidityWithdraw(address account, uint amount) external returns (bool);
}
