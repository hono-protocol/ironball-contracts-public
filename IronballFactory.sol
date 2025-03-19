// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./lib/IIronballStorage.sol";
import "./lib/IIronballNFT.sol";
import "./lib/IIronballLibrary.sol";
import "@openzeppelin/contracts-upgradeable/proxy/ClonesUpgradeable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

interface ICCIPSenderETH
{
    function setNFT(address _nft) external;
}
contract IronballFactory is OwnableUpgradeable {

    address public collectionImplementation;
    address public lidoManager ;

    uint256 public version;
    IIronballStorage public IronballStorage;
    uint256 private _proxyId;

    event Create(address collectionAddress, address collectionImplementation);
    event CreateDetail(address collectionAddress, uint256 maxSupply, bool isActive, address collectionImplementation);
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor()  {
       _disableInitializers();
    }
    
    function initialize( address _collectionImplementation,
        address _storageAddress,
        uint256 _version) initializer public {
        OwnableUpgradeable.__Ownable_init();
        collectionImplementation = _collectionImplementation;
        version = _version;
        IronballStorage = IIronballStorage(_storageAddress);
    }

    function updatecollectionImplementation(address _collectionImplementation) external onlyOwner {
        collectionImplementation = _collectionImplementation;
    }

    function createCollection (
		string memory _name, 
        string memory _symbol, 
        uint256 _maxSupply,
        string memory _baseUri,
        string memory _preRevealImageURI,
        address _referrer,
        address _whitelistSigner,
        IronballLibrary.MintConfig memory _publicMintConfig,
        IronballLibrary.MintConfig memory _privateMintConfig
    ) external payable returns (address) {
        // Create the collection clone
        //address payable clone = payable(ClonesUpgradeable.clone(collectionImplementation));
        BeaconProxy proxy = new BeaconProxy{salt: bytes32(_proxyId)}(collectionImplementation, "");
        address payable clone = payable(address(proxy));
        _proxyId++;
        // Initialize the collection clone
        IIronballNFT(clone).initialize(
            msg.sender, // collection owner address
            address(IronballStorage), // storage address
            address(this), // factory address
			_name, 
	        _symbol, 
	        _maxSupply,
            _baseUri,
            _preRevealImageURI,
            _referrer,
            _whitelistSigner,
            _publicMintConfig,
            _privateMintConfig);
        ICCIPSenderETH(IronballStorage.ccipSender()).setNFT(clone);
        emit CreateDetail(address(clone), _maxSupply, _publicMintConfig.active || _privateMintConfig.active,collectionImplementation);
        // Add the collection to the IronballStorage
        IronballStorage.addCollection(address(clone));
        // Return the address of the new collection
        return clone;
    }
}