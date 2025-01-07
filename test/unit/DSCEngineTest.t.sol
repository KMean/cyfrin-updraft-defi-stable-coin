//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { Test } from "lib/forge-std/src/Test.sol";
import { DeployDSC } from "script/DeployDSC.s.sol";
import { DecentralizedStableCoin } from "src/DecentralizedStableCoin.sol";
import { DSCEngine } from "src/DSCEngine.sol";
import { HelperConfig } from "script/HelperConfig.s.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC public deployer;
    DecentralizedStableCoin public dsc;
    DSCEngine public engine;
    HelperConfig public config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLenghtDoesntMatchPriceFeedLength() public {
        // Arrange

        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                            PRICE FEEDS TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetTokenAmountFromUsd() public {
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = engine.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30_000e18;
        uint256 usdValue = engine.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    /*//////////////////////////////////////////////////////////////
                            COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfCollateralZero() public {
        // Arrange/Act/Assert
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", USER, 100e18);
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randToken)));
        engine.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        // Arrange

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        // Assert
        uint256 expectedDepositedAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(0, totalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositedAmount);
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            MINTING TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsWhenMintingWithoutCollateral() public {
        vm.startPrank(USER);
        uint256 mintAmount = 1 ether;
        vm.expectRevert(); // Expect health factor to be below threshold
        engine.mintDsc(mintAmount);
        vm.stopPrank();
    }

    function testCanMintDscAfterDepositingCollateral() public depositedCollateral {
        vm.startPrank(USER);
        uint256 mintAmount = 1 ether;
        engine.mintDsc(mintAmount);

        (uint256 totalDscMinted,) = engine.getAccountInformation(USER);
        assertEq(totalDscMinted, mintAmount);
        vm.stopPrank();
    }

    function testRevertsIfMintingExceedsHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        uint256 excessiveMintAmount = 1_000_000 ether;
        vm.expectRevert(); // Expect health factor below threshold
        engine.mintDsc(excessiveMintAmount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfRedeemingMoreThanDeposited() public depositedCollateral {
        vm.startPrank(USER);
        uint256 excessiveRedeemAmount = 20 ether;
        vm.expectRevert();
        engine.redeemCollateral(weth, excessiveRedeemAmount);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        uint256 redeemAmount = 5 ether;
        engine.redeemCollateral(weth, redeemAmount);

        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedRemainingCollateral = AMOUNT_COLLATERAL - redeemAmount;
        assertEq(engine.getTokenAmountFromUsd(weth, collateralValueInUsd), expectedRemainingCollateral);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfLiquidationNotNeeded() public depositedCollateral {
        vm.startPrank(USER);
        uint256 mintAmount = 1 ether;
        engine.mintDsc(mintAmount);
        vm.stopPrank();

        vm.startPrank(makeAddr("liquidator"));
        vm.expectRevert();
        engine.liquidate(weth, USER, mintAmount);
        vm.stopPrank();
    }
}
