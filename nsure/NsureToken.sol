/**
 * @author  Nsure.Team <nsure@nsure.network>
 *
 * @dev     A contract for staking tokens in order to get the dividends of the pool
 *          If widthdraw, should be applied first, N(commonly be modified) blocks later
 *          can it be really withdrawed.
 *
 * @notice  The goal of this contract is to lock tokens for startups.
 *          Use it for your own risk.
 */
 
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../Interfaces/IStaking.sol";
import "../Interfaces/INSureToken.sol";
import "../Common/MinterRole.sol";

contract NsureToken is MinterRole, ERC20, INSureToken {
    using Address for address;
    using SafeMath for uint256;

    IStaking private _staking;

    uint256 private BLOCK_REWARD    = 2 * 1e18;     // mining reward per block
    
    uint256 private _stakingRatio   = 10;           // staking weight for someone who staking their tokens

    uint256 private _lastMintBlock;                 // last mint block for statistics
    uint256 private _lastFinishedMineBlock;         // the last block which reward the miners

    uint256 private _percentForTaker        = 30;   // init for 30% to takers
 
    address public constant TAKER_ADDRESS   = 0x0000000000000000000000000000000000000001;
    address public constant MAKER_ADDRESS   = 0x0000000000000000000000000000000000000002;


    struct Pool {
        uint256 lastWeight;
        uint256 balance;
        uint256 lastMintBlock;

        mapping(address => User) users;
    }

    struct User {
        uint256 lastWeight;
        uint256 balance;
        uint256 lastMintBlock;
    }
    
    Pool public taker;  // for insurace buyer mining
    Pool public maker;  // for insurace provider mining


    // construtors
    constructor () public ERC20("NSure Network Token", "Nsure") {
        _setLastMintBlock(block.number);

        _lastFinishedMineBlock = block.number.add(9460800);  //  about 20 years

        // pre-mine 1500w for investors, whitelists etc.
        _mint(_msgSender(), 15000000 * 1e18);
    }

    function isMintable() public view returns (bool) {
        if (block.number.sub(lastMintBlock()) > 0 && _lastFinishedMineBlock.sub(lastMintBlock()) > 0) {
            return true;
        }

        return false;
    }

    function reward(uint256 blockNumber) public view returns (uint256) {
        return blockNumber.sub(lastMintBlock()).mul(BLOCK_REWARD);
    }

    function mint() public returns (bool) {
        if (!isMintable()) {
            return false;
        }

        uint256 _mints = reward(block.number);
        _setLastMintBlock(block.number);

        uint256 takerMintable = _mints.mul(_percentForTaker).div(100);
        uint256 makerMintable = _mints.sub(takerMintable);

        _mint(TAKER_ADDRESS, takerMintable);
        _mint(MAKER_ADDRESS, makerMintable);

        return true;
    }


    // user share of taker pool
    function share(address account) public view returns (uint256, uint256){
        uint256 m = takerQuantityOfPool();
        uint256 n = takerQuantityOf(account);

        return (m, n);
    }

    function takerQuantityOfPool() public view returns (uint256) {
        return taker.lastWeight;
    }

    function takerQuantityOf(address account) public view returns (uint256) {
        return taker.users[account].lastWeight;
    }

    function takerLastMintBlockOfPool() public view returns (uint256) {
        return taker.lastMintBlock;
    }

    function takerLastMintBlockOf(address account) public view returns (uint256) {
        return taker.users[account].lastMintBlock;
    }

    function takerBalanceOf() public view returns (uint256) {
        return balanceOf(TAKER_ADDRESS);
    }

    // user balance in the taker pool
    function takerBalanceOf(address account) public view returns (uint256) {
        (uint256 m, uint256 n) = share(account);
        if (m <= 0 || n <= 0) {
            return 0;
        }

        return takerBalanceOf().mul(n).div(m);
    }

    // taker mining, allow multi minters such as usdt pool, eth pool, etc
    function takerMining(uint256 amount, address account) public override onlyMinter returns (bool) {
        require(account != address(0), "nsureToken: taker deposit account is the zero address");

        if(amount <= 0) {
            return false;
        }

        mint();

        // update weight according staking ratio
        (uint256 userW, uint256 poolW) = _staking.shareOf(account);
        if(userW > 0 && poolW > userW) {
            uint256 deltaWeight = amount.mul(userW).mul(_stakingRatio).div(poolW);
            amount = amount.add(deltaWeight);
        }

        taker.lastWeight    = takerQuantityOfPool().add(amount);
        taker.lastMintBlock = block.number;

        User storage user   = taker.users[account];
        user.lastWeight     = takerQuantityOf(account).add(amount);
        user.lastMintBlock  = block.number;

        return true;
    }

    function _takerWithdraw(uint256 amount) internal returns (bool) {
        require(takerBalanceOf() >= amount, "nsureToken: taker withdraw amount exceeds taker pool balance");

        uint256 delta = takerQuantityOfPool().mul(amount).div(takerBalanceOf());

        taker.lastWeight    = takerQuantityOfPool().sub(delta);
        taker.lastMintBlock = block.number;

        User storage user   = taker.users[_msgSender()];
        user.lastWeight     = takerQuantityOf(_msgSender()).sub(delta);
        user.lastMintBlock  = block.number;

        _transfer(TAKER_ADDRESS, _msgSender(), amount);

        // do not emit event, for transfer will emit event

        return true;
    }

    function takerWithdraw(uint256 quantity) public returns (bool) {
        mint();

        uint256 balance = takerBalanceOf(_msgSender());
        if (quantity <= balance) {
            return _takerWithdraw(quantity);
        }

        return _takerWithdraw(balance);
    }

    function takerWithdraw() public returns (bool) {
        mint();

        uint256 balance = takerBalanceOf(_msgSender());

        return _takerWithdraw(balance);
    }

    // share of liquidity provider(insurance provider)
    // will multi staking ratio here
    function liquidityOf(address account) public view returns (uint256, uint256) {
        uint256 deltaUser = makerDepositOf(account).mul(block.number.sub(makerTimestampOf(account)));
        uint256 deltaPool = makerDepositOfPool().mul(block.number.sub(makerTimestampOfPool()));

        (uint256 userW, uint256 poolW) = _staking.shareOf(account);
        if(userW > 0 && poolW > userW) {
            deltaUser = deltaUser.mul(userW).mul(_stakingRatio).div(poolW);
            deltaPool = deltaPool.mul(_stakingRatio);
        }

        uint256 m = makerQuantityOfPool().add(deltaPool);
        uint256 n = makerQuantityOf(account).add(deltaUser);

        return (m, n);
    }
    
    function makerQuantityOfPool() public view returns (uint256) {
        return maker.lastWeight;
    }

    function makerDepositOfPool() public view returns (uint256) {
        return maker.balance;
    }

    function makerTimestampOfPool() public view returns (uint256) {
        return maker.lastMintBlock;
    }

    // user share of maker pool
    function makerQuantityOf(address account) public view returns (uint256) {
        return maker.users[account].lastWeight;
    }

    function makerDepositOf(address account) public view returns (uint256) {
        return maker.users[account].balance;
    }

    function makerTimestampOf(address account) public view returns (uint256) {
        return maker.users[account].lastMintBlock;
    }

    function _makerBalanceAndLiquidityOf(address account) internal view returns (uint256, uint256, uint256) {
        (uint256 m, uint256 n) = liquidityOf(account);
        if (n <= 0 || m <= 0) {
            return (0, m, n);
        }

        if (n == m) {
            return (makerBalanceOf(), m, n);
        }

        return (makerBalanceOf().mul(n).div(m), m, n);
    }

    function makerBalanceOf() public view returns (uint256) {
        return balanceOf(MAKER_ADDRESS);
    }

    // user balance in the maker pool
    function makerBalanceOf(address account) public view returns (uint256) {
        (uint256 balance, ,) = _makerBalanceAndLiquidityOf(account);
        return balance;
    }

    function _makerWithdraw(address account) internal returns (bool) {
        require(account != address(0), "nsureToken: maker withdraw account is the zero address");

        mint();

        (uint256 withdrawn, uint256 m, uint256 n) = _makerBalanceAndLiquidityOf(account);
        if (withdrawn <= 0) {
            return false;
        }

        maker.lastWeight    = m.sub(n);
        maker.lastMintBlock = block.number;

        User storage user   = maker.users[account];
        user.lastWeight     = 0;
        user.lastMintBlock  = block.number;

        _transfer(MAKER_ADDRESS, account, withdrawn);

        return true;
    }

    // maker withdraw, will withdraw all money at once
    function makerWithdraw() public returns (bool) {
        return _makerWithdraw(_msgSender());
    }


    function _liquidityUpdate(address account, uint256 amount, uint8 flag) internal returns (bool) {
        require(account != address(0), "nsureToken: liquidity account is the zero address");

        mint();

        if(amount <= 0) {
            return false;
        }

        (uint256 m, uint256 n)  = liquidityOf(account);

        maker.lastWeight        = m;
        maker.lastMintBlock     = block.number;

        User storage user       = maker.users[account];
        user.lastWeight         = n;
        user.lastMintBlock      = block.number;

        if(flag == 1) {
            // deposit
            maker.balance       = makerDepositOfPool().add(amount);
            user.balance        = makerDepositOf(account).add(amount);
        } else if(flag == 2){
            // withdraw
            maker.balance       = makerDepositOfPool().sub(amount);
            user.balance        = makerDepositOf(account).sub(amount);
        }

        return true;
    }

    // Notice:  deposit and withdraw should be same amount, if someone deposit 380usdt which equals to 1eth
    //          then when he withdraw 380usdt, it should be also worked as 1eth, whatever 1eth=500usdt or more

    // if someone depost to liquidity pool, call this to let him mine
    function liquidityDeposit(address account, uint256 amount) public override onlyMinter returns (bool) {
        return _liquidityUpdate(account, amount, 1);    // deposit
    }

    // if someone withdraw of liquidity pool, call this to update his balance and weight etc
    function liquidityWithdraw(address account, uint256 amount) public override onlyMinter returns (bool) {
        return _liquidityUpdate(account, amount, 2);    // withdraw
    }

    function lastMintBlock() public view returns (uint256) {
        return _lastMintBlock;
    }

    function _setLastMintBlock(uint256 blockNumber) internal {
        _lastMintBlock = blockNumber;
    }

    /*************  admin area *************/

    // modify modifyStakingRatio
    function modifyStakingRatio(uint256 ratio) public onlyOwner
        returns(bool success)
    {
        _stakingRatio = ratio;
        return true;
    }

    function setStaking(IStaking newStaking) public onlyOwner {
        require(address(newStaking) != address(0), "NsureToken: newStaking is the zero address");
        _staking = newStaking;
    }

    function setTakerMiningRatio(uint256 ratio) public onlyOwner {
        require(ratio <= 100, "setTakerMiningRatio: ratio is the illegal");
        _percentForTaker = ratio;
    }

}
