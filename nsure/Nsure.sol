pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../Interfaces/INSureToken.sol";

contract NSure is Ownable, Pausable {
    using Address for address;
    using SafeMath for uint;

    INSureToken private _mine;

    uint public constant etherUnit  = 1e18;
    
    uint public orderIndex          = 1000;

    uint private _percentPremiumForIP       = 50;   // insurance provider permium ratio
    uint private _percentPremiumForStaking  = 30;   // staking permium ratio, and left is for team

    uint private _createdBlockNo;
    uint private _minimumDeposit;
    address payable private _stakingAddr;
    address payable private _teamPremiumAddr;

    // Insurance product Struct
    struct Product {
        string productName;
        uint feeRate;
        uint status;

        uint totalPremium;
        uint totalSale;
    }
    mapping (address => Product) private _products;

    // The Insurance Provider Struct
    struct InsuranceProvider {
        uint avail;
        uint locked;

        uint lastDepositNumber;
    }

    // The Insurance Pool Struct
    struct InsurancePool {
        uint avail;
        uint locked;

        mapping(address => InsuranceProvider) ips;
    }
    // just support eth at the moment
    InsurancePool public ethPool;


    // order detail for one provider
    struct OrderDetail {
        address providerAddr;
        uint amount;
    }

    // Insurance Order
    // Attr state, 0: in progress; 1: finished; 2: compensated
    struct Order {
        address payable buyer;

        uint premium;
        uint price;
        uint settleBlockNumber;

        uint8 totalProviders;
        uint8 state;

        mapping(uint => OrderDetail) orderDetails;
    }
    mapping (bytes32 => Order) public insuranceOrders;

    constructor() public {
        _createdBlockNo     = block.number;
        _teamPremiumAddr    = _msgSender();
    }

    // empty function and do not receive any eth funds.
    receive() external payable {
        require(msg.value == 0, "this function should not be called at any time!");

        // do nothing..
    }

    /*************  public functions *************/
    
    // Buy Insurance main function
    // _amount:     the total value for insurance
    // msg.value:   the premium of the insurance
    // _ipAddrs,_ipAmount:  the insurance provider infos
    function buyInsurance(address _productAddr, uint _amount, uint _blocks, 
                address payable [] calldata _ipAddrs, uint[] calldata _ipAmount) 
            external payable whenNotPaused returns (bytes32 _orderId) 
    {
        require(_ipAddrs.length <= 3, "_ipAddrs.length is too long..");
        require(_ipAddrs.length == _ipAmount.length, "_ipAddrs and _ipAmount need to correspond");

        Product storage _productInfo = _products[_productAddr];
        require(_productInfo.status == 1, "this product is disabled!");

        // Initialize order data
        _orderId        = _buildOrderId(_productAddr, _amount, _blocks);

        uint premium    = _calculatePremium(_amount, _blocks, _productInfo.feeRate);
        require(premium == msg.value, "premium and msg.value is not the same");

        Order storage _order = insuranceOrders[_orderId];
        require(_order.buyer == address(0), "order id is not empty?!");

        _order.buyer    = _msgSender();
        _order.premium  = premium;
        _order.price    = _amount;
        _order.state    = 0;
        _order.settleBlockNumber = _blocks.add(block.number);

        _doBuyInsurance(_order, _productInfo, _ipAddrs, _ipAmount);

        emit NewOrder(_orderId, _order.buyer, _productAddr, _order.premium, _order.price, _order.settleBlockNumber);
    }

    function _doBuyInsurance(Order storage _order, Product storage _productInfo, 
                             address payable [] memory _ipAddrs, uint[] memory _ipAmount)
        internal returns (bool) 
    {
        uint _totalAmount       = 0;
        uint _totalIpPremium    = 0;
        for (uint8 i = 0; i < _ipAddrs.length; i++) {
            require(_ipAmount[i] > 0, "_ipAmount is zero");

            InsuranceProvider storage _currProvider = ethPool.ips[_ipAddrs[i]];
            require(_currProvider.avail >= _ipAmount[i], "Insurance provider avail balance not enough");

            uint ipPremium = _updateBuyInsuranceIP(_currProvider, _ipAddrs[i], _ipAmount[i], _order.price, _order.premium);
            
            _totalIpPremium = _totalIpPremium.add(ipPremium);
            _totalAmount = _totalAmount.add(_ipAmount[i]);

            // Set order details
            _order.orderDetails[i] = OrderDetail(_ipAddrs[i], _ipAmount[i]);
            _order.totalProviders = _order.totalProviders + 1;
        }

        require(_totalAmount == _order.price, "The calldata amount is inconsistent with the order amount");

        _distributeOtherPremium(_order.premium, _totalIpPremium);

        // Update pool avail and locked
        ethPool.avail = ethPool.avail.sub(_totalAmount);
        ethPool.locked = ethPool.locked.add(_totalAmount);

        // Update product totalPremium and totalSale
        _productInfo.totalPremium = _productInfo.totalPremium.add(_order.premium);
        _productInfo.totalSale = _productInfo.totalSale.add(_totalAmount);

        // should be premium to do mine param, because some one can let amount bigger, and blocks less
        getMine().takerMining(_order.premium, _msgSender());

        return true;
    }

    function _distributeOtherPremium(uint premium, uint ipPremium) internal returns (bool) {
        // distribute premium to staking contract, and left is for team
        uint stakingPremium = premium.mul(_percentPremiumForStaking).div(100);
        _stakingAddr.transfer(stakingPremium);

        // for team bonus to do buy back etc.
        _teamPremiumAddr.transfer(premium.sub(ipPremium).sub(stakingPremium));

        return true;
    }

    function _calculatePremium(uint amount, uint blocks, uint feeRate) internal pure returns (uint) {
        return amount.mul(blocks).mul(feeRate).div(etherUnit);
    }

    // update ip when one user buy insurance
    function _updateBuyInsuranceIP(InsuranceProvider storage ip, address payable ipAddr, uint ipAmount, uint totalAmount, uint premium)
        internal returns(uint ipPremium) 
    {
        ip.avail = ip.avail.sub(ipAmount);
        ip.locked = ip.locked.add(ipAmount);

        // distribute premium
        ipPremium = premium.mul(ipAmount).div(totalAmount).mul(_percentPremiumForIP).div(100);

        ipAddr.transfer(ipPremium);
    }

    // addInsuranceLiquidity to pool
    function addLiquidityEth() payable external whenNotPaused returns(bool) {
        require(msg.value >= _minimumDeposit, "amount should be greater than or equal to minimumDeposit");

        InsuranceProvider storage _provider = ethPool.ips[_msgSender()];
        _provider.avail = _provider.avail.add(msg.value);
        _provider.lastDepositNumber = block.number;

        ethPool.avail = ethPool.avail.add(msg.value);

        getMine().liquidityDeposit(_msgSender(), msg.value);
        emit AddLiquidity(_msgSender(), msg.value);

        return true;
    }

    // Withdraw avail insurance liquidity
    function withdrawLiquidity(uint _amount) public whenNotPaused returns(bool) {
        InsuranceProvider storage _provider = ethPool.ips[_msgSender()];
        
        require(_provider.avail >= _amount, "The available balance of the account is insufficient");

        // update InsuranceProvider and eth pool avail amount
        _provider.avail = _provider.avail.sub(_amount);
        ethPool.avail = ethPool.avail.sub(_amount);

        _msgSender().transfer(_amount);

        getMine().liquidityWithdraw(_msgSender(), _amount);
        emit WithdrawLiquidity(_msgSender(), _amount);

        return true;
    }

    // Get insurance provider eth pool info
    function InsuranceProviderPoolInfo(address _providerAddr) public view returns(uint avail, uint locked) {
        avail = ethPool.ips[_providerAddr].avail;
        locked = ethPool.ips[_providerAddr].locked;
    }

    /*************  private functions *************/

    function _buildOrderId(address _productAddr, uint _amount, uint _blocks) private returns (bytes32) {
        orderIndex++;
        address buyer = _msgSender();
        return sha256(abi.encode(uint(keccak256(abi.encode(_productAddr))) + uint(keccak256(abi.encode(buyer))) + _amount + block.number + _blocks + now + orderIndex));
    }

    /*************  admin area *************/

    function setMinimumDeposit(uint _amount) public onlyOwner {
        require(_amount > 0, "amount should be greater than 0");

        _minimumDeposit = _amount;
    }

    // settle one insurance order to finish status with no claims
    function setOrderFinished(bytes32 _orderId) public onlyOwner returns (bool) {
        Order storage _orderInfo = insuranceOrders[_orderId];

        require(_orderInfo.state == 0, "Order status is not pending");
        require(block.number >= _orderInfo.settleBlockNumber, "Unlocking time not reached");
        
        uint _len = _orderInfo.totalProviders;
        for(uint i = 0; i < _len; i++) {
            address _providerAddr = _orderInfo.orderDetails[i].providerAddr;
            uint _providerAmount = _orderInfo.orderDetails[i].amount;

            // Update eth pool insurance provider avail and locked amount
            ethPool.ips[_providerAddr].avail = ethPool.ips[_providerAddr].avail.add(_providerAmount);
            ethPool.ips[_providerAddr].locked = ethPool.ips[_providerAddr].locked.sub(_providerAmount);
        }

        // Update eth pool avail and locked amount
        ethPool.avail = ethPool.avail.add(_orderInfo.price);
        ethPool.locked = ethPool.locked.sub(_orderInfo.price);

        // update the order state to finished
        _orderInfo.state = 1;

        emit ChangeOrder(_orderId, 1, _orderInfo.price);

        return true;
    }

    // Settle one insurance order to compensate status which need claims
    function setOrderWithClaims(bytes32 _orderId) public onlyOwner returns (bool) {
        Order storage _orderInfo = insuranceOrders[_orderId];

        require(_orderInfo.state == 0, "Order status is not pending");
        require(block.number >= _orderInfo.settleBlockNumber, "Unlocking time not reached");

        uint _len = _orderInfo.totalProviders;
        for(uint i = 0; i < _len; i++) {
            address _providerAddr = _orderInfo.orderDetails[i].providerAddr;
            uint _providerAmount = _orderInfo.orderDetails[i].amount;

            ethPool.ips[_providerAddr].locked = ethPool.ips[_providerAddr].locked.sub(_providerAmount);

            // here should withdraw liquidity, because the money has been repaid..
            getMine().liquidityWithdraw(_providerAddr, _providerAmount);
        }

        // Transfer _totalAmount to Order buyer
        _orderInfo.buyer.transfer(_orderInfo.price);

        // Update eth pool locked amount
        ethPool.locked = ethPool.locked.sub(_orderInfo.price);

        // update the order state to compensated
        insuranceOrders[_orderId].state = 2;

        emit ChangeOrder(_orderId, 2, _orderInfo.price);

        return true;
    }

    function getProduct(address _productAddr) public view returns (Product memory) {
        return _products[_productAddr];
    }

    function addProduct(address _productAddr, string memory _productName, uint _feeRate, uint _status) public onlyOwner {
        _products[_productAddr]    =  Product(_productName, _feeRate, _status, 0, 0);
    }

    function updateProduct(address _productAddr, string memory  _productName, uint _feeRate, uint _status) public onlyOwner {
        _products[_productAddr] = Product(_productName, _feeRate, _status, 0, 0);
    }

    function deleteProduct(address _productAddr) public onlyOwner {
        delete _products[_productAddr];
    }

    /**
     * dao
     */
    function getMine() public view returns (INSureToken) {
        return _mine;
    }

    function setMine(INSureToken newMine) public onlyOwner {
        require(address(newMine) != address(0), "Nsure: new _mine is the zero address");
        _mine = (newMine);
    }

    function setTeamPremiumAddr(address payable _newAddr) public onlyOwner {
        require(_newAddr != address(0), "Nsure: _newAddr is the zero address");
        _teamPremiumAddr = _newAddr;
    }

    function setStakingAddr(address payable _newAddr) public onlyOwner {
        require(_newAddr != address(0), "Nsure: _newAddr is the zero address");
        _stakingAddr = _newAddr;
    }

    
    // Events
    event ChangeOrder(bytes32 orderId, uint8 state, uint totalAmount);
    event NewOrder(bytes32 orderId, address buyerAddr, address productAddr, uint premium, uint price, uint blocks);
    event AddLiquidity(address ipAddr, uint amount);
    event WithdrawLiquidity(address ipAddr, uint amount);
}
