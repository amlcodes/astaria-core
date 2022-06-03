pragma solidity ^0.8.13;
pragma experimental ABIEncoderV2;

interface IAuctionHouse {
    function createAuction(
        uint256 tokenId,
        uint256 duration,
        uint256 reservePrice
    ) external returns (uint256);

    function createBid(uint256 auctionId, uint256 amount) external payable;

    function endAuction(uint256 auctionId) external returns (address);

    function cancelAuction(uint256 auctionId) external;

    function getAuctionData(uint256 _auctionId)
        external
        returns (
            uint256 tokenId,
            uint256 amount,
            uint256 duration,
            uint256 firstBidTime,
            uint256 reservePrice,
            address payable bidder,
            bytes32 bondVault
        );
}