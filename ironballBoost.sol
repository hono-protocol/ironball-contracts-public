// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./lib/IIronballStorage.sol";

interface STETH {
    function submit(address _ref) external payable returns (uint256);

}

contract IronballBoosts is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {

	IIronballStorage public ironballStorage;
	uint256 public tvl;

	mapping(address => mapping(address => uint256)) public boosts; // booster -> collection -> nb of boosts
	mapping(address => uint256) public boostsPerAddress; // booster -> nb of boosts
	mapping(address => uint256) public balance; // booster -> balance

	event Boost(address indexed user, address collection, uint256 quantity, uint256 value);
	event Transfer(address indexed user, address from, address to, uint256 quantity);
	event Refund(address indexed user, address collection, uint256 quantity, uint256 value);
	
	/// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

	function initialize( address _storageAddress) public initializer {
        OwnableUpgradeable.__Ownable_init();
        ironballStorage = IIronballStorage(_storageAddress);
    }

    function claimYield() external nonReentrant onlyOwner {
        uint256 _claimableYield = claimableYield();
        require(_claimableYield > 0, 'No yield to claim.');
    	(bool success, ) = payable(ironballStorage.feeCollector()).call{value: _claimableYield}("");
    	require(success, 'Transfer failed');
    }

    function claimableYield() public view returns (uint256) {
        return address(this).balance - tvl;
    }

	function boost(uint256 _quantity, address _collection) public payable {
		require(_quantity > 0, "Incorrect quantity");
		require(ironballStorage.isCollection(_collection), "Can only boost collection created with ironball");
		require(boosts[msg.sender][_collection] + _quantity <= ironballStorage.maxBoostsPerAddressPerCollection(), "Max boosts per collection reached");
		require(msg.value >= _quantity * ironballStorage.boostPrice(), "Incorrect eth value sent");
		uint256 balanceBefore = IERC20(ironballStorage.stETH()).balanceOf(address(this));
		STETH(ironballStorage.stETH()).submit{value:msg.value}(ironballStorage.feeCollector());
		uint256 stethvalue = IERC20(ironballStorage.stETH()).balanceOf(address(this)) - balanceBefore;
		boosts[msg.sender][_collection] += _quantity;
		boostsPerAddress[msg.sender] += _quantity;
		balance[msg.sender] += stethvalue;
		tvl += stethvalue;

		emit Boost(msg.sender, _collection, _quantity, stethvalue);
	}

	function transfer(uint256 _quantity, address _collectionFrom, address _collectionTo) public {
		require(_quantity > 0, "Incorrect quantity");
		require(ironballStorage.isCollection(_collectionFrom) && ironballStorage.isCollection(_collectionTo), "Can only transfer boosts for collections created with ironball");
		require(boosts[msg.sender][_collectionFrom] >= _quantity, "Not enough boosts to transfer");
		require(boosts[msg.sender][_collectionTo] + _quantity <= ironballStorage.maxBoostsPerAddressPerCollection(), "Max boosts per collection reached");

		boosts[msg.sender][_collectionFrom] -= _quantity;
		boosts[msg.sender][_collectionTo] += _quantity;

		emit Transfer(msg.sender, _collectionFrom, _collectionTo, _quantity);
	}

	function refund(address _collection) public {
		require(ironballStorage.isCollection(_collection), "Can only refund from a collection created with ironball");
		require(boosts[msg.sender][_collection] > 0, "No boosts to refund");

		uint256 averageBoostPrice = balance[msg.sender] / boostsPerAddress[msg.sender];
		uint256 boostsToRefund = boosts[msg.sender][_collection];
		uint256 valueToRefund = averageBoostPrice * boostsToRefund;

		boosts[msg.sender][_collection] = 0;
		boostsPerAddress[msg.sender] -= boostsToRefund;
		balance[msg.sender] -= valueToRefund;
		tvl -= valueToRefund;
		IERC20(ironballStorage.stETH()).transfer(msg.sender, valueToRefund);
		//payable(msg.sender).transfer(valueToRefund);

		emit Refund(msg.sender, _collection, boostsToRefund, valueToRefund);
	}
}