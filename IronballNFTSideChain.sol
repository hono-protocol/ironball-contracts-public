// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./lib/Counters.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";

import "./lib/IERC4906.sol";
import "./lib/IIronballStorage.sol";
import "./lib/IIronballNFT.sol";
import "./lib/IIronballLibrary.sol";
import "./lib/IIronballNFTSideChain.sol";
interface RefundICCIP
{
    function destinationChainSelector() external view returns (uint64);
    function receiver() external view returns (address);
    function sendMessage(
        ActionData calldata data 
    ) external payable returns (bytes32 messageId);
}
interface IethCreateReceiver
{
     function tokenURI(address collectionAddress, 
        uint256 id, 
        string memory baseURI, 
        bool upgradedAt, 
        uint256 lockValue,
        uint256 lockAt,
        uint256 lockPeriod,
        string memory name,
        string memory preRevealImageURI) external view returns (string memory);
    function tokenURIForKey(address collectionAddress, 
        uint256 id, 
        string memory baseURI, 
        bool upgradedAt, 
        uint256 lockValue,
        uint256 lockAt,
        uint256 lockPeriod,
        string memory keyImg,
        string memory color) external view returns (string memory);
    function getMintedIdFromCollection(address collection, uint256 tokenId) external view returns(uint256);
}
interface IFactory {
    function CCIPReceiver() external view returns (address);
}
interface ILidoManager {
    function requestWithdraw(uint256 _stETHAmount, address user, bool instant) external;
}
interface IOwnable {
    function owner() external view returns (address);
}

/// @author Ironball team
/// @title Refundable NFTs implementation
contract IronballNFTSideChain is Initializable, ERC721EnumerableUpgradeable, IERC4906, OwnableUpgradeable, ReentrancyGuardUpgradeable, IIronballNFTSideChain {

    using ECDSA for bytes32;
    using Counters for Counters.Counter;
    using Strings for uint256;
    struct RoyaltyInfo {
        address royaltyAddress;
        uint96 royaltyBps;
    }
    struct Lock {
        uint128 value;
        uint64 lockPeriod;
        uint64 lockedAt;
    }
    Counters.Counter private _tokenId;
    Counters.Counter private _keyHoldersMints;

    string private _tokenName;
    string private _tokenSymbol;
    string private _description;

    uint256 public tvl;
    uint256 public maxSupply;
    uint256 public publicMintStartTime;
    address public factoryAddress;
    address public referrer;
    address public whitelistSigner;
    address public refundCCIPSender;
    address public ethCreateReceiver;
    string public baseURI;
    string public preRevealImageURI;
    bool public initialized;
    CollectionType public collectionType;

    IIronballStorage public IronballStorage;
    uint256[] public refundedTokens;
    ILidoManager public lidoManager;
    IronballLibrary.MintConfig public publicMintConfig;
    IronballLibrary.MintConfig public privateMintConfig;
    address public orignalNFTAddress;
    mapping(uint256 => Color) public color;
    mapping(uint256 => Lock) public locks; // tokenId -> Lock
    mapping(uint256 => uint256) public upgradedAt; // tokenId -> upgradedAt
    mapping(address => uint256) private _publicMintsPerWallet; // address -> nb tokens minted
    mapping(address => uint256) private _privateMintsPerWallet; // address -> nb tokens minted
    mapping(uint256 => uint256) private _keyHoldersMintsPerToken; // tokenId -> nb tokens minted
    event RoyaltyInfoUpdated(address royaltyAddress, uint96 royaltyBps);

    event Refund(uint256 tokenId, address indexed by, uint256 value);
    event Upgrade(uint256 tokenId, address indexed by, uint256 value);
    event GasFeesClaim(address owner, uint256 minClaimRateBips);
    event PublicMintStateUpdate(address owner, bool active);
    event PrivateMintStateUpdate(address owner, bool active);
    event WhitelistSignerUpdate(address owner, address whitelistSigner);
    event BaseUriUpdate(address owner, string baseURI);
    event PreRevealImageUriUpdate(address owner, string preRevealImageURI);
    event PublicMintConfigUpdate(
        address owner,
        uint128 mintPrice,
        uint64 lockPeriod,
        uint24 maxMintsPerTransaction,
        uint24 maxMintsPerWallet,
        bool active
    );
    event PrivateMintConfigUpdate(
        address owner,
        uint128 mintPrice,
        uint64 lockPeriod,
        uint24 maxMintsPerTransaction,
        uint24 maxMintsPerWallet,
        bool active
    );
    event Mint(
        uint256[] tokenIds,
        address indexed minter,
        address indexed recipient,
        uint128 value,
        uint24 quantity, 
        uint64 lockPeriod,
        string mintType
    );
    event YieldClaim(
        address owner,
        address protocolFeeCollector, 
        address referrer, 
        uint256 ownerYield,
        uint256 protocolYield,
        uint256 referrerYield
    );
    
    error AlreadyInitialized();
    error IncorrectMaxSupply();
    error TransferFailed();

    modifier onlyCCIPReceiver() {
        require(msg.sender == ethCreateReceiver || msg.sender == IOwnable(ethCreateReceiver).owner(), "Caller is not the CCIP receiver");
        _;
    }
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }


    /* External functions */

    function publicMint(uint24 _quantity, address receiver) external onlyCCIPReceiver() nonReentrant returns (uint256[] memory){

        // First 5 min (300s) of the public mint are reserved for Ironball key holders
        if (block.timestamp - publicMintStartTime < 300) {
            uint256 keysBalance = IIronballNFT(IronballStorage.NFTContractAddress()).balanceOf(msg.sender);
            require (keysBalance > 0 && _quantity <= keysBalance, "The first 5 min of public mint are reserved for Ironball key holders (max mint quantity: 1 per key owned)");
            require (_keyHoldersMints.current() + _quantity <= maxSupply / 20, "Must not mint more than 5% of total supply");

            uint256[] memory keysOwned = IIronballNFT(IronballStorage.NFTContractAddress()).tokensOwnedBy(msg.sender);
            uint256 keysUsed = 0;

            for (uint256 i = 0; i < keysBalance; i++) {
                uint256 ownedTokenId = keysOwned[i];
                if (_keyHoldersMintsPerToken[ownedTokenId] == 0) {
                    _keyHoldersMintsPerToken[ownedTokenId] = 1;
                    _keyHoldersMints.increment();
                    keysUsed++;

                    if (keysUsed == _quantity) {
                        break;
                    }
                }
            }

            require(keysUsed == _quantity, "You don't own enough keys to mint asked quantity");
        }

        require(_isNull(publicMintConfig.maxMintsPerTransaction) || _quantity <= publicMintConfig.maxMintsPerTransaction, "Exceeds max mints per transaction");
        require(_isNull(publicMintConfig.maxMintsPerWallet) || _publicMintsPerWallet[msg.sender] + _quantity <= publicMintConfig.maxMintsPerWallet, "Exceeds max mints per wallet");

        _publicMintsPerWallet[msg.sender] += _quantity;
        return _mint(receiver, publicMintConfig.mintPrice, publicMintConfig.lockPeriod, _quantity, 0, 'public');
    }

    function setCollectionType(CollectionType _collectionType) external onlyCCIPReceiver() {
        collectionType = _collectionType;
    }

    function setColor(uint256[] memory ids, Color[] memory _colors) external onlyCCIPReceiver() {
        require(ids.length == _colors.length, "Array length mismatch");
        for (uint256 i = 0; i < ids.length; i++) {
            color[ids[i]] = _colors[i];
        }
    }
    // Refunds and burns the tokenId, tokenId can be re-minted later
    function refund1chain(uint256 tokenId_) external payable nonReentrant {
        require(_exists(tokenId_), "Token ID does not exist");
        require(ownerOf(tokenId_) == msg.sender, "Not the NFT owner");

        Lock memory lock = locks[tokenId_];

        emit Refund(tokenId_, msg.sender, lock.value);
        emit MetadataUpdate(tokenId_);

        _burn(tokenId_);
        delete locks[tokenId_];

        // Add the token ID to the refundedTokens array
        refundedTokens.push(tokenId_);
       
    }

    function _refund(uint256 tokenId_) internal
    {
        require(_exists(tokenId_), "Token ID does not exist");
        require(ownerOf(tokenId_) == msg.sender, "Not the NFT owner");

        Lock memory lock = locks[tokenId_];
        require(lock.value > 0, "Nothing to refund");

        require(block.timestamp >= lock.lockedAt + lock.lockPeriod || msg.sender == owner(), "Lock period not expired");

        emit Refund(tokenId_, msg.sender, lock.value);
        emit MetadataUpdate(tokenId_);

        _burn(tokenId_);
        delete locks[tokenId_];

        // Add the token ID to the refundedTokens array
        refundedTokens.push(tokenId_);
        // Update TVL
    }

    function refund(uint256[] memory tokenIds) external payable nonReentrant {
        uint256[] memory orginalTokenIds = new uint256[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            _refund(tokenIds[i]);
            uint256 orginalTokenId = IethCreateReceiver(ethCreateReceiver).getMintedIdFromCollection(address(this), tokenIds[i]);
            orginalTokenIds[i] = orginalTokenId;
        }

        ActionData memory data = ActionData({
            nftAddress: orignalNFTAddress,
            tokenIds: orginalTokenIds,
            by: msg.sender,
            action: Action.REFUND
        });
        RefundICCIP(refundCCIPSender).sendMessage{value:msg.value}(data);
    }
    
    function _upgrade(uint256 tokenId_) internal {
        require(_exists(tokenId_), "Token ID does not exist");
        require(upgradedAt[tokenId_] == 0, "Already upgraded");
        require(ownerOf(tokenId_) == msg.sender, "Not the NFT owner");

        Lock memory lock = locks[tokenId_];

        emit Upgrade(tokenId_, msg.sender, lock.value);
        emit MetadataUpdate(tokenId_);

        // Delete the Lock from the mapping
        delete locks[tokenId_];

        // Update TVL
        tvl -= lock.value;

        // Register the upgrade
        upgradedAt[tokenId_] = block.timestamp;
    }

    function batchUpgrade(uint256[] memory tokenIds) external payable nonReentrant {
        uint256[] memory orginalTokenIds = new uint256[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length ; i++) {
            _upgrade(tokenIds[i]);
            uint256 orginalTokenId = IethCreateReceiver(ethCreateReceiver).getMintedIdFromCollection(address(this), tokenIds[i]);
            orginalTokenIds[i] = orginalTokenId;
        }

        ActionData memory data = ActionData({
            nftAddress: orignalNFTAddress,
            tokenIds: orginalTokenIds,
            by: msg.sender,
            action: Action.UPGRADE
        });

        RefundICCIP(refundCCIPSender).sendMessage{value:msg.value}(data);
    }
    /* Public functions */

    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, ERC721EnumerableUpgradeable) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    // Initializes the minimal proxy contract
    function initialize(
        address _ownerAddress,
        address _originalNFTAddress,
        string memory name_, 
        string memory symbol_, 
        uint256 _maxSupply,
        string memory baseURI_, // Do not use if _preRevealImageURI is used
        string memory _preRevealImageURI, // Do not use if baseURI_ is used
        address _referrer,
        address _whitelistSigner,
        IronballLibrary.MintConfig memory _publicMintConfig,
        IronballLibrary.MintConfig memory _privateMintConfig,
        address _lidoManager, 
        address _CCIPSender,
        address _ccipReceiver
    ) public initializer {
        // Revert if clone contract already initialized
        if (initialized) revert AlreadyInitialized();
        if (_maxSupply < 1) revert IncorrectMaxSupply();
        initialized = true;

        // Transfer ownership to the creator
        _transferOwnership(_ownerAddress);
        orignalNFTAddress = _originalNFTAddress;
        _tokenName = name_;
        _tokenSymbol = symbol_;
        maxSupply = _maxSupply;
        baseURI = baseURI_;
        preRevealImageURI = _preRevealImageURI;
        referrer = _referrer;
        whitelistSigner = _whitelistSigner;
        publicMintConfig = _publicMintConfig;
        privateMintConfig = _privateMintConfig;
        lidoManager = ILidoManager(_lidoManager);
        refundCCIPSender = _CCIPSender;
        ethCreateReceiver = _ccipReceiver;
    }

    function name() public view virtual override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view virtual override returns (string memory) {
        return _tokenSymbol;
    }

    function ccipUpdateMintConfit(IronballLibrary.MintConfig memory _publicMintConfig, IronballLibrary.MintConfig memory _privateMintConfig) external onlyCCIPReceiver() {
        publicMintConfig = _publicMintConfig;
        privateMintConfig = _privateMintConfig;
    }

    function setPublicMintConfig(IronballLibrary.MintConfig memory _publicMintConfig) external onlyOwner {
        publicMintConfig = _publicMintConfig;
    }
    
    function tokenURI(uint256 tokenId_) public view override returns (string memory) {
        require(_exists(tokenId_), "ERC721: URI query for nonexistent token");
        if (collectionType == CollectionType.key) {
            return IethCreateReceiver(ethCreateReceiver).tokenURIForKey(address(this), 
            tokenId_, 
            _baseURI(), 
            upgradedAt[tokenId_] > 0, 
            locks[tokenId_].value, 
            locks[tokenId_].lockedAt, 
            locks[tokenId_].lockPeriod, 
            getColorImage(tokenId_), getColor(tokenId_));
        } else if (collectionType == CollectionType.lottery) {
            return "No longer available";
        }
        if (bytes(_baseURI()).length > 0) {
            return string(abi.encodePacked(_baseURI(), tokenId_.toString()));
        } else {
            IethCreateReceiver(ethCreateReceiver).tokenURI(address(this), 
            tokenId_, 
            _baseURI(), 
            upgradedAt[tokenId_] > 0, 
            locks[tokenId_].value, 
            locks[tokenId_].lockedAt, 
            locks[tokenId_].lockPeriod, 
            _tokenName, preRevealImageURI);
        }   
    }

    function tokensOwnedBy(address _ownerAddress) public view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(_ownerAddress);
        uint256[] memory result = new uint256[](tokenCount); // Always initialized, might be empty
        
        for (uint256 index = 0; index < tokenCount; index++) {
            result[index] = tokenOfOwnerByIndex(_ownerAddress, index);
        }
        
        return result;
    }

    function setBaseURI(string memory _baseURI_) external onlyOwner() {
        baseURI = _baseURI_;
        emit BaseUriUpdate(msg.sender, _baseURI_);
    }
    
    function setPrepRevealImageURI(string memory _preRevealImageURI) external onlyOwner() {
        preRevealImageURI = _preRevealImageURI;
        emit PreRevealImageUriUpdate(msg.sender, _preRevealImageURI);
    }
    /* Internal functions */

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    // Adds a condition where an upgraded token can not be transferred for 7 days after upgrade
    // Prevents users from upgrading and accepting bids immediately on marketplaces
    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal virtual override(ERC721EnumerableUpgradeable) {
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
        require(upgradedAt[firstTokenId] == 0 || block.timestamp - upgradedAt[firstTokenId] > 86400 * 7, "After upgrade() tokens can not be transferred for 7 days");
    }

    function _mint(address _recipient, uint128 _mintPrice, uint64 _lockPeriod, uint24 _quantity, uint128 _msgValue, string memory mintType) private returns (uint256[] memory) {
        require(_quantity > 0, "Quantity cannot be zero");
        require(totalSupply() + _quantity <= maxSupply, "Max supply exceeded");

         uint256[] memory mintedTokens = new uint256[](_quantity);

        for (uint256 i = 0; i < _quantity; i++) {
            uint256 tokenId = _findAvailableTokenId();
            mintedTokens[i] = tokenId;
            locks[tokenId] = Lock({
                value: _mintPrice,
                lockPeriod: _lockPeriod,
                lockedAt: uint64(block.timestamp)
            });
            tvl += _mintPrice;

            _mint(_recipient, tokenId);
        }
        emit Mint(mintedTokens, msg.sender, _recipient, _msgValue, _quantity, _lockPeriod, mintType);
        return mintedTokens;
    }
    function setCollectionManager(address _ethCreateReceiver) external onlyOwner() {
        ethCreateReceiver = _ethCreateReceiver;
    }
    function _findAvailableTokenId() private returns (uint256) {
        if (refundedTokens.length > 0) {
            uint256 tokenId = refundedTokens[refundedTokens.length - 1];
            emit MetadataUpdate(tokenId);
            refundedTokens.pop();
            return tokenId;
        } else {
            uint256 newTokenId = _tokenId.current();
            _tokenId.increment();
            return newTokenId;
        }
    }

    // Checks if the variable is 0
    function _isNull(uint256 variable) private pure returns (bool) {
        return variable == 0;
    }

    function sendEth(address _address, uint256 _value) internal {
        (bool success, ) = _address.call{value: _value}("");
        require(success, "ETH Transfer failed.");
    }

    function getColor(uint256 id) internal view returns (string memory) {
        if (color[id] == Color.BRONZE) return "BRONZE";
        if (color[id] == Color.SILVER) return "SILVER";
        if (color[id] == Color.GOLD) return "GOLD";
        if (color[id] == Color.DIAMOND) return "DIAMOND";
        if (color[id] == Color.IRON) return "IRON";
        return "Unknown";
    }
    function getColorImage(uint256 id) internal view returns (string memory) {
        if (color[id] == Color.IRON) return "5";
        if (color[id] == Color.BRONZE) return "4";
        if (color[id] == Color.SILVER) return "3";
        if (color[id] == Color.GOLD) return "2";
        if (color[id] == Color.DIAMOND) return "1";
        return "Unknown";
    }
    function intToColor(uint8 id) internal pure returns (Color) {
        if (id == 0) return Color.DIAMOND;
        if (id == 1) return Color.GOLD;
        if (id == 2) return Color.SILVER;
        if (id == 3) return Color.BRONZE;
        if (id == 4) return Color.IRON;
        return Color.IRON;
    }
}