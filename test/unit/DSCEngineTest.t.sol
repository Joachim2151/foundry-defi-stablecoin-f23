// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant STARTING_ERC20BIT_BALANCE = 10 ether;
    uint256 public constant AMOUNT_MINT = 5 ether;

    address LIQUIDATOR = makeAddr("liquidator");

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20BIT_BALANCE);
    }

    //////////////////////
    // Coonstrctor Test //
    /////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////
    // Price Test //
    ///////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/Eth = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ////////////////////////////
    //depositCollateral Tests //
    ///////////////////////////

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        ranToken.mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollateralAndMint() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(AMOUNT_MINT);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        //  20000000000000000000000
        //  10000000000000000000
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    ////////////////
    // Mint Test //
    ///////////////

    function testRevertsIfMintAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintBreaksHealthFactor() public depositedCollateral {
        // USER has 10 WETH deposited = $20,000 collateral
        // Max safe mint = $10,000 DSC (200% collateralization requirement)
        // Minting even 1 wei more than that should break the health factor
        uint256 amountToMint = 10000 ether + 1;

        // Calculate the exact health factor this mint amount would produce,
        // so we can check the revert carries the correct value
        uint256 expectedHealthFactor = (dsce.getUsdValue(weth, AMOUNT_COLLATERAL) * 50 / 100 * 1e18) / amountToMint;

        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        uint256 amountToMint = 10000 ether;

        vm.startPrank(USER);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        // 1. Check DSCEngine's internal accounting updated
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint);

        // 2. Check the user actually holds real DSC tokens now
        assertEq(dsc.balanceOf(USER), amountToMint);
    }
    ////////////////////////////////////////////
    ///// // depositCollateralAndMintDsc Test //
    //////////////////////////////////////////

    function testdepositCollateralMintsDsc() public depositedCollateral {
        // To check if it deposits
        uint256 amountToMint = 10000 ether;

        vm.startPrank(USER);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint);
        assertEq(dsc.balanceOf(USER), amountToMint);

        uint256 expectedCollateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
    }

    function testgetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 actualTotalCollateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedTotalCollateralValueInUsd = 30000 ether;
        assertEq(actualTotalCollateralValue, expectedTotalCollateralValueInUsd);
    }

    function testRevertsIfRedeemAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, STARTING_ERC20_BALANCE);
    }

    function testCanBurnDsc() public depositCollateralAndMint {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_MINT);
        dsce.burnDSC(AMOUNT_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanRedeemCollateralForDsc() public depositCollateralAndMint {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_MINT);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        vm.stopPrank();

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, 0);

        uint256 userWethBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userWethBalance, STARTING_ERC20_BALANCE);
    }

    ////////////////////
    // Liquidate Test //
    ///////////////////

    function testCanLiquidate() public depositCollateralAndMint {
        int256 ethUsdUpdatedPrice = 8e7; // crash weth to $1 // crashed price
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 collateralToCover = 20 ether;

        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateral(weth, collateralToCover);
        dsce.mintDsc(AMOUNT_MINT);
        dsc.approve(address(dsce), AMOUNT_MINT);
        dsce.liquidate(weth, USER, AMOUNT_MINT);
        vm.stopPrank();

        uint256 tokenAmountFromDebtCovered = dsce.getTokenAmountFromUsd(weth, AMOUNT_MINT);
        uint256 bonusCollateral =
            (tokenAmountFromDebtCovered * dsce.getLiquidationBonus()) / dsce.getLiquidationPrecision();
        uint256 expectedWeth = tokenAmountFromDebtCovered + bonusCollateral;

        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        assertEq(liquidatorWethBalance, expectedWeth);
    }
}
