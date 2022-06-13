pragma solidity ^0.8.0;
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IBrokerRouter} from "../BrokerRouter.sol";

interface ILienToken is IERC721 {
    struct Lien {
        uint256 amount;
        uint32 last;
        uint32 start;
        uint32 rate;
        uint32 buyout;
        uint32 duration;
        bool active;
        bytes32 root;
    }

    struct LienActionEncumber {
        IBrokerRouter.Terms terms;
        uint256 amount;
    }
    struct LienActionBuyout {
        IBrokerRouter.Terms incoming;
        address receiver;
    }

    function stopLiens(uint256 collateralVault)
        external
        returns (
            uint256 reserve,
            uint256[] memory amounts,
            uint256[] memory lienIds
        );

    function getBuyout(uint256 collateralVault, uint256 index)
        external
        view
        returns (uint256, uint256);

    function removeLiens(uint256 collateralVault) external;

    function getInterest(uint256 collateralVault, uint256 position)
        external
        view
        returns (uint256);

    function getLiens(uint256 _starId) external view returns (uint256[] memory);

    function getLien(uint256 lienId) external view returns (Lien memory);

    function getLien(uint256 collateralVault, uint256 position)
        external
        view
        returns (Lien memory);

    function createLien(LienActionEncumber calldata params)
        external
        returns (uint256 lienId);

    function buyoutLien(LienActionBuyout calldata params) external;

    function validateTerms(IBrokerRouter.Terms memory params)
        external
        view
        returns (bool);

    function validateTerms(
        bytes32[] memory proof,
        uint256 collateralVault,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 duration,
        uint256 position,
        uint256 schedule
    ) external view returns (bool);
}