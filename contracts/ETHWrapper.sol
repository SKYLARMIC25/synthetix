pragma solidity ^0.5.16;

// Inheritance
import "./Owned.sol";
import "./interfaces/IAddressResolver.sol";
import "./interfaces/ISystemStatus.sol";
import "./interfaces/IETHWrapper.sol";
import "./interfaces/ISynth.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";
import "openzeppelin-solidity-2.3.0/contracts/utils/ReentrancyGuard.sol";

// Internal references
import "./interfaces/IIssuer.sol";
import "./interfaces/IExchangeRates.sol";
import "./interfaces/IFeePool.sol";
import "./MixinResolver.sol";
import "./MixinSystemSettings.sol";

// Libraries
import "openzeppelin-solidity-2.3.0/contracts/math/SafeMath.sol";
import "./SafeDecimalMath.sol";
import "hardhat/console.sol";

// MixinSystemSettings
// Pausable
contract ETHWrapper is Owned, MixinResolver, ReentrancyGuard, IETHWrapper {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /* ========== CONSTANTS ============== */
    
    /* ========== ENCODED NAMES ========== */

    bytes32 internal constant sUSD = "sUSD";
    bytes32 internal constant sETH = "sETH";
    bytes32 internal constant ETH = "ETH";
    bytes32 internal constant SNX = "SNX";

    // Flexible storage names
    bytes32 public constant CONTRACT_NAME = "ETHWrapper";
    bytes32 internal constant MAX_ETH = "maxETH";
    bytes32 internal constant MINT_FEE_RATE = "mintFeeRate";
    bytes32 internal constant BURN_FEE_RATE = "burnFeeRate";

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */
    bytes32 private constant CONTRACT_SYNTHETIX = "Synthetix";
    bytes32 private constant CONTRACT_SYSTEMSTATUS = "SystemStatus";
    bytes32 private constant CONTRACT_SYNTHSETH = "SynthsETH";
    bytes32 private constant CONTRACT_SYNTHSUSD = "SynthsUSD";
    bytes32 private constant CONTRACT_ISSUER = "Issuer";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_FEEPOOL = "FeePool";

    // ========== STATE VARIABLES ==========
    IWETH public weth;
    
    mapping(address => uint) public pendingWithdrawals;
    
    // The maximum amount of ETH held by contract.
    uint public maxETH = 5000 ether;

    // The "controlled" ETH balance of the contract.
    // Note: we keep track of this in contract state, rather than using address(this).balance,
    // as there are ways to move Ether without creating a message call, which would allow
    // someone to DoS the contract. 
    uint private _balance = 0 ether;

    // The fee for depositing ETH into the contract. Default 50 bps.
    uint public mintFeeRate = (5 * SafeDecimalMath.unit()) / 1000;

    // The fee for burning sETH and releasing ETH from the contract. Default 50 bps.
    uint public burnFeeRate = (5 * SafeDecimalMath.unit()) / 1000;

    constructor(address _owner, address _resolver, address payable _WETH) public Owned(_owner) MixinResolver(_resolver) {
        weth = IWETH(_WETH);
    }

    /* ========== VIEWS ========== */
    function resolverAddressesRequired() public view returns (bytes32[] memory addresses) {
        bytes32[] memory addresses = new bytes32[](6);
        addresses[0] = CONTRACT_SYSTEMSTATUS;
        addresses[1] = CONTRACT_SYNTHSETH;
        addresses[2] = CONTRACT_SYNTHSUSD;
        addresses[3] = CONTRACT_EXRATES;
        addresses[4] = CONTRACT_ISSUER;
        addresses[5] = CONTRACT_FEEPOOL;
        return addresses;
    }

    /* ========== INTERNAL VIEWS ========== */

    function systemStatus() internal view returns (ISystemStatus) {
        return ISystemStatus(requireAndGetAddress(CONTRACT_SYSTEMSTATUS));
    }
    

    function synthsUSD() internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(CONTRACT_SYNTHSUSD));
    }

    function synthsETH() internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(CONTRACT_SYNTHSETH));
    }

    function feePool() internal view returns (IFeePool) {
        return IFeePool(requireAndGetAddress(CONTRACT_FEEPOOL));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXRATES));
    }

    function issuer() internal view returns (IIssuer) {
        return IIssuer(requireAndGetAddress(CONTRACT_ISSUER));
    }

    /* ========== PUBLIC FUNCTIONS ========== */


    // ========== VIEWS ==========

    function capacity() public view returns (uint) {
        return _balance >= maxETH ? 0 : maxETH.sub(_balance);
    }

    function getBalance() public view returns (uint) {
        return _balance;
    }

    function calculateMintFee(uint amount) public view returns (uint) {
        return amount.multiplyDecimalRound(mintFeeRate);
    }

    function calculateBurnFee(uint amount) public view returns (uint) {
        return amount.multiplyDecimalRound(burnFeeRate);
    }

    // function maxETH() public view returns (uint256) {
    //     // return flexibleStorage().getUIntValue(CONTRACT_NAME, MAX_ETH);
    // }

    // function mintFeeRate() public view returns (uint256) {
    //     // return flexibleStorage().getUIntValue(CONTRACT_NAME, MINT_FEE_RATE);
    // }

    // function burnFeeRate() public view returns (uint256) {
    //     // return flexibleStorage().getUIntValue(CONTRACT_NAME, BURN_FEE_RATE);
    // }
    
    /* ========== MUTATIVE FUNCTIONS ========== */

    function mint() external payable {
        uint capacity = capacity();
        require(capacity > 0, "Contract has no spare capacity to mint");
        
        if(msg.value >= capacity) {
            _mint(capacity);
            // Refund remainder.
            msg.sender.transfer(msg.value.sub(capacity));
        } else {
            _mint(msg.value);
        }
    }

    // Burn `amount` sETH for `amount - fees` ETH.
    function burn(uint amount) external {
        uint reserves = getBalance();
        require(reserves > 0, "Contract cannot burn sETH for ETH, ETH balance is zero");

        uint burnFee = calculateBurnFee(amount);
        
        if(amount >= reserves) {
            _burn(reserves);
            // Refund is not needed, as we transfer the exact amount of reserves.
        } else {
            _burn(amount);
        }
    }

    // ========== RESTRICTED ==========

    function setMaxETH(uint _maxETH) external onlyOwner {
        // flexibleStorage().setUIntValue(CONTRACT_NAME, MAX_ETH, _maxETH);

        // If we set the _newMaxETH to be lower than the current maxETH,
        // then the perms are (mint=0, burn=1).
        // Else if it is higher,
        // then the perms are (mint=1, burn=1)
        maxETH = _maxETH;
        emit MaxETHUpdated(_maxETH);
    }

    function setMintFeeRate(uint _rate) external onlyOwner {
        // flexibleStorage().setUIntValue(CONTRACT_NAME, MINT_FEE_RATE, _rate);
        mintFeeRate = _rate;
        emit MintFeeRateUpdated(_rate);
    }

    function setBurnFeeRate(uint _rate) external onlyOwner {
        // flexibleStorage().setUIntValue(CONTRACT_NAME, BURN_FEE_RATE, _rate);
        burnFeeRate = _rate;
        emit BurnFeeRateUpdated(_rate);
    }

    /**
     * @notice Fallback function
     */
    function() external payable {
        revert("Fallback disabled, use mint()");
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _mint(uint depositAmountEth) internal {
        // Calculate minting fee.
        uint feeAmountEth = calculateMintFee(depositAmountEth);

        // Fee Distribution. Mints sUSD internally.
        // Normalize fee to sUSD
        uint feeSusd = exchangeRates().effectiveValue(ETH, feeAmountEth, sUSD);

        // Remit the fee in sUSDs
        issuer().synths(sUSD).issue(feePool().FEE_ADDRESS(), feeSusd);

        // Tell the fee pool about this
        feePool().recordFeePaid(feeSusd);

        // Finally, issue sETH.
        synthsETH().issue(msg.sender, depositAmountEth.sub(feeAmountEth));

        // Update contract balance, and hence capacity.
        _balance = _balance.add(depositAmountEth.sub(feeAmountEth));
    }

    function _burn(uint amount) internal {
        require(amount <= IERC20(address(synthsETH())).allowance(msg.sender, address(this)), "Allowance not high enough");
        require(amount <= IERC20(address(synthsETH())).balanceOf(msg.sender), "Balance is too low");

        // Burn the full amount sent.
        synthsETH().burn(msg.sender, amount);

        // Calculate burning fee.
        uint feeAmountEth = calculateBurnFee(amount);

        // Fee Distribution. Mints sUSD internally.
        // Normalize fee to sUSD
        uint feeSusd = exchangeRates().effectiveValue(ETH, feeAmountEth, sUSD);

        // Remit the fee in sUSDs
        issuer().synths(sUSD).issue(feePool().FEE_ADDRESS(), feeSusd);

        // Tell the fee pool about this
        feePool().recordFeePaid(feeSusd);        

        // Finally, allow the sender to withdraw their ETH, less the fee.
        pendingWithdrawals[msg.sender] = pendingWithdrawals[msg.sender].add(amount.sub(feeAmountEth));
    }

    function withdraw(uint amount) external nonReentrant {
        // If they try to withdraw more than their total balance, it will fail on the safe sub.
        pendingWithdrawals[msg.sender] = pendingWithdrawals[msg.sender].sub(amount);

        // Update internally tracked ETH balance.
        _balance = _balance.sub(amount);

        (bool success, ) = msg.sender.call.value(amount)("");
        require(success, "Transfer failed");
    }


    /* ========== EVENTS ========== */
    event MaxETHUpdated(uint rate);
    event MintFeeRateUpdated(uint rate);
    event BurnFeeRateUpdated(uint rate);
}