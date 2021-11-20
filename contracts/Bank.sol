//SPDX-License-Identifier: Unlicense

pragma solidity 0.7.0;

import "./interfaces/IBank.sol";
import "./interfaces/IPriceOracle.sol";
import "./libraries/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/GSN/Context.sol";

contract Bank is Context, IBank {

    using DSMath for uint256;

    IPriceOracle public priceOracle;
    address public hakToken;
    address public constant ethMagic = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    mapping (address => Account) hakAccount;
    mapping (address => Account) ethAccount;
    mapping (address => Account) loanAccount;

    constructor() {
        priceOracle = IPriceOracle(address(0xc3F639B8a6831ff50aD8113B438E2Ef873845552));
        hakToken = address(0xBefeeD4CB8c6DD190793b1c97B72B60272f3EA6C);
    }

    /**
     * Substract deposit from the account
     * @param account - the account to Account
     * @param amount - the amount to substract
     */
    function _substract(Account storage account, uint256 amount) private {

        if(account.interest > amount) {
            account.interest = account.interest.sub(amount);
        }
        else if(account.interest <= amount) {
            account.deposit = account.deposit.sub(account.deposit.sub(account.interest));
            account.interest = 0;
        }
    }

    /**
     * This funtion calculates the corateral interest.
     * @param ethLoan - amount of the Ethereum loan.
     * @param hakCorateral - amount of the HAK corateral.
     */
    function _calculateCorateralRatio(uint256 ethLoan, uint256 hakCorateral) view private returns (uint256) {
        require(ethLoan != 0);
        uint256 hakToEthRate = priceOracle.getVirtualPrice(hakToken);
        return (hakCorateral.mul(hakToEthRate).mul(10000) / (10 ** 18)) / ethLoan;
    }

    /**
     * This function calculates the interest.
     * @param acc - the account to update its interest.
     */
    function _calculateInterest(Account storage acc, uint256 rate) view private returns (uint256) {
        uint256 deltaBlocks = block.number.sub(acc.lastInterestBlock);
        return acc.interest.add(acc.deposit.mul(deltaBlocks.mul(rate)) / 10000);
    }

    /**
     * Convert Hak to Eth
     * @param hakAmount - the amount of hak.
     */
    function _convertHakToEth(uint256 hakAmount) view private returns (uint256) {
        return hakAmount.mul(priceOracle.getVirtualPrice(hakToken)) / (10 ** 18);
    }

    /**
     * Convert Eth to Hak
     * @param ethAmount - the amount of hak.
     */
    function _convertEthToHak(uint256 ethAmount) view private returns (uint256) {
        return ethAmount.mul(10 ** 18) / priceOracle.getVirtualPrice(hakToken);
    }

    /**
     * This function updates the interest.
     * @param acc - the account to update its interest.
     */
    function _updateInterest(Account storage acc, uint256 rate) private {
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

        uint256 maximumAmount = acc.deposit.add(_calculateInterest(acc, 3));

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

        uint256 hakToEthRate = priceOracle.getVirtualPrice(hakToken);
        // uint256 hakToEthRate = 1;

        Account storage hakAcc = hakAccount[_msgSender()];
        Account storage loanAcc = loanAccount[_msgSender()];

        uint256 hakBalance = hakAcc.deposit.add(_calculateInterest(hakAcc, 3));
        uint256 loanBalance = loanAcc.deposit.add(_calculateInterest(loanAcc, 5));

        if(hakBalance == 0) {
            revert("no collateral deposited");
        }

        uint256 maxLoan = ((hakBalance.mul(hakToEthRate) / (150)).mul(10 ** 2) / (10 ** 18)).sub(loanBalance);

        if(maxLoan < 0) {
            revert("borrow would exceed collateral ratio");
        }

        if(amount == 0) {
            amount = maxLoan;
        }

        if(amount > maxLoan) {
            revert("borrow would exceed collateral ratio");
        }

        _updateInterest(loanAcc, 5);

        loanAcc.deposit = loanAcc.deposit.add(amount);

        uint256 colateralRatio = _calculateCorateralRatio(
            loanAcc.deposit.add(_calculateInterest(loanAcc, 5)),
            hakBalance
        );

        emit Borrow(_msgSender(), token, amount, colateralRatio);

        return colateralRatio;
    }

    /**
     * The purpose of this function is to allow users to repay their loans.
     * Loans can be repaid partially or entirely. When replaying a loan, an
     * interest payment is also required. The interest on a loan is equal to
     * 5% of the amount lent per 100 blocks. If the loan is repaid earlier,
     * or later then the interest should be proportional to the number of 
     * blocks that the amount was borrowed for.
     * @param token - the address of the token to repay. If this address is
     *                set to 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE then 
     *                the token is ETH.
     * @param amount - the amount to repay including the interest.
     * @return - the amount still left to pay for this loan, excluding interest.
     */
    function repay(address token, uint256 amount)
        payable
        external
        override
        returns (uint256) {
        
        Account storage acc;
        Account storage loanAcc = loanAccount[_msgSender()];

        if(token == ethMagic) {
            if(msg.value < amount) {
                revert("msg.value < amount to repay");
            }
            acc = ethAccount[_msgSender()];
        }
        else {
            revert("token not supported");
        }

        uint256 loanBalance = loanAcc.deposit.add(_calculateInterest(loanAcc, 5));

        if(loanBalance == 0) {
            revert("nothing to repay");
        }

        _updateInterest(loanAcc, 5);

        if(loanBalance < amount) {
            loanAcc.deposit = 0;
            loanAcc.interest = 0;
        }
        else if(loanAcc.interest >= amount) {
            loanAcc.interest = loanAcc.interest.sub(amount);
        }
        else{
            loanAcc.deposit = loanAcc.deposit.sub(amount.sub(loanAcc.interest));
            loanAcc.interest = 0;
        }

        emit Repay(_msgSender(), token, loanAcc.deposit);

        return loanAcc.deposit;
    }

    /**
     * The purpose of this function is to allow so called keepers to collect bad
     * debt, that is in case the collateral ratio goes below 150% for any loan. 
     * @param token - the address of the token used as collateral for the loan. 
     * @param account - the account that took out the loan that is now undercollateralized.
     * @return - true if the liquidation was successful, otherwise revert.
     */
    function liquidate(address token, address account)
        payable
        external
        override
        returns (bool) {

        if(token != hakToken) {
            revert("token not supported");
        }

        if(_msgSender() == account) {
            revert("cannot liquidate own position");
        }
        
        Account storage borrowerLoan = loanAccount[account];
        Account storage borrowerHak = hakAccount[account];
        Account storage liquidatorHak = hakAccount[_msgSender()];

        uint256 loanAmount = borrowerLoan.deposit.add(_calculateInterest(borrowerLoan, 5));
        uint256 borrowerHakEquiEth = _convertHakToEth(_getBalance(hakToken, account));

        if(getCollateralRatio(hakToken, account) >= 15000) {
            revert("healthy position");
        }

        if(loanAmount > msg.value) {
            revert("insufficient ETH sent by liquidator");
        }

        if(loanAmount > borrowerHakEquiEth) {
            revert("insufficient collateral of borrower");
        }

        _substract(borrowerHak, (_convertEthToHak(msg.value)));
        liquidatorHak.deposit = liquidatorHak.deposit.add(_convertEthToHak(msg.value));
        borrowerLoan.deposit = 0;
        borrowerLoan.interest = 0;

        emit Liquidate(_msgSender(), account, hakToken, loanAmount, msg.value);

        return true;
    }

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

        Account storage hakAcc = hakAccount[account];
        Account storage loanAcc = loanAccount[account];

        return _calculateCorateralRatio(
            loanAcc.deposit.add(_calculateInterest(loanAcc, 5)),
            hakAcc.deposit.add(_calculateInterest(hakAcc, 3))
        );
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
        return _getBalance(token, _msgSender());
    }

    /**
     * The purpose of this function is to return the balance that the caller 
     * has in their own account for the given token (including interest).
     * @param token - the address of the token for which the balance is computed.
     * @param account - the address of the account.
     * @return - the value of the caller's balance with interest, excluding debts.
     */
    function _getBalance(address token, address account) view private returns(uint256) {

        Account storage acc;

        if(token == hakToken){
            acc = hakAccount[account];
        }
        else if(token == ethMagic) {
            acc = ethAccount[account];
        }
        else{
            revert("token not supported");
        }

        return acc.deposit.add(_calculateInterest(acc, 3));
    }
}
