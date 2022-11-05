// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";

import {
  IERC1155Receiver
} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {ERC721} from "gpl/ERC721.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {IPublicVault} from "../interfaces/IPublicVault.sol";
import {CollateralToken, IFlashAction} from "../CollateralToken.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {IVault, VaultImplementation} from "../VaultImplementation.sol";
import {IVaultImplementation} from "../interfaces/IVaultImplementation.sol";
import {LienToken} from "../LienToken.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";

contract RevertTesting is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;

  function testFailInvalidSignatureAndInvalidStrategist() public {
    TestNFT nft = new TestNFT(3);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToVault(
      Lender({addr: strategistOne, amountToLend: 50 ether}),
      privateVault
    );

    IAstariaRouter.Commitment memory terms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      stack: new ILienToken.Stack[](0)
    });

    IAstariaRouter.Commitment memory terms2 = terms;
    terms.lienRequest.strategy.strategist = address(5);
    terms2.lienRequest.r = bytes32(0);
    ERC721(tokenContract).setApprovalForAll(address(ASTARIA_ROUTER), true);

    IAstariaRouter.Commitment[]
      memory commitments = new IAstariaRouter.Commitment[](1);
    commitments[0] = terms;

    IAstariaRouter.Commitment[]
      memory commitments2 = new IAstariaRouter.Commitment[](1);
    commitments[0] = terms2;

    COLLATERAL_TOKEN.setApprovalForAll(address(ASTARIA_ROUTER), true);
    vm.expectRevert(
      abi.encodeWithSelector(
        IVaultImplementation.InvalidRequest.selector,
        IVaultImplementation.InvalidRequestReason.INVALID_SIGNATURE
      )
    );
    ASTARIA_ROUTER.commitToLiens(commitments);
    vm.expectRevert(
      abi.encodeWithSelector(
        IVaultImplementation.InvalidRequest.selector,
        IVaultImplementation.InvalidRequestReason.INVALID_STRATEGIST
      )
    );
    ASTARIA_ROUTER.commitToLiens(commitments2);
  }

  // Only strategists for PrivateVaults can supply capital
  function testFailSoloLendNotAppraiser() public {
    TestNFT nft = new TestNFT(3);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      privateVault
    );
  }

  function testFailBorrowMoreThanMaxAmount() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    ILienToken.Details memory details = standardLienDetails;
    details.maxAmount = 10 ether;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 11 ether,
      isFirstLien: true
    });
  }

  // PublicVaults should not be able to progress to the next epoch unless all liens that are able to be liquidated have been liquidated
  function testFailProcessEpochWithUnliquidatedLien() public {
    TestNFT nft = new TestNFT(3);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    // borrow 10 eth against the dummy NFT
    _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    vm.warp(block.timestamp + 15 days);
    PublicVault(publicVault).processEpoch();
  }

  function testFailBorrowMoreThanMaxPotentialDebt() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    // borrow 10 eth against the dummy NFT
    _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: false
    });
  }

  function testFailMinMaxPublicVaultEpochLength() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidState.selector,
        IPublicVault.InvalidStates.EPOCH_TOO_LOW
      )
    );
    _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 0
    });
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidState.selector,
        IPublicVault.InvalidStates.EPOCH_TOO_HIGH
      )
    );
    _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 80 days
    });
  }

  function testFailLienDurationZero() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    ILienToken.Details memory zeroDuration = standardLienDetails;
    zeroDuration.duration = 0;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: zeroDuration,
      amount: 10 ether,
      isFirstLien: true
    });
  }

  function testFailLienRateZero() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    ILienToken.Details memory zeroRate = standardLienDetails;
    zeroRate.rate = 0;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: zeroRate,
      amount: 10 ether,
      isFirstLien: true
    });
  }

  function testFailPayLienAfterLiquidate() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    // uint256[][] memory liens = new uint256[][](1);
    ILienToken.Stack[][] memory stack = new ILienToken.Stack[][](1);
    (, stack[0]) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    vm.warp(block.timestamp + 14 days);

    ASTARIA_ROUTER.liquidate(collateralId, uint8(0), stack[0]);

    _repay(stack[0], 0, 10 ether, address(this));
  }
}
