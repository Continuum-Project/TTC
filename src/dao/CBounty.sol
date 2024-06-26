// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IBountyContract, WETHDataFeed} from "../interface/IBounty.sol";
import {InitialETHDataFeeds, BountyStatus, Bounty} from "../types/CBounty.sol";

contract BountyContract is IBountyContract, Ownable {
    modifier _activeBounty_(uint256 _bountyId) {
        require(bounties[_bountyId].status == BountyStatus.ACTIVE, "Bounty not active");
        _;
    }

    modifier _hasDatafeed_(address _token) {
        require(address(dataFeeds[_token]) != address(0), "Datafeed not found");
        _;
    }

    modifier _nonDuplicateDatafeed_(address _token) {
        require(address(dataFeeds[_token]) == address(0), "Datafeed already exists");
        _;
    }

    mapping(uint256 => Bounty) public bounties;
    mapping(address => AggregatorV3Interface) internal dataFeeds;

    uint256 bountyCount;

    // Data Feed for WETH should NOT be provided in _dataFeeds
    constructor(InitialETHDataFeeds[] memory _dataFeeds, address wethAddress) Ownable(msg.sender) {
        for (uint256 i = 0; i < _dataFeeds.length; i++) {
            dataFeeds[_dataFeeds[i].token] = AggregatorV3Interface(_dataFeeds[i].dataFeed);
        }

        dataFeeds[wethAddress] = new WETHDataFeed(wethAddress);
        bountyCount = 0;
    }

    function createBounty(address _tokenWant, address _tokenGive, uint256 _amountGive)
        external
        onlyOwner
        returns (uint256)
    {
        Bounty memory bounty = Bounty({
            bountyId: bountyCount,
            creator: owner(),
            tokenWant: _tokenWant,
            tokenGive: _tokenGive,
            amountGive: _amountGive,
            status: BountyStatus.ACTIVE
        });

        bounties[bountyCount] = bounty;
        bountyCount++;

        emit BOUNTY_CREATED(tx.origin, bounty.bountyId, _amountGive);

        return bounty.bountyId;
    }

    function fulfillBounty(uint256 _bountyId, uint256 amountIn)
        external
        onlyOwner // only DAO can fulfill bounties, though anyone can fulfill it through DAO
        _activeBounty_(_bountyId)
    {
        _fulfillBounty(bounties[_bountyId], amountIn);

        bounties[_bountyId].status = BountyStatus.FULFILLED;

        emit BOUNTY_FULFILLED(tx.origin, _bountyId);
    }

    function getBounty(uint256 _bountyId) external view returns (Bounty memory) {
        return bounties[_bountyId];
    }

    function addPriceFeed(address _token, address _dataFeed)
        external
        _nonDuplicateDatafeed_(_token) // not really needed, since only dao can invoke it
        onlyOwner
    {
        dataFeeds[_token] = AggregatorV3Interface(_dataFeed);

        emit PRICE_FEED_ADDED(_token, _dataFeed);
    }

    function _fulfillBounty(Bounty memory bounty, uint256 amountIn)
        internal
        _hasDatafeed_(bounty.tokenWant)
        _hasDatafeed_(bounty.tokenGive)
    {
        address fulfiller = tx.origin; // not msg.sender, because fulfill bounty is called through dao
        address creator = bounty.creator;

        // find value of tokenWant
        address tokenWant = bounty.tokenWant;
        uint256 tokenWantValue = _value(tokenWant, amountIn);

        // find value of tokenGive
        address tokenGive = bounty.tokenGive;
        uint256 tokenGiveValue = _value(tokenGive, bounty.amountGive);

        // check if the fulfiller has provided enough value
        require(tokenWantValue >= tokenGiveValue, "Value discrepancy too high");

        // transfer the tokens
        ERC20(tokenWant).transferFrom(fulfiller, creator, amountIn);
        ERC20(tokenGive).transferFrom(creator, fulfiller, bounty.amountGive);
    }

    function _value(address _token, uint256 _amount) internal view _hasDatafeed_(_token) returns (uint256) {
        AggregatorV3Interface tokenFeed = dataFeeds[_token];
        (, int256 tokenPrice,,,) = tokenFeed.latestRoundData();
        return _amount * uint256(tokenPrice);
    }
}
