pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {WithdrawProxy} from "./WithdrawProxy.sol";
import {PublicVault} from "./PublicVault.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {Clone} from "clones-with-immutable-args/Clone.sol";

abstract contract LiquidationBase is Clone {
    function underlying() public pure returns (address) {
        return _getArgAddress(0);
    }

    function ROUTER() public pure returns (address) {
        return _getArgAddress(20);
    }

    function VAULT() public pure returns (address) {
        return _getArgAddress(40);
    }

    function LIEN_TOKEN() public pure returns (address) {
        return _getArgAddress(60);
    }

    function WITHDRAW_PROXY() public view returns (address) {
        // TODO fix
        return _getArgAddress(80);
    }
}

/**
 * @title LiquidationAccountant
 * @author santiagogregory
 * @notice This contract collects funds from liquidations that overlap with an epoch boundary where liquidity providers are exiting.
 * When the final auction being tracked by a LiquidationAccountant for a given epoch is completed,
 * claim() proportionally pays out auction funds to withdrawing liquidity providers and the PublicVault.
 */
contract LiquidationAccountant is LiquidationBase {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    uint256 withdrawRatio;

    uint256 expected; // Expected value of auctioned NFTs. yIntercept (virtual assets) of a PublicVault are not modified on liquidation, only once an auction is completed.
    uint256 public finalAuctionEnd; // when this is deleted, we know the final auction is over

    address withdrawProxy;

    /**
     * @notice Proportionally sends funds collected from auctions to withdrawing liquidity providers and the PublicVault for this LiquidationAccountant.
     */
    function claim() public {
        //        require(ILienToken(LIEN_TOKEN()).getLiens(finalAuctionEnd).length == 0);

        require(block.timestamp > finalAuctionEnd || finalAuctionEnd == uint256(0), "final auction has not ended");

        uint256 balance = ERC20(underlying()).balanceOf(address(this));
        // would happen if there was no WithdrawProxy for current epoch
        if (withdrawRatio == uint256(0)) {
            ERC20(underlying()).safeTransfer(VAULT(), balance);
        } else {
            //should be wad multiplication
            // declining
            uint256 transferAmount = withdrawRatio * balance;
            ERC20(underlying()).safeTransfer(withdrawProxy, transferAmount);

            unchecked {
                balance -= transferAmount;
            }

            ERC20(underlying()).safeTransfer(VAULT(), balance);
        }

        uint256 oldYIntercept = PublicVault(VAULT()).getYIntercept();

        //
        PublicVault(VAULT()).setYIntercept(
            oldYIntercept - (expected - ERC20(underlying()).balanceOf(address(this))).mulDivDown(1 - withdrawRatio, 1)
        );
    }

    // pass in withdrawproxy address here instead of constructor in case liquidation called before first marked withdraw
    // called on epoch boundary (maybe rename)

    /**
     * @notice Called at epoch boundary, computes the ratio between the funds of withdrawing liquidity providers and the balance of the underlying PublicVault so that claim() proportionally pays out to all parties.
     */
    function calculateWithdrawRatio() public {
        require(msg.sender == VAULT());

        withdrawRatio = WithdrawProxy(WITHDRAW_PROXY()).totalSupply().mulDivDown(1, PublicVault(VAULT()).totalSupply());
    }

    /**
     * @notice Adds an auction scheduled to end in a new epoch to this LiquidationAccountant.
     * @param newLienExpectedValue The expected auction value for the lien being auctioned.
     * @param finalAuctionTimestamp The timestamp by which the auction being added is guaranteed to end. As new auctions are added to the LiquidationAccountant, this value will strictly increase as all auctions have the same maximum duration.
     */
    function handleNewLiquidation(uint256 newLienExpectedValue, uint256 finalAuctionTimestamp) public {
        require(msg.sender == ROUTER());
        expected += newLienExpectedValue;
        finalAuctionEnd = finalAuctionTimestamp;
    }
}