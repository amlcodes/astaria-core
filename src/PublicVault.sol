// SPDX-License-Identifier: BUSL-1.1

/**                                                     
*  █████╗ ███████╗████████╗ █████╗ ██████╗ ██╗ █████╗ 
* ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██║██╔══██╗
* ███████║███████╗   ██║   ███████║██████╔╝██║███████║
* ██╔══██║╚════██║   ██║   ██╔══██║██╔══██╗██║██╔══██║
* ██║  ██║███████║   ██║   ██║  ██║██║  ██║██║██║  ██║
* ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
*
* Astaria Labs, Inc
*/

pragma solidity =0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {IERC165} from "core/interfaces/IERC165.sol";
import {ERC4626Cloned} from "gpl/ERC4626-Cloned.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {IERC20} from "core/interfaces/IERC20.sol";
import {IERC20Metadata} from "core/interfaces/IERC20Metadata.sol";
import {ERC20Cloned} from "gpl/ERC20-Cloned.sol";
import {
  ClonesWithImmutableArgs
} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

import {VaultImplementation} from "core/VaultImplementation.sol";
import {WithdrawProxy} from "core/WithdrawProxy.sol";

import {Math} from "core/utils/Math.sol";
import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {IAstariaVaultBase} from "core/interfaces/IAstariaVaultBase.sol";
import {AstariaVaultBase} from "core/AstariaVaultBase.sol";

/*
 * @title PublicVault
 * @author androolloyd
 * @notice
 */
contract PublicVault is VaultImplementation, IPublicVault, ERC4626Cloned {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;

  uint256 private constant PUBLIC_VAULT_SLOT =
    uint256(keccak256("xyz.astaria.PublicVault.storage.location")) - 1;

  function asset()
    public
    pure
    virtual
    override(IAstariaVaultBase, AstariaVaultBase, ERC4626Cloned)
    returns (address)
  {
    return super.asset();
  }

  function decimals()
    public
    pure
    virtual
    override(IERC20Metadata)
    returns (uint8)
  {
    return 18;
  }

  function name()
    public
    view
    virtual
    override(IERC20Metadata, VaultImplementation)
    returns (string memory)
  {
    return string(abi.encodePacked("AST-Vault-", ERC20(asset()).symbol()));
  }

  function symbol()
    public
    view
    virtual
    override(IERC20Metadata, VaultImplementation)
    returns (string memory)
  {
    return string(abi.encodePacked("AST-V-", ERC20(asset()).symbol()));
  }

  function minDepositAmount()
    public
    view
    virtual
    override(ERC4626Cloned)
    returns (uint256)
  {
    if (ERC20(asset()).decimals() == uint8(18)) {
      return 100 gwei;
    } else {
      return 10**(ERC20(asset()).decimals() - 1);
    }
  }

  /**
   * @notice Signal a withdrawal of funds (redeeming for underlying asset) in the next epoch.
   * @param shares The number of VaultToken shares to redeem.
   * @param receiver The receiver of the WithdrawTokens (and eventual underlying asset)
   * @param owner The owner of the VaultTokens.
   * @return assets The amount of the underlying asset redeemed.
   */
  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public virtual override(ERC4626Cloned) returns (uint256 assets) {
    VaultData storage s = _loadStorageSlot();
    assets = _redeemFutureEpoch(s, shares, receiver, owner, s.currentEpoch);
  }

  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public virtual override(ERC4626Cloned) returns (uint256 shares) {
    shares = previewWithdraw(assets);

    VaultData storage s = _loadStorageSlot();

    _redeemFutureEpoch(s, shares, receiver, owner, s.currentEpoch);
  }

  function redeemFutureEpoch(
    uint256 shares,
    address receiver,
    address owner,
    uint64 epoch
  ) public virtual returns (uint256 assets) {
    return
      _redeemFutureEpoch(_loadStorageSlot(), shares, receiver, owner, epoch);
  }

  function _redeemFutureEpoch(
    VaultData storage s,
    uint256 shares,
    address receiver,
    address owner,
    uint64 epoch
  ) internal virtual returns (uint256 assets) {
    // check to ensure that the requested epoch is not in the past

    ERC20Data storage es = _loadERC20Slot();

    if (msg.sender != owner) {
      uint256 allowed = es.allowance[owner][msg.sender]; // Saves gas for limited approvals.

      if (allowed != type(uint256).max) {
        es.allowance[owner][msg.sender] = allowed - shares;
      }
    }

    if (epoch < s.currentEpoch) {
      revert InvalidState(InvalidStates.EPOCH_TOO_LOW);
    }
    require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");
    // check for rounding error since we round down in previewRedeem.

    //this will underflow if not enough balance
    es.balanceOf[owner] -= shares;

    // Cannot overflow because the sum of all user
    // balances can't exceed the max uint256 value.
    unchecked {
      es.balanceOf[address(this)] += shares;
    }

    emit Transfer(owner, address(this), shares);
    // Deploy WithdrawProxy if no WithdrawProxy exists for the specified epoch
    _deployWithdrawProxyIfNotDeployed(s, epoch);

    emit Withdraw(msg.sender, receiver, owner, assets, shares);

    // WithdrawProxy shares are minted 1:1 with PublicVault shares
    WithdrawProxy(s.epochData[epoch].withdrawProxy).mint(shares, receiver);
  }

  function getWithdrawProxy(uint64 epoch) public view returns (WithdrawProxy) {
    return WithdrawProxy(_loadStorageSlot().epochData[epoch].withdrawProxy);
  }

  function getCurrentEpoch() public view returns (uint64) {
    return _loadStorageSlot().currentEpoch;
  }

  function getSlope() public view returns (uint256) {
    return uint256(_loadStorageSlot().slope);
  }

  function getWithdrawReserve() public view returns (uint256) {
    return uint256(_loadStorageSlot().withdrawReserve);
  }

  function getLiquidationWithdrawRatio() public view returns (uint256) {
    return uint256(_loadStorageSlot().liquidationWithdrawRatio);
  }

  function getYIntercept() public view returns (uint256) {
    return uint256(_loadStorageSlot().yIntercept);
  }

  function _deployWithdrawProxyIfNotDeployed(VaultData storage s, uint64 epoch)
    internal
  {
    if (s.epochData[epoch].withdrawProxy == address(0)) {
      s.epochData[epoch].withdrawProxy = ClonesWithImmutableArgs.clone(
        IAstariaRouter(ROUTER()).BEACON_PROXY_IMPLEMENTATION(),
        abi.encodePacked(
          address(ROUTER()), // router is the beacon
          uint8(IAstariaRouter.ImplementationType.WithdrawProxy),
          asset(), // token
          address(this), // vault
          epoch + 1 // claimable epoch
        )
      );
    }
  }

  function mint(uint256 shares, address receiver)
    public
    override(ERC4626Cloned)
    whenNotPaused
    returns (uint256)
  {
    VIData storage s = _loadVISlot();
    if (s.allowListEnabled) {
      require(s.allowList[receiver]);
    }
    return super.mint(shares, receiver);
  }

  /**
   * @notice Deposit funds into the PublicVault.
   * @param amount The amount of funds to deposit.
   * @param receiver The receiver of the resulting VaultToken shares.
   */
  function deposit(uint256 amount, address receiver)
    public
    override(ERC4626Cloned)
    whenNotPaused
    returns (uint256)
  {
    VIData storage s = _loadVISlot();
    if (s.allowListEnabled) {
      require(s.allowList[receiver]);
    }

    uint256 assets = totalAssets();

    return super.deposit(amount, receiver);
  }

  /**
   * @notice Retrieve the domain separator.
   * @return The domain separator.
   */
  function computeDomainSeparator() internal view override returns (bytes32) {
    return super.domainSeparator();
  }

  function processEpoch() public {
    // check to make sure epoch is over
    if (timeToEpochEnd() > 0) {
      revert InvalidState(InvalidStates.EPOCH_NOT_OVER);
    }
    VaultData storage s = _loadStorageSlot();

    if (s.withdrawReserve > 0) {
      revert InvalidState(InvalidStates.WITHDRAW_RESERVE_NOT_ZERO);
    }

    WithdrawProxy currentWithdrawProxy = WithdrawProxy(
      s.epochData[s.currentEpoch].withdrawProxy
    );

    // split funds from previous WithdrawProxy with PublicVault if hasn't been already
    if (s.currentEpoch != 0) {
      WithdrawProxy previousWithdrawProxy = WithdrawProxy(
        s.epochData[s.currentEpoch - 1].withdrawProxy
      );
      if (
        address(previousWithdrawProxy) != address(0) &&
        previousWithdrawProxy.getFinalAuctionEnd() != 0
      ) {
        previousWithdrawProxy.claim();
      }
    }

    if (s.epochData[s.currentEpoch].liensOpenForEpoch > 0) {
      revert InvalidState(InvalidStates.LIENS_OPEN_FOR_EPOCH_NOT_ZERO);
    }

    // reset liquidationWithdrawRatio to prepare for re calcualtion
    s.liquidationWithdrawRatio = 0;

    // check if there are LPs withdrawing this epoch
    if ((address(currentWithdrawProxy) != address(0))) {
      uint256 proxySupply = currentWithdrawProxy.totalSupply();

      s.liquidationWithdrawRatio = proxySupply
        .mulDivDown(1e18, totalSupply())
        .safeCastTo88();

      currentWithdrawProxy.setWithdrawRatio(s.liquidationWithdrawRatio);
      uint256 expected = currentWithdrawProxy.getExpected();

      unchecked {
        if (totalAssets() > expected) {
          s.withdrawReserve = (totalAssets() - expected)
            .mulWadDown(s.liquidationWithdrawRatio)
            .safeCastTo88();
        } else {
          s.withdrawReserve = 0;
        }
      }
      _setYIntercept(
        s,
        s.yIntercept -
          totalAssets().mulDivDown(s.liquidationWithdrawRatio, 1e18)
      );
      // burn the tokens of the LPs withdrawing
      _burn(address(this), proxySupply);
    }

    // increment epoch
    unchecked {
      s.currentEpoch++;
    }
  }

  function supportsInterface(bytes4 interfaceId)
    public
    pure
    override(IERC165)
    returns (bool)
  {
    return
      interfaceId == type(IPublicVault).interfaceId ||
      interfaceId == type(ERC4626Cloned).interfaceId ||
      interfaceId == type(ERC4626).interfaceId ||
      interfaceId == type(ERC20).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  function transferWithdrawReserve() public {
    VaultData storage s = _loadStorageSlot();

    if (s.currentEpoch == uint64(0)) {
      return;
    }

    address currentWithdrawProxy = s
      .epochData[s.currentEpoch - 1]
      .withdrawProxy;
    // prevents transfer to a non-existent WithdrawProxy
    // withdrawProxies are indexed by the epoch where they're deployed
    if (currentWithdrawProxy != address(0)) {
      uint256 withdrawBalance = ERC20(asset()).balanceOf(address(this));

        // prevent transfer of more assets then are available
        if (s.withdrawReserve <= withdrawBalance) {
          withdrawBalance = s.withdrawReserve;
          s.withdrawReserve = 0;
        } else {
          unchecked {
            s.withdrawReserve -= withdrawBalance.safeCastTo88();
          }
        }

      ERC20(asset()).safeTransfer(currentWithdrawProxy, withdrawBalance);
      WithdrawProxy(currentWithdrawProxy).increaseWithdrawReserveReceived(
        withdrawBalance
      );
      emit WithdrawReserveTransferred(withdrawBalance);
    }

    address withdrawProxy = s.epochData[s.currentEpoch].withdrawProxy;
    if (
      s.withdrawReserve > 0 &&
      timeToEpochEnd() == 0 &&
      withdrawProxy != address(0)
    ) {
      address currentWithdrawProxy = s
        .epochData[s.currentEpoch - 1]
        .withdrawProxy;
      uint256 drainBalance = WithdrawProxy(withdrawProxy)
        .drain(
          s.withdrawReserve,
          s.epochData[s.currentEpoch - 1].withdrawProxy
        );
      unchecked {

        s.withdrawReserve -= drainBalance.safeCastTo88();
      }
      WithdrawProxy(currentWithdrawProxy).increaseWithdrawReserveReceived(
          drainBalance
        );
    }
  }

  function _beforeCommitToLien(IAstariaRouter.Commitment calldata params)
    internal
    virtual
    override(VaultImplementation)
  {
    VaultData storage s = _loadStorageSlot();

    if (s.withdrawReserve > uint256(0)) {
      transferWithdrawReserve();
    }
    if (timeToEpochEnd() == uint256(0)) {
      processEpoch();
    }
  }

  function _loadStorageSlot() internal pure returns (VaultData storage s) {
    uint256 slot = PUBLIC_VAULT_SLOT;
    assembly {
      s.slot := slot
    }
  }

  /**
   * @dev Hook for updating the slope of the PublicVault after a LienToken is issued.
   * @param lienId The ID of the lien.
   */
  function _afterCommitToLien(
    uint40 lienEnd,
    uint256 lienId,
    uint256 lienSlope
  ) internal virtual override {
    VaultData storage s = _loadStorageSlot();

    // increment slope for the new lien
    _accrue(s);
    unchecked {
      uint48 newSlope = s.slope + lienSlope.safeCastTo48();
      _setSlope(s, newSlope);
    }

    uint64 epoch = getLienEpoch(lienEnd);

    _increaseOpenLiens(s, epoch);
    emit LienOpen(lienId, epoch);
  }

  event SlopeUpdated(uint48 newSlope);

  function accrue() public returns (uint256) {
    return _accrue(_loadStorageSlot());
  }

  function _accrue(VaultData storage s) internal returns (uint256) {
    unchecked {
      s.yIntercept = (_totalAssets(s)).safeCastTo88();
      s.last = block.timestamp.safeCastTo40();
    }
    emit YInterceptChanged(s.yIntercept);

    return s.yIntercept;
  }

  /**
   * @notice Computes the implied value of this PublicVault. This includes interest payments that have not yet been made.
   * @return The implied value for this PublicVault.
   */
  function totalAssets()
    public
    view
    virtual
    override(ERC4626Cloned)
    returns (uint256)
  {
    VaultData storage s = _loadStorageSlot();
    return _totalAssets(s);
  }

  function _totalAssets(VaultData storage s) internal view returns (uint256) {
    uint256 delta_t = block.timestamp - s.last;
    return uint256(s.slope).mulDivDown(delta_t, 1) + uint256(s.yIntercept);
  }

  function totalSupply()
    public
    view
    virtual
    override(IERC20, ERC20Cloned)
    returns (uint256)
  {
    return
      _loadERC20Slot()._totalSupply +
      _loadStorageSlot().strategistUnclaimedShares;
  }

  function claim() external {
    require(msg.sender == owner()); //owner is "strategist"
    VaultData storage s = _loadStorageSlot();
    uint256 unclaimed = s.strategistUnclaimedShares;
    s.strategistUnclaimedShares = 0;
    _mint(msg.sender, unclaimed);
  }

  function beforePayment(BeforePaymentParams calldata params)
    external
    onlyLienToken
  {
    VaultData storage s = _loadStorageSlot();
    _accrue(s);

    unchecked {
      uint48 newSlope = s.slope - params.lienSlope.safeCastTo48();
      _setSlope(s, newSlope);
    }
    _handleStrategistInterestReward(s, params.interestOwed, params.amount);
  }

  function _setSlope(VaultData storage s, uint48 newSlope) internal {
    s.slope = newSlope;
    emit SlopeUpdated(newSlope);
  }

  function decreaseEpochLienCount(uint64 epoch) public onlyLienToken {
    _decreaseEpochLienCount(_loadStorageSlot(), epoch);
  }

  function _decreaseEpochLienCount(VaultData storage s, uint64 epoch) internal {
    s.epochData[epoch].liensOpenForEpoch--;
    emit LiensOpenForEpochRemaining(
      epoch,
      s.epochData[epoch].liensOpenForEpoch
    );
  }

  function getLienEpoch(uint64 end) public pure returns (uint64) {
    return
      uint256(Math.ceilDiv(end - uint64(START()), EPOCH_LENGTH()) - 1)
        .safeCastTo64();
  }

  function getEpochEnd(uint256 epoch) public pure returns (uint64) {
    return uint256(START() + (epoch + 1) * EPOCH_LENGTH()).safeCastTo64();
  }

  function _increaseOpenLiens(VaultData storage s, uint64 epoch) internal {
    unchecked {
      s.epochData[epoch].liensOpenForEpoch++;
    }
  }

  function afterPayment(uint256 computedSlope) public onlyLienToken {
    VaultData storage s = _loadStorageSlot();
    unchecked {
      s.slope += computedSlope.safeCastTo48();
    }
    emit SlopeUpdated(s.slope);
  }

  /**
   * @notice After-deposit hook to update the yIntercept of the PublicVault to reflect a capital contribution.
   * @param assets The amount of assets deposited to the PublicVault.
   * @param shares The resulting amount of VaultToken shares that were issued.
   */
  function afterDeposit(uint256 assets, uint256 shares)
    internal
    virtual
    override
  {
    VaultData storage s = _loadStorageSlot();

    unchecked {
      s.yIntercept += assets.safeCastTo88();
    }
    VIData storage v = _loadVISlot();
    if (v.depositCap != 0 && totalAssets() >= v.depositCap) {
      revert InvalidState(InvalidStates.DEPOSIT_CAP_EXCEEDED);
    }
    emit YInterceptChanged(s.yIntercept);
  }

  /**
   * @dev Handles the dilutive fees (on lien repayments) for strategists in VaultTokens.
   * @param interestOwing the owingInterest for the lien
   * @param amount The amount that was paid.
   */
  function _handleStrategistInterestReward(
    VaultData storage s,
    uint256 interestOwing,
    uint256 amount
  ) internal virtual {
    if (VAULT_FEE() != uint256(0)) {
      uint256 x = (amount > interestOwing) ? interestOwing : amount;
      uint256 fee = x.mulDivDown(VAULT_FEE(), 10000);
      uint88 feeInShares = convertToShares(fee).safeCastTo88();
      s.strategistUnclaimedShares += feeInShares;
      emit StrategistFee(feeInShares);
    }
  }

  function LIEN_TOKEN() public view returns (ILienToken) {
    return ROUTER().LIEN_TOKEN();
  }

  function handleBuyoutLien(BuyoutLienParams calldata params)
    public
    onlyLienToken
  {
    VaultData storage s = _loadStorageSlot();

    unchecked {
      uint48 newSlope = s.slope - params.lienSlope.safeCastTo48();
      _setSlope(s, newSlope);
      s.yIntercept += params.increaseYIntercept.safeCastTo88();
      s.last = block.timestamp.safeCastTo40();
    }

    _decreaseEpochLienCount(s, getLienEpoch(params.lienEnd.safeCastTo64()));
    emit YInterceptChanged(s.yIntercept);
  }

  function updateAfterLiquidationPayment(
    LiquidationPaymentParams calldata params
  ) external onlyLienToken {
    VaultData storage s = _loadStorageSlot();
    if (params.remaining > 0) _setYIntercept(s, s.yIntercept - params.remaining);
  }

  function updateVaultAfterLiquidation(
    uint256 maxAuctionWindow,
    AfterLiquidationParams calldata params
  ) public onlyLienToken returns (address withdrawProxyIfNearBoundary) {
    VaultData storage s = _loadStorageSlot();

    _accrue(s);
    unchecked {
      _setSlope(s, s.slope - params.lienSlope.safeCastTo48());
    }

    if (s.currentEpoch != 0) {
      transferWithdrawReserve();
    }
    uint64 lienEpoch = getLienEpoch(params.lienEnd);
    _decreaseEpochLienCount(s, lienEpoch);

    uint256 timeToEnd = timeToEpochEnd(lienEpoch);
    if (timeToEnd < maxAuctionWindow) {
      _deployWithdrawProxyIfNotDeployed(s, lienEpoch);
      withdrawProxyIfNearBoundary = s.epochData[lienEpoch].withdrawProxy;

      WithdrawProxy(withdrawProxyIfNearBoundary).handleNewLiquidation(
        params.newAmount,
        maxAuctionWindow
      );
    }
  }

  function increaseYIntercept(uint256 amount) public {
    VaultData storage s = _loadStorageSlot();
    uint64 currentEpoch = s.currentEpoch;
    require(
      currentEpoch != 0 &&
        msg.sender == s.epochData[currentEpoch - 1].withdrawProxy
    );
    _setYIntercept(s, s.yIntercept + amount);
  }

  modifier onlyLienToken() {
    require(msg.sender == address(LIEN_TOKEN()));
    _;
  }

  function decreaseYIntercept(uint256 amount) public {
    VaultData storage s = _loadStorageSlot();
    uint64 currentEpoch = s.currentEpoch;
    require(
      currentEpoch != 0 &&
        msg.sender == s.epochData[currentEpoch - 1].withdrawProxy
    );
    _setYIntercept(s, s.yIntercept - amount);
  }

  function _setYIntercept(VaultData storage s, uint256 newYIntercept) internal {
    s.yIntercept = newYIntercept.safeCastTo88();
    emit YInterceptChanged(s.yIntercept);
  }

  function timeToEpochEnd() public view returns (uint256) {
    return timeToEpochEnd(_loadStorageSlot().currentEpoch);
  }

  function timeToEpochEnd(uint256 epoch) public view returns (uint256) {
    uint256 epochEnd = START() + ((epoch + 1) * EPOCH_LENGTH());

    if (block.timestamp >= epochEnd) {
      return uint256(0);
    }

    return epochEnd - block.timestamp;
  }

  function _timeToSecondEndIfPublic()
    internal
    view
    override
    returns (uint256 timeToSecondEpochEnd)
  {
    return timeToEpochEnd() + EPOCH_LENGTH();
  }

  function timeToSecondEpochEnd() public view returns (uint256) {
    return _timeToSecondEndIfPublic();
  }
}
