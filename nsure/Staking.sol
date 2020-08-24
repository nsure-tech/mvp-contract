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
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../Interfaces/IStaking.sol";
import "../Library/Array.sol";

/**
 * @title   Staking: lock fund contract
 */
contract Staking is Ownable, Pausable, IStaking {
    using SafeMath for uint256;
    using Address for address;

    using Array for address[];

    uint256 public constant etherUnit   = 1e18;
    uint256 public constant minmumUnit  = 1e14;

    // This struct tracks fund-related balances for a specific investor address
    struct Investor
    {
        uint256 invests;                    // total invest num at moment for this investor
        uint256 lastMintBlock;              // last mint block
        uint256 lastWeight;                 // last weight before calculating

        uint256 pendingWithdrawal;          // payments available for withdrawal by an investor
        uint256 pendingAtBlock;             // records blocks at which last withdrawal were made
    }

    struct Pool {
        // pool basic info
        ERC20   token;          // contract address, if it's an erc20 token

        uint256 pendingBlocks;  // the delay blocks which allow user to withdraw
        uint256 minDepositNum;  // minimum deposit amount

        // pool variables
        uint256 locked;         // locked invest(under withdraw)
        uint256 avail;          // total invest which is availabe

        uint256 lastMintBlock;              // last mint block
        uint256 lastWeight;                 // last weight before calculating

        mapping (address => Investor) investors;
    }
    Pool public pool;

    // dividend currencies
    address[] public divCurrencies;


    /*************  public functions *************/

    // constructor
    constructor(address tokenAddr, uint256 pendingBlocks, uint256 minDepositNum) public 
    {
        require(tokenAddr != address(0), "error param, tokenAddr should not be 0!");

        pool.token          = ERC20(tokenAddr);
        pool.pendingBlocks  = pendingBlocks;
        pool.minDepositNum  = minDepositNum;
    }
    
    // just receive eth funds as dividends.
    receive() external payable {
        // do nothing..
    }
    

    /**
     * @dev     main staking function
     */
    function staking(uint256 amount) public whenNotPaused 
        returns(bool)
    {
        require(amount >= pool.minDepositNum, "staking amount should greater than minDepositNum!");
        require(pool.token.balanceOf(_msgSender()) >= amount, "insufficient balance");

        return _staking(amount);
    }

    /**
     * @dev submit a withdraw request, then he can really withdraw after n blocks
     */
    function submitWithdrawProposal(uint256 amount) public
    {
        require(amount > 0, "withdraw amount shoule be greater than 0");

        require(pool.investors[_msgSender()].invests >= amount,
                "insufficient balance for the withdraw proposal");

        // update share
        _mint();

        // move the invest to pending invests for really withdraws.
        pool.investors[_msgSender()].invests = pool.investors[_msgSender()].invests.sub(amount);
        pool.investors[_msgSender()].pendingWithdrawal = pool.investors[_msgSender()].pendingWithdrawal.add(amount);
        pool.investors[_msgSender()].pendingAtBlock = block.number;

        // update the total invest num.
        pool.avail  = pool.avail.sub(amount);
        pool.locked = pool.locked.add(amount);

        emit eWithdrawProposal(_msgSender(), amount);
    }

    /**
     * @dev really withdraw
     *      shoule be submit a proposal n blocks ahead.
     *
     * @dev if do withdraw, will withdraw all the money which in pending invests
     *      for there is no need to withdraw just some of it.
     */
    function doWithdraw() public 
    {
        require(pool.investors[_msgSender()].pendingWithdrawal > 0,
                "there is no balance for withdraw.");

        // need n blocks later could it be really withdrawed.
        require((block.number.sub(pool.investors[_msgSender()].pendingAtBlock)) >= pool.pendingBlocks,
                "need wait severl blocks for withdraw");

        _doWithdraw();
    }

    /**
     * @dev     receive dividends, may have many currencies
     * 
     * @notice  just support get all of the dividends at one time
     */
    function getDividends() public 
    {
        _mint();

        (uint256 userW, uint256 poolW) = shareOf(_msgSender());
        require(userW > 0, "userWeight is zero, no need to get dividends!");

        // decrease the ratio of weight
        pool.investors[_msgSender()].lastWeight = 0;
        pool.lastWeight = pool.lastWeight.sub(userW);

        // transfer eth dividends first
        uint256 ethAmount = address(this).balance.mul(userW).div(poolW);
        if(ethAmount >= minmumUnit) {
            _msgSender().transfer(ethAmount);
        }

        // foreach divCurrencies, do transfer by user ratio
        if(divCurrencies.length > 0) {
            for (uint256 index = 0; index < divCurrencies.length; index++) {
                ERC20 token = ERC20(divCurrencies[index]);
                uint256 tokenAmount = token.balanceOf(address(this)).mul(userW).div(poolW);
                if(tokenAmount >= minmumUnit) {
                    token.transfer(_msgSender(), tokenAmount);
                }
            }
        }

        emit eGetDividends(_msgSender());
    }

    /*************  reading functions *************/

    /**
     * @dev     get the invest number and the block number which deposit last time
     *
     * @return  invest         my invest num
     *          blockNo        block no which deposit last time
     *          withdrawal     Payments available for withdrawal by an investor
     *          pendingAtBlock last block no for last withdrawal
     */
    function getInvestorInfo(address _addr) external view
        returns(uint256 invest, uint256 blockNo, uint256 withdrawal, uint256 pendingAtBlock)
    {
        return  (pool.investors[_addr].invests,
                pool.investors[_addr].lastMintBlock,
                pool.investors[_addr].pendingWithdrawal,
                pool.investors[_addr].pendingAtBlock);
    }

    
    /**
     * @dev get the balances of the pool
     */
    function getPoolBalances() public view returns (uint256[] memory) {
        uint256[] memory balances = new uint256[](divCurrencies.length+1);

        balances[0] = address(this).balance;
        if(divCurrencies.length > 0) {
            for (uint256 index = 0; index < divCurrencies.length; index++) {
                ERC20 token = ERC20(divCurrencies[index]);
                balances[index+1] = token.balanceOf(address(this));
            }
        }

        return balances;
    }


    function shareOf(address _addr) public view override returns (uint256, uint256) {
        return (userWeight(_addr), poolWeight());
    }

    function poolWeight() public view returns (uint256) {
        uint256 deltaWeight = 0;

        if(block.number > pool.lastMintBlock) {
            uint256 deltaBlocks = block.number.sub(pool.lastMintBlock);
            deltaWeight = pool.avail.mul(deltaBlocks);
        }
        return pool.lastWeight.add(deltaWeight);
    }

    function userWeight(address _addr) public view returns (uint256) {
        uint256 deltaWeight = 0;

        if(block.number > pool.investors[_addr].lastMintBlock) {
            uint256 deltaBlocks = block.number.sub(pool.investors[_addr].lastMintBlock);
            deltaWeight = pool.investors[_addr].invests.mul(deltaBlocks);
        }
        
        return pool.investors[_addr].lastWeight.add(deltaWeight);
    }


    function getDivCurrencyLength() public view returns (uint256) {
        return divCurrencies.length;
    }


    /*************  admin area *************/

    // modify pendingBlocks
    function modifyWdrawDelayBlocks(uint256 _delayBlocks) public onlyOwner
        returns(bool success)
    {
        require(_delayBlocks > 0, "withdraw delay blocks shoule be greater than 0");

        pool.pendingBlocks = _delayBlocks;
        return true;
    }

    // modify minimumDepositNum
    function modifyMinimumDepositNum(uint256 _depositNum) public onlyOwner
        returns(bool success)
    {
        require(_depositNum > 0, "minimum deposit num shoule be greater than 0");

        pool.minDepositNum = _depositNum;
        return true;
    }

    
    function addDivCurrency(address currency) public onlyOwner {
        divCurrencies.push(currency);
    }

    function delDivCurrency(address currency) public onlyOwner {
        divCurrencies.remove(currency);
    }


    /*************  private functions *************/

    // when balance is changed, need call this function to rebalance the weight
    function _mint() private {
        // update invest weight variables
        if(block.number > pool.investors[_msgSender()].lastMintBlock) {
            // update the weight
            uint256 deltaBlocks = block.number.sub(pool.investors[_msgSender()].lastMintBlock);
            uint256 deltaWeight = pool.investors[_msgSender()].invests.mul(deltaBlocks);
            pool.investors[_msgSender()].lastWeight = pool.investors[_msgSender()].lastWeight.add(deltaWeight);

            pool.investors[_msgSender()].lastMintBlock = block.number;
        }

        // update pool weight variables
        if(block.number > pool.lastMintBlock) {
            uint256 deltaWeight = pool.avail.mul(block.number.sub(pool.lastMintBlock));
            pool.lastWeight = pool.lastWeight.add(deltaWeight);

            pool.lastMintBlock = block.number;
        }
    }

    /**
     * @dev     real staking function
     */
    function _staking(uint256 amount) private returns(bool) {
        // checks

        // do transfer
        pool.token.transferFrom(_msgSender(), address(this), amount);

        _mint();

        // update variables
        pool.avail                              = pool.avail.add(amount);
        pool.investors[_msgSender()].invests    = pool.investors[_msgSender()].invests.add(amount);

        emit eStaking(_msgSender(), amount);

        return true;
    }


    // do really withdraw
    function _doWithdraw() private
    {
        uint256 amount = pool.investors[_msgSender()].pendingWithdrawal;

        // update pool status
        pool.locked = pool.locked.sub(amount);

        // update investor status
        pool.investors[_msgSender()].pendingWithdrawal = 0;

        pool.token.transfer(_msgSender(), amount);
    }


    /*******************  event definition   *******************/

    // staking event
    event eStaking(address indexed user, uint256 amount);

    // submit withdraw proposal event
    event eWithdrawProposal(address indexed user, uint256 amount);

    // get dividends event, don't emit the amount, for there is multi currency
    event eGetDividends(address indexed user);
}

