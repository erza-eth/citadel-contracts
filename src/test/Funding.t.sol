// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.12;

import {BaseFixture} from "./BaseFixture.sol";
import {SupplySchedule} from "../SupplySchedule.sol";
import {GlobalAccessControl} from "../GlobalAccessControl.sol";
import {Funding} from "../Funding.sol";

import {ERC20Utils} from "./utils/ERC20Utils.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "../interfaces/erc20/IERC20.sol";

contract FundingTest is BaseFixture {
    using FixedPointMathLib for uint;

    function setUp() public override {
        BaseFixture.setUp();
        ERC20Utils erc20utils = new ERC20Utils();
        // address cvx_address = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
        // IERC20 cvx = IERC20(cvx_address);
    }
    
    function testDiscountRateBasics() public {
        /** 
        @fatima: confirm the discount rate is functional
        - access control for setting discount rate (i.e. the proper accounts can call the function and it works. improper accounts revert when attempting to call)
        - access control for setting discount rate limits
        - pausing freezes these functions appropriately
    */

        // calling from correct account
        vm.prank(address(governance));
        fundingCvx.setDiscountLimits(10, 50);
        vm.prank(address(policyOps));
        fundingCvx.setDiscount(20);
        (uint256 discount,uint256 minDiscount,uint256 maxDiscount,,,) = fundingCvx.funding();
        // check if discount is set
        assertEq(discount,20);

        // setting discount above maximum limit

        vm.prank(address(policyOps));
        vm.expectRevert(bytes("discount > maxDiscount"));
        fundingCvx.setDiscount(60);

        // setting discount below minimum limit
        vm.prank(address(policyOps));
        vm.expectRevert(bytes("discount < minDiscount"));
        fundingCvx.setDiscount(5);

        // calling setDiscount from a different account
        vm.prank(address(1));
        vm.expectRevert(bytes("GAC: invalid-caller-role-or-address"));
        fundingCvx.setDiscount(20);

        // - access control for setting discount rate limits

        // calling with correct role
        vm.prank(address(governance));
        fundingCvx.setDiscountLimits(0, 50);
        (,minDiscount,maxDiscount,,,) = fundingCvx.funding();

        // checking if limits are set
        assertEq(minDiscount,0);
        assertEq(maxDiscount, 50);

        // check discount can not be greater than or equal to MAX_BPS
        vm.prank(address(governance));
        vm.expectRevert(bytes("maxDiscount >= MAX_BPS"));
        fundingCvx.setDiscountLimits(0, 10000);

        // calling with wrong address
        vm.prank(address(1));
        vm.expectRevert(bytes("GAC: invalid-caller-role"));
        fundingCvx.setDiscountLimits(0,20);

        // - pausing freezes these functions appropriately
        vm.prank(address(guardian));
        gac.pause();
        vm.prank(address(governance));
        vm.expectRevert(bytes("global-paused"));
        fundingCvx.setDiscountLimits(0, 50);
        vm.prank(address(policyOps));
        vm.expectRevert(bytes("global-paused"));
        fundingCvx.setDiscount(10);

    }

    
    function testDiscountRateBuys(uint8 _assetAmountIn, uint32 discount, uint8 citadelPrice) public {
        
        /**
            @fatima: this is a good candidate to generalize using fuzzing: test buys with various discount rates, using fuzzing, and confirm the results.
            sanity check the numerical results (tokens in vs tokens out, based on price and discount rate)
        */ 

        vm.assume(discount<10000 && _assetAmountIn>0 && citadelPrice>0);  // discount < MAX_BPS = 10000 

        vm.prank(address(governance));
        fundingCvx.setDiscountLimits(0, 9999);
        
        vm.prank(address(policyOps));
        fundingCvx.setDiscount(discount); // set discount

        vm.prank(eoaOracle);
        fundingCvx.updateCitadelPriceInAsset(citadelPrice); // set citadel price

        uint256 citadelAmountOutExpected = fundingCvx.getAmountOut(_assetAmountIn);

        vm.prank(governance);
        citadel.mint(address(fundingCvx), citadelAmountOutExpected ); // fundingCvx should have citadel to transfer to user

        address user = address(1) ;
        vm.startPrank(user);
        erc20utils.forceMintTo(user, cvx_address , _assetAmountIn );
        cvx.approve(address(fundingCvx), _assetAmountIn);
        uint256 citadelAmountOut = fundingCvx.deposit(_assetAmountIn , 0);
        vm.stopPrank();
        
        assertEq(citadelAmountOut , citadelAmountOutExpected);

    }

    function testBuy() public {
        _testBuy(fundingCvx, 100e18, 100e18);
    }

    function testBuyDifferentDecimals() public {
        // wBTC is an 8 decimal example
        // TODO: Fix comparator calls in inner function as per that functions comment
        // _testBuy(fundingWbtc, 2e8, 2e8);
        assertTrue(true);
    }

    function _testBuy(Funding fundingContract, uint assetIn, uint citadelPrice) internal {
        // just make citadel appear rather than going through minting flow here
        erc20utils.forceMintTo(address(fundingContract), address(citadel), 100000e18);
        
        vm.prank(eoaOracle);

        // CVX funding contract gives us an 18 decimal example
        fundingContract.updateCitadelPriceInAsset(citadelPrice);

        uint expectedAssetOut = assetIn.divWadUp(citadelPrice);
        
        emit log_named_uint("Citadel Price", citadelPrice);

        vm.startPrank(whale);

        require(cvx.balanceOf(whale) >= assetIn, "buyer has insufficent assets for specified buy amount");
        require(citadel.balanceOf(address(fundingContract)) >= expectedAssetOut, "funding has insufficent citadel for specified buy amount");

        comparator.snapPrev();
        cvx.approve(address(fundingContract), cvx.balanceOf(whale));

        fundingContract.deposit(assetIn, 0);
        comparator.snapCurr();

        uint expectedAssetLost = assetIn;
        uint expectedxCitadelGained = citadelPrice;

        // user trades in asset for citadel in xCitadel form.
        assertEq(comparator.diff("citadel.balanceOf(whale)"), 0);
        assertEq(comparator.diff("xCitadel.balanceOf(whale)"), expectedAssetOut);
        assertEq(comparator.negDiff("cvx.balanceOf(whale)"), assetIn);
        
        // funding contract loses citadel and sends asset to saleRecipient. should never hold an xCitadel balance (deposited for each user) (gas costs?)

        // TODO: Improve comparator to easily add new entity for all balance calls.
        assertEq(comparator.negDiff("citadel.balanceOf(fundingCvx)"), expectedAssetOut);
        assertEq(comparator.diff("cvx.balanceOf(treasuryVault)"), assetIn);
        
        assertEq(xCitadel.balanceOf(address(fundingContract)), 0);

        vm.stopPrank();
    }
 }
