//SPDX-License-Identifier: Unlicense

pragma solidity 0.7.0;

import "./interfaces/IBank.sol";
import "./interfaces/IPriceOracle.sol";
import "./libraries/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/GSN/Context.sol";

contract Bank is Context, IBank {

    using DSMath for uint;

    IPriceOracle public priceOracle;
    address public hakToken;
    address public constant ethMagic = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    mapping (address => Account) hakAccount;
    mapping (address => Account) ethAccount;
    mapping (address => Account) loanAccount;

    constructor(address _priceOracle, address _hakToken) {
        priceOracle = IPriceOracle(_priceOracle);
        hakToken = _hakToken;
    }

    /**
     * This function calculates the interest.
     * @param acc - the account to update its interest.
     */
    function _calculateInterest(Account storage acc, uint rate) view private returns (uint) {
        uint deltaBlocks = block.number.sub(acc.lastInterestBlock);
        return acc.interest.add(acc.deposit.mul(deltaBlocks.mul(rate)) / 10000);
    }

    /**
     * This function updates the interest.
     * @param acc - the account to update its interest.
     */
    function _updateInterest(Account storage acc, uint rate) private {
        if(acc.lastInterestBlock == 0){
            acc.lastInterestBlock = block.number;
        }
        else{
            acc.interest = _calculateInterest(acc, rate);
        }
        acc.lastInterestBlock = block.number;
    }

    /**
     * The purpose of this function is to allow end-users to deposit a given 
     * token amount into their bank account.
     * @param token - the address of the token to deposit. If this address is
     *                set to 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE then 
     *                the token to deposit is ETH.
     * @param amount - the amount of the given token to deposit.
     * @return - true if the deposit was successful, otherwise revert.
     */
    function deposit(address token, uint256 amount)
        payable
        external
        override
        returns (bool) {

        Account storage acc;
        
        if(token == hakToken) {
            ERC20 hakTokenContract = ERC20(hakToken);
            if(!hakTokenContract.transferFrom(_msgSender(), address(this), amount)){
                revert("transfer not allowed");
            }
            acc = hakAccount[_msgSender()];
        }
        else if(token == ethMagic) {
            if(amount != msg.value) {
                revert("invalid request");
            }
            acc = ethAccount[_msgSender()];
        }
        else{
            revert("token not supported");
        }

        _updateInterest(acc, 3);

        acc.deposit = acc.deposit.add(amount);

        emit Deposit(_msgSender(), token, amount);
        
        return true;
    }

    /**
     * The purpose of this function is to allow end-users to withdraw a given 
     * token amount from their bank account. Upon withdrawal, the user must
     * automatically receive a 3% interest rate per 100 blocks on their deposit.
     * @param token - the address of the token to withdraw. If this address is
     *                set to 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE then 
     *                the token to withdraw is ETH.
     * @param amount - the amount of the given token to withdraw. If this param
     *                 is set to 0, then the maximum amount available in the 
     *                 caller's account should be withdrawn.
     * @return - the amount that was withdrawn plus interest upon success, 
     *           otherwise revert.
     */
    function withdraw(address token, uint256 amount)
        external
        override
        returns (uint256) {

        Account storage acc;

        if(token == hakToken) {
            acc = hakAccount[_msgSender()];
        }
        else if(token == ethMagic) {
            acc = ethAccount[_msgSender()];
        }
        else{
            revert("token not supported");
        }

        _updateInterest(acc, 3);

        uint maximumAmount = acc.deposit.add(_calculateInterest(acc, 3));

        if(maximumAmount == 0) {
            revert("no balance");
        }

        if(amount != 0 && maximumAmount <= amount) {
            revert("amount exceeds balance");
        }

        if(amount == 0){
            amount = maximumAmount;
        }

        if(amount <= acc.interest) {
            acc.interest = acc.interest.sub(amount);
        }
        else {
            acc.deposit = acc.deposit.add(acc.interest);
            acc.deposit = acc.deposit.sub(amount);
        }

        emit Withdraw(_msgSender(), token, amount);

        return acc.deposit.add(_calculateInterest(acc, 3));
    }

    /**
     * The purpose of this function is to allow users to borrow funds by using their 
     * deposited funds as collateral. The minimum ratio of deposited funds over 
     * borrowed funds must not be less than 150%.
     * @param token - the address of the token to borrow. This address must be
     *                set to 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, otherwise  
     *                the transaction must revert.
     * @param amount - the amount to borrow. If this amount is set to zero (0),
     *                 then the amount borrowed should be the maximum allowed, 
     *                 while respecting the collateral ratio of 150%.
     * @return - the current collateral ratio.
     */
    function borrow(address token, uint256 amount)
        external
        override
        returns (uint256) {
        
        if(token != ethMagic) {
            revert("token not supported");
        }

        uint hakToEthRate = priceOracle.getVirtualPrice(hakToken);

        Account storage hakAcc = hakAccount[_msgSender()];
        Account storage loanAcc = loanAccount[_msgSender()];

        uint hakBalance = hakAcc.deposit.add(_calculateInterest(hakAcc, 3));
        uint loanBalance = loanAcc.deposit.add(_calculateInterest(loanAcc, 5));

        if(hakBalance == 0) {
            revert("no collateral deposited");
        }

        uint maxLoan = (hakBalance.mul(hakToEthRate).mul(150)).sub(loanBalance.mul(100)) / 100;

        if(amount == 0) {
            amount = maxLoan;
        }

        if(amount > maxLoan) {
            revert("borrow would exceed collateral ratio");
        }

        _updateInterest(loanAcc, 5);

        loanAcc.deposit = loanAcc.deposit.add(amount);

        uint colateralRatio = hakBalance.mul(hakToEthRate) / loanAcc.deposit.add(_calculateInterest(loanAcc, 5));

        emit Borrow(_msgSender(), token, amount, colateralRatio);

        return colateralRatio;
    }

    function repay(address token, uint256 amount)
        payable
        external
        override
        returns (uint256) {}

    function liquidate(address token, address account)
        payable
        external
        override
        returns (bool) {}

    /**
     * The purpose of this function is to return the collateral ratio for any account.
     * The collateral ratio is computed as the value deposited divided by the value
     * borrowed. However, if no value is borrowed then the function should return 
     * uint256 MAX_INT = type(uint256).max
     * @param token - the address of the deposited token used a collateral for the loan. 
     * @param account - the account that took out the loan.
     * @return - the value of the collateral ratio with 2 percentage decimals, e.g. 1% = 100.
     *           If the account has no deposits for the given token then return zero (0).
     *           If the account has deposited token, but has not borrowed anything then 
     *           return MAX_INT.
     */
    function getCollateralRatio(address token, address account)
        view
        public
        override
        returns (uint256) {

        if(token != hakToken) revert("token not supported");

        uint hakToEthRate = priceOracle.getVirtualPrice(hakToken);

        Account storage hakAcc = hakAccount[account];
        Account storage loanAcc = loanAccount[account];

        if(loanAcc.deposit.add(_calculateInterest(loanAcc, 5)) == 0) {
            return type(uint256).max;
        }

        return (hakAcc.deposit.add(_calculateInterest(hakAcc, 3)).mul(hakToEthRate)) /
               (loanAcc.deposit.add(_calculateInterest(loanAcc, 5)));
    }


    /**
     * The purpose of this function is to return the balance that the caller 
     * has in their own account for the given token (including interest).
     * @param token - the address of the token for which the balance is computed.
     * @return - the value of the caller's balance with interest, excluding debts.
     */
    function getBalance(address token)
        view
        public
        override
        returns (uint256) {

        Account storage acc;

        if(token == hakToken){
            acc = hakAccount[_msgSender()];
        }
        else if(token == ethMagic) {
            acc = ethAccount[_msgSender()];
        }
        else{
            revert("token not supported");
        }

        return acc.deposit.add(_calculateInterest(acc, 3));
    }
}
