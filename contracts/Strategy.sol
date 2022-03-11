// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
// Gary's Fork
// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

struct route {
    address from;
    address to;
    bool stable;
}

interface ISolidlyRouter {
    function addLiquidity(
        address,
        address,
        bool,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        uint256
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function getAmountsOut(uint256 amountIn, route[] memory routes)
        external
        view
        returns (uint256[] memory amounts);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function quoteRemoveLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity
    ) external view returns (uint256 amountA, uint256 amountB);
}

// boo:xboo ratios, enter = "Locks Boo and mints xBoo", leave = "Unlocks the staked + gained Boo, and burns xBoo"
interface IAnyWFTM is IERC20 {
    function deposit(uint256) external returns (uint256);

    function withdraw(uint256) external returns (uint256);

    function withdraw() external returns (uint256);

    function deposit() external returns (uint256);
}

interface ITradeFactory {
    function enable(address, address) external;
}

interface ILpDepositer {
    function deposit(address pool, uint256 _amount) external;

    function withdraw(address pool, uint256 _amount) external; // use amount = 0 for harvesting rewards

    function userBalances(address user, address pool)
        external
        view
        returns (uint256);

    function getReward(address[] memory lps) external;
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // swap stuff
    address internal constant solidlyRouter =
        0xa38cd27185a464914D3046f0AB9d43356B34829D;
    bool public tradesEnabled;
    bool public realiseLosses;
    bool public depositerAvoid;
    address public tradeFactory =
        address(0xD3f89C21719Ec5961a3E6B0f9bBf9F9b4180E9e9);

    IERC20 internal constant wftm =
        IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    IAnyWFTM internal constant anyWFTM =
        IAnyWFTM(0x6362496Bef53458b20548a35A2101214Ee2BE3e0);

    IERC20 internal constant sex =
        IERC20(0xD31Fcd1f7Ba190dBc75354046F6024A9b86014d7);
    IERC20 internal constant solid =
        IERC20(0x888EF71766ca594DED1F0FA3AE64eD2941740A20);

    uint256 public lpSlippage = 9995; //0.05% slippage allowance

    uint256 immutable DENOMINATOR = 10_000;

