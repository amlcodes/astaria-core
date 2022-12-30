//// SPDX-License-Identifier: UNLICENSED
//
///**
// *       __  ___       __
// *  /\  /__'  |   /\  |__) |  /\
// * /~~\ .__/  |  /~~\ |  \ | /~~\
// *
// * Copyright (c) Astaria Labs, Inc
// */
//
//pragma solidity =0.8.17;
//
//import {ERC721} from "solmate/tokens/ERC721.sol";
//
//import {CollateralLookup} from "core/libraries/CollateralLookup.sol";
//import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
//import {ILienToken} from "core/interfaces/ILienToken.sol";
//import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";
//import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
//
//interface IDYAD {
//  struct Nft {
//    uint256 withdrawn; // dyad withdrawn from the pool deposit
//    int256 deposit; // dyad balance in pool
//    uint256 xp; // always positive, always inflationary
//    bool isLiquidatable;
//  }
//
//  function idToNft(uint256 id) external view returns (Nft memory);
//}
//
//interface IDYADValidator is IStrategyValidator {
//  struct Details {
//    uint8 version;
//    address token;
//    uint256 collateralDeposited;
//    uint256 minDyadDeposited;
//    uint256 maxDyadWithdrawn;
//    uint256 minXp;
//    ILienToken.Details lien;
//  }
//}
//
//contract DYADValidator is IDYADValidator {
//  using CollateralLookup for address;
//  using FixedPointMathLib for uint256;
//
//  uint8 public constant VERSION_TYPE = uint8(5);
//
//  function validateAndParse(
//    IAstariaRouter.NewLienRequest calldata params,
//    address borrower,
//    address collateralTokenContract,
//    uint256 collateralTokenId
//  ) external view override returns (bytes32, ILienToken.Details memory) {
//    IDYADValidator.Details memory details = abi.decode(
//      params.details,
//      (Details)
//    );
//    require(details.version == VERSION_TYPE, "InvalidVersion");
//    require(details.token == collateralTokenContract, "InvalidCollateral");
//    Nft memory nft = IDYAD(details.token).idToNft(collateralTokenId);
//
//    require(
//      nft.deposit - nft.withdrawn >= details.minDyadDeposited,
//      "InvalidMinDyadDeposited"
//    );
//    require(
//      nft.withdrawn <= details.maxDyadWithdrawn,
//      "InvalidMaxDyadWithdrawn"
//    );
//    require(nft.xp >= details.minXp, "InvalidMinXp");
//
//    require(!nft.isLiquidatable, "InvalidIsLiquidatable");
//
//    return (keccak256(abi.encode(params.nlrDetails)), details.lien);
//  }
//}