    string internal stratName; // we use this for our strategy's name on cloning
    address public lpToken =
        address(0x9aC7664060a3e388CEB157C5a0B6064BeFFAb9f2);
    ILpDepositer public lpDepositer =
        ILpDepositer(0x26E1A0d851CF28E697870e1b7F053B605C8b060F);

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us
    uint256 public minHarvestCredit; // if we hit this amount of credit, harvest the strategy

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault, string memory _name)
        public
        BaseStrategy(_vault)
    {
        require(vault.token() == address(wftm));
        _initializeStrat(_name);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(string memory _name) internal {
        // initialize variables
        maxReportDelay = 43200; // 1/2 day in seconds, if we hit this then harvestTrigger = True
        healthCheck = address(0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0); // Fantom common health check

        // set our strategy's name
        stratName = _name;

        // turn off our credit harvest trigger to start with
        minHarvestCredit = type(uint256).max;

        // add approvals on all tokens
        IERC20(lpToken).approve(address(lpDepositer), type(uint256).max);
        IERC20(lpToken).approve(address(solidlyRouter), type(uint256).max);
        anyWFTM.approve(address(solidlyRouter), type(uint256).max);
        wftm.approve(address(anyWFTM), type(uint256).max);
        wftm.approve(address(solidlyRouter), type(uint256).max);
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    // balance of boo in strat - should be zero most of the time
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfAnyWftm() public view returns (uint256) {
        return anyWFTM.balanceOf(address(this));
    }

    function balanceOfLPStaked() public view returns (uint256) {
        return lpDepositer.userBalances(address(this), lpToken);
    }

    function balanceOfConstituents(uint256 liquidity)
        public
        view
        returns (uint256 amountWftm, uint256 amountAnyWftm)
    {
        (amountWftm, amountAnyWftm) = ISolidlyRouter(solidlyRouter)
            .quoteRemoveLiquidity(
                address(wftm),
                address(anyWFTM),
                true, //stable pool
                liquidity
            );
    }

    //wftm and anywftm are interchangeable 1-1. so we need our balance of each. added to whatever we can withdraw from lps
    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 lpTokens = balanceOfLPStaked().add(
            IERC20(lpToken).balanceOf(address(this))
        );

        (uint256 amountWftm, uint256 amountAnyWftm) = balanceOfConstituents(
            lpTokens
        );

        return
            amountAnyWftm.add(balanceOfAnyWftm()).add(balanceOfWant()).add(
                amountWftm
            );
    }

    function _setUpTradeFactory() internal {
        //approve and set up trade factory
        address _tradeFactory = tradeFactory;

        ITradeFactory tf = ITradeFactory(_tradeFactory);
        sex.safeApprove(_tradeFactory, type(uint256).max);
        tf.enable(address(sex), address(want));

        solid.safeApprove(_tradeFactory, type(uint256).max);
        tf.enable(address(solid), address(want));
        tradesEnabled = true;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        if (tradesEnabled == false && tradeFactory != address(0)) {
            _setUpTradeFactory();
        }
        // claim our rewards
        address[] memory pairs = new address[](1);
        pairs[0] = address(lpToken);
        lpDepositer.getReward(pairs);

        uint256 assets = estimatedTotalAssets();
        uint256 wantBal = balanceOfWant();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 amountToFree;

        if (assets >= debt) {
            _debtPayment = _debtOutstanding;
            _profit = assets.sub(debt);

            amountToFree = _profit.add(_debtPayment);
        } else {
            //loss should never happen. so leave blank. small potential for IP i suppose. lets not record if so and handle manually
            //dont withdraw either incase we realise losses
            //withdraw with loss
            if (realiseLosses) {
                _loss = debt.sub(assets);
                _debtPayment = _debtOutstanding.sub(_loss);

                amountToFree = _debtPayment;
            }
        }

        //amountToFree > 0 checking (included in the if statement)
        if (wantBal < amountToFree) {
            liquidatePosition(amountToFree);

            uint256 newLoose = want.balanceOf(address(this));

            //if we dont have enough money adjust _debtOutstanding and only change profit if needed
            if (newLoose < amountToFree) {
                if (_profit > newLoose) {
                    _profit = newLoose;
                    _debtPayment = 0;
                } else {
                    _debtPayment = Math.min(newLoose - _profit, _debtPayment);
                }
            }
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // send all of our want tokens to be deposited
        uint256 toInvest = balanceOfWant();
        // stake only if we have something to stake
        // dont bother for less than 0.1 wftm
        if (toInvest > 1e17) {
            //because it is a stable pool, lets check slippage by doing a trade against it. if we can swap 1 wftm for less than slippage we gucci
            route memory ftmToAny = route(
                address(wftm),
                address(anyWFTM),
                true
            );
            route memory anyToWftm = route(
                address(anyWFTM),
                address(wftm),
                true
            );

            uint256 inAmount = 1e18;

            //ftm to any
            route[] memory routes = new route[](1);
            routes[0] = ftmToAny;
            uint256 amountOut = ISolidlyRouter(solidlyRouter).getAmountsOut(
                inAmount,
                routes
            )[1];
            //allow 0.5% slippage by default
            if (amountOut < inAmount.mul(lpSlippage).div(DENOMINATOR)) {
                //dont do anything because we would be lping into the lp at a bad price
                return;
            }

            //any to ftm
            routes[0] = anyToWftm;
            amountOut = ISolidlyRouter(solidlyRouter).getAmountsOut(
                inAmount,
                routes
            )[1];

            if (amountOut < inAmount.mul(lpSlippage).div(DENOMINATOR)) {
                //dont do anything because we would be lping into the lp at a bad price
                return;
            }

            uint256 anyWftmBal = balanceOfAnyWftm();
            if (anyWftmBal > 1e7) {
                //lazy approach. thank you cheap fantom. lets withdraw
                anyWFTM.withdraw();
            }

            //now we get the ratio we need of each token in the lp. this determines how many we need of each
            uint256 wftmB = wftm.balanceOf(lpToken);
            uint256 anyWftmB = anyWFTM.balanceOf(lpToken);

            uint256 wftmBal = balanceOfWant();
            uint256 anyWeNeed = wftmBal.mul(anyWftmB).div(wftmB.add(anyWftmB));

            if (anyWeNeed > 1e7) {
                //we want to mint some anyWftm
                anyWFTM.deposit(anyWeNeed);
            }

            wftmBal = balanceOfWant();
            anyWftmBal = balanceOfAnyWftm();

            if (anyWftmBal > 0 && wftmBal > 0) {
                // deposit into lp
                ISolidlyRouter(solidlyRouter).addLiquidity(
                    address(wftm),
                    address(anyWFTM),
                    true,
                    wftmBal,
                    anyWftmBal,
                    0,
                    0,
                    address(this),
                    2**256 - 1
                );
            }
        }
        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));

        if (lpBalance > 0) {
            //deposit to lp depositer
            lpDepositer.deposit(
                lpToken,
                IERC20(lpToken).balanceOf(address(this))
            );
        }
    }

    //returns lp tokens needed to get that amount of boo
    function wftmToLpTokens(uint256 amountOfWftmWeWant)
        public
        returns (uint256)
    {
        //amount of wftm and anyWftm for 1 lp token
        (uint256 amountWftm, uint256 amountAnyWftm) = balanceOfConstituents(
            1e18
        );

        //1 lp token is this amoubt of boo
        uint256 amountWftmPerLp = amountWftm.add(amountAnyWftm);

        uint256 lpTokensWeNeed = amountOfWftmWeWant.mul(1e18).div(
            amountWftmPerLp
        );

        return lpTokensWeNeed;
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        //if we have loose anyWftm. liquidated it
        uint256 anyWftmBal = balanceOfAnyWftm();
        if (anyWftmBal > 1e7) {
            anyWFTM.withdraw();
        }

        uint256 balanceOfWftm = balanceOfWant();

        // if we need more boo than is already loose in the contract
        if (balanceOfWftm < _amountNeeded) {
            // wftm needed beyond any boo that is already loose in the contract
            uint256 amountToFree = _amountNeeded.sub(balanceOfWftm);

            // converts this amount into lpTokens
            uint256 lpTokensNeeded = wftmToLpTokens(amountToFree);

            uint256 balanceOfLpTokens = IERC20(lpToken).balanceOf(
                address(this)
            );

            if (balanceOfLpTokens < lpTokensNeeded) {
                uint256 toWithdrawfromSolidex = lpTokensNeeded.sub(
                    balanceOfLpTokens
                );

                uint256 staked = balanceOfLPStaked();
                lpDepositer.withdraw(
                    lpToken,
                    Math.min(toWithdrawfromSolidex, staked)
                );

                balanceOfLpTokens = IERC20(lpToken).balanceOf(address(this));
            }

            (uint256 amountWftm, uint256 amountAnyWftm) = ISolidlyRouter(
                solidlyRouter
            ).removeLiquidity(
                    address(wftm),
                    address(anyWFTM),
                    true,
                    Math.min(lpTokensNeeded, balanceOfLpTokens),
                    0,
                    0,
                    address(this),
                    type(uint256).max
                );

            anyWftmBal = balanceOfAnyWftm();
            if (anyWftmBal > 1e7) {
                anyWFTM.withdraw();
            }

            _liquidatedAmount = Math.min(
                want.balanceOf(address(this)),
                _amountNeeded
            );

            if (_liquidatedAmount < _amountNeeded) {
                _loss = _amountNeeded.sub(_liquidatedAmount);
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        lpDepositer.withdraw(lpToken, balanceOfLPStaked());
        ISolidlyRouter(solidlyRouter).removeLiquidity(
            address(wftm),
            address(anyWFTM),
            true,
            IERC20(lpToken).balanceOf(address(this)),
            0,
            0,
            address(this),
            type(uint256).max
        );
        anyWFTM.withdraw();

        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        if (!depositerAvoid) {
            lpDepositer.withdraw(lpToken, balanceOfLPStaked());
        }

        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));

        if (lpBalance > 0) {
            IERC20(lpToken).safeTransfer(_newStrategy, lpBalance);
        }

        uint256 anyWftmBalance = balanceOfAnyWftm();

        if (anyWftmBalance > 0) {
            // send our total balance of xboo to the new strategy
            anyWFTM.transfer(_newStrategy, anyWftmBalance);
        }
    }

    function manualWithdraw(address lp, uint256 amount)
        external
        onlyEmergencyAuthorized
    {
        lpDepositer.withdraw(lp, amount);
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    // our main trigger is regarding our DCA since there is low liquidity for our emissionToken
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        StrategyParams memory params = vault.strategies(address(this));

        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return true;
        }

        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // trigger if we have enough credit
        if (vault.creditAvailable() >= minHarvestCredit) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {}

    function updateTradeFactory(address _newTradeFactory)
        external
        onlyGovernance
    {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        tradeFactory = _newTradeFactory;
        _setUpTradeFactory();
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        address _tradeFactory = tradeFactory;
        sex.safeApprove(_tradeFactory, 0);

        solid.safeApprove(_tradeFactory, 0);

        tradeFactory = address(0);
        tradesEnabled = false;
    }

    /* ========== SETTERS ========== */

    ///@notice This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyEmergencyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    ///@notice When our strategy has this much credit, harvestTrigger will be true.
    function setMinHarvestCredit(uint256 _minHarvestCredit)
        external
        onlyEmergencyAuthorized
    {
        minHarvestCredit = _minHarvestCredit;
    }

    function setRealiseLosses(bool _realiseLoosses) external onlyVaultManagers {
        realiseLosses = _realiseLoosses;
    }

    function setLpSlippage(uint256 _slippage) external onlyEmergencyAuthorized {
        _setLpSlippage(_slippage, false);
    }

    //only vault managers can set high slippage
    function setLpSlippage(uint256 _slippage, bool _force)
        external
        onlyVaultManagers
    {
        _setLpSlippage(_slippage, _force);
    }

    function _setLpSlippage(uint256 _slippage, bool _force) internal {
        require(_slippage <= DENOMINATOR, "higher than max");
        if (!_force) {
            require(_slippage >= 9900, "higher than 1pc slippage set");
        }
        lpSlippage = _slippage;
    }

    function setDepositerAvoid(bool _avoid) external onlyGovernance {
        depositerAvoid = _avoid;
    }
}
