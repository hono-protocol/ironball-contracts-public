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

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface ICCIP
{
    function sendMessage(
        uint64 destinationChainSelector,
        address receiver,
        CollectionData calldata data 
    ) external payable returns (bytes32 messageId);
}


interface STETH {
    function submit(address _ref) external payable returns (uint256);
}

/// @author Ironball team
/// @title Refundable NFTs implementation
contract IronballNFT is Initializable, ERC721EnumerableUpgradeable, IERC4906, OwnableUpgradeable, ReentrancyGuardUpgradeable {

    using ECDSA for bytes32;
    using Counters for Counters.Counter;
    using Strings for uint256;

    struct Lock {
        uint256 value;
        uint64 lockPeriod;
        uint64 lockedAt;
    }
    struct RoyaltyInfo {
        address royaltyAddress;
        uint96 royaltyBps;
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
    address public validator;
    string public baseURI;
    string public preRevealImageURI;
    bool public initialized;

    address public royaltyAddress;
    uint96 private royaltyFraction;
    uint256 public royaltyBasisPoints;

    IIronballStorage public IronballStorage;
    uint256[] public refundedTokens;
    IronballLibrary.MintConfig public publicMintConfig;
    IronballLibrary.MintConfig public privateMintConfig;

    mapping(uint256 => Lock) public locks; // tokenId -> Lock
    mapping(uint256 => uint256) public upgradedAt; // tokenId -> upgradedAt
    mapping(address => uint256) private _publicMintsPerWallet; // address -> nb tokens minted
    mapping(address => uint256) private _privateMintsPerWallet; // address -> nb tokens minted
    mapping(uint256 => uint256) private _keyHoldersMintsPerToken; // tokenId -> nb tokens minted
    uint256 public keyHolderfeeDiscountFactor;
    mapping(uint256 => bool) public isCrossChainMinted; // tokenId -> index in tickets array

    event RoyaltyInfoUpdated(address royaltyAddress, uint96 royaltyBps);
    event TransferValidatorUpdated(address oldValidator, address newValidator);
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
    event CloneCreated(
        address clone, // The address of the sender from the source chain.
        address orignal // The text that was received.
    ); 

    event CrossMintRefunded(
        bytes32 messageId,
        address user,
        address collectionId 
    ); 
    
    error AlreadyInitialized();
    error IncorrectMaxSupply();
    error TransferFailed();
    
    modifier onlyCCIPReceiver() {
        require(msg.sender == IronballStorage.ccipReceiver(), "C");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function publicMint(uint24 _quantity, uint64 destinationChainSelector, address receiver) external payable nonReentrant {
        require(publicMintConfig.active, "N");

        // First 5 min (300s) of the public mint are reserved for Ironball key holders
        if (block.timestamp - publicMintStartTime < IronballStorage.keyHolderPriorityTime()) {
            uint256 keysBalance = IIronballNFT(IronballStorage.NFTContractAddress()).balanceOf(msg.sender);
            require (keysBalance > 0 && _quantity <= keysBalance, "K");
            require (_keyHoldersMints.current() + _quantity <= maxSupply / 20, "MS");

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

            require(keysUsed == _quantity, "NEK");
        }

        require(_isNull(publicMintConfig.maxMintsPerTransaction) || _quantity <= publicMintConfig.maxMintsPerTransaction, "EX");
        require(_isNull(publicMintConfig.maxMintsPerWallet) || _publicMintsPerWallet[msg.sender] + _quantity <= publicMintConfig.maxMintsPerWallet, "EX");

        _publicMintsPerWallet[msg.sender] += _quantity;
        _mint(msg.sender, publicMintConfig.mintPrice, publicMintConfig.lockPeriod, _quantity, uint128(msg.value), 'public', destinationChainSelector, receiver);
    }

    function privateMint(uint24 _quantity, bytes memory _signature, uint64 destinationChainSelector, address receiver) external payable nonReentrant {
        require(privateMintConfig.active, "not active");
        require(_isNull(privateMintConfig.maxMintsPerTransaction) || _quantity <= privateMintConfig.maxMintsPerTransaction, "EX");
        require(_isNull(privateMintConfig.maxMintsPerWallet) || _privateMintsPerWallet[msg.sender] + _quantity <= privateMintConfig.maxMintsPerWallet, "EX");
        address recoveredAddress = 
        keccak256(abi.encodePacked(address(this), owner(),msg.sender))
        .toEthSignedMessageHash().recover(_signature);
        require(recoveredAddress == IronballStorage.whitelistSigner(), "Na");

        _privateMintsPerWallet[msg.sender] += _quantity;
        _mint(msg.sender, privateMintConfig.mintPrice, privateMintConfig.lockPeriod, _quantity, uint128(msg.value), 'private', destinationChainSelector, receiver);
    }

    function _refund(uint256 tokenId_, address ownerOf) internal
    {
        Lock memory lock = locks[tokenId_];
        require(lock.value > 0, "Nothing to refund");
        address IronballKeysAddress = IronballStorage.NFTContractAddress();

        if (
            IIronballNFT(IronballKeysAddress).balanceOf(ownerOf) == 0 ||
            IronballKeysAddress == address(this) ||
            !IronballStorage.keyBenefit()
        ) {
            if(!isCrossChainMinted[tokenId_])
            {
                require(block.timestamp >= lock.lockedAt + lock.lockPeriod, "Lock");
            }
        }

        emit Refund(tokenId_, ownerOf, lock.value);
        emit MetadataUpdate(tokenId_);

        if(!isCrossChainMinted[tokenId_])
        {
           _burn(tokenId_);
        }

        isCrossChainMinted[tokenId_] = false;

        IERC20(IronballStorage.stETH()).transfer(ownerOf, lock.value);
        delete locks[tokenId_];
        refundedTokens.push(tokenId_);

        // Update TVL
        tvl -= lock.value;

    }

    function refundFromSideChainError(address minter, uint256[] calldata tokenIds, bytes32 messageId, bytes calldata signature) external  returns(bool){
        require(IronballStorage.verify(minter, messageId, tokenIds, signature), "Invalid signature");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(isCrossChainMinted[tokenIds[i]], "CRS");
            _refund(tokenIds[i], msg.sender);
        }
        emit CrossMintRefunded(messageId, msg.sender, address(this));
        return true;
    }

    function refundFromSideChain(uint256[] calldata tokenIds, address tokenOwner) external  onlyCCIPReceiver returns(bool){
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(isCrossChainMinted[tokenIds[i]], "CRS");
            _refund(tokenIds[i], tokenOwner);
        }
        return true;
    }

    function refund(uint256[] memory tokenId_) external nonReentrant {
        for (uint256 i = 0; i < tokenId_.length; i++) {
            require(isCrossChainMinted[tokenId_[i]] == false, "CRS");
            require(ownerOf(tokenId_[i]) == msg.sender, "Own");
            _refund(tokenId_[i], msg.sender);
        }
    }
    
    // Caution: this method will release the funds that have been locked during the mint for a specific NFT to the owner
    function _upgrade(uint256 tokenId_, address tokenOwner) internal  {
        Lock memory lock = locks[tokenId_];

        emit Upgrade(tokenId_, tokenOwner, lock.value);
        emit MetadataUpdate(tokenId_);

        // Transfer locked ether to the owner
        uint256 protocolFee = lock.value*IronballStorage.protocolFee()/10000;
        IERC20 stETH = IERC20(IronballStorage.stETH());
        stETH.transfer(owner(), lock.value - protocolFee);
        stETH.transfer(IronballStorage.feeCollector(),protocolFee);

        // Delete the Lock from the mapping
        delete locks[tokenId_];

        // Update TVL
        tvl -= lock.value;

        // Register the upgrade
        upgradedAt[tokenId_] = block.timestamp;
    }

    function batchUpgradeFromSideChain(uint256[] calldata tokenIds, address tokenOwner) external  onlyCCIPReceiver {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(upgradedAt[tokenIds[i]] == 0, "NU");
            _upgrade(tokenIds[i],tokenOwner);
        }
    }

    function batchUpgrade(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(_exists(tokenIds[i]), "NA");
            require(upgradedAt[tokenIds[i]] == 0, "NU");
            require(ownerOf(tokenIds[i]) == msg.sender, "NO");
            _upgrade(tokenIds[i], msg.sender);
        }
    }
    
    function claimYield() external nonReentrant onlyOwner(){
        uint256 _claimableYield = claimableYield();
        require(_claimableYield > 0, '0');

        uint256 protocolYield = 0;
        uint256 referrerYield = 0;
        uint256 contractYield = _claimableYield;
        IERC20 stETH = IERC20(IronballStorage.stETH());
        address protocolFeeCollector = IronballStorage.feeCollector();
        uint256 protocolFee = IronballStorage.protocolFee();
        uint256 referrerFee = IronballStorage.referrerFee();

        if (protocolFee > 0) {
            // If the owner owns a Ironball Key NFT
            if (IIronballNFT(IronballStorage.NFTContractAddress()).balanceOf(owner()) > 0) {
                protocolYield = _claimableYield * protocolFee *  IronballStorage.keyHolderfeeDiscountFactor() / 10000 ;
                contractYield -= protocolYield;
            }
        }
            
        // Transfer contractYield to the owner
        stETH.transfer(owner(), contractYield);

        if (protocolYield > 0) {
            // Transfer referrerYield to the referrer address
            if (referrer != address(0)) {
                if (referrerFee > 0) {
                    referrerYield = protocolYield * referrerFee / 10000;
                    stETH.transfer(referrer, referrerYield);
                    protocolYield -= referrerYield;
                }
            }
            stETH.transfer(protocolFeeCollector, protocolYield);
        }

        emit YieldClaim(
            owner(),
            protocolFeeCollector, 
            referrer, 
            contractYield,
            protocolYield,
            referrerYield
        );
    }
    
    function setPublicMintConfig(IronballLibrary.MintConfig memory _publicMintConfig) external onlyOwner {
        bool wasActiveBefore = publicMintConfig.active;
        publicMintConfig = _publicMintConfig;

        if (!wasActiveBefore && publicMintConfig.active) {
            publicMintStartTime = block.timestamp;
        }

        emit PublicMintConfigUpdate(
            owner(), 
            _publicMintConfig.mintPrice, 
            _publicMintConfig.lockPeriod, 
            _publicMintConfig.maxMintsPerTransaction, 
            _publicMintConfig.maxMintsPerWallet, 
            _publicMintConfig.active
        );
    }

    function setPrivateMintConfig(IronballLibrary.MintConfig memory _privateMintConfig) external onlyOwner {
        privateMintConfig = _privateMintConfig;
        emit PrivateMintConfigUpdate(
            owner(), 
            _privateMintConfig.mintPrice, 
            _privateMintConfig.lockPeriod, 
            _privateMintConfig.maxMintsPerTransaction, 
            _privateMintConfig.maxMintsPerWallet, 
            _privateMintConfig.active
        );
    }

    function setPreRevealImageURI(string calldata _preRevealImageURI) external onlyOwner {
        preRevealImageURI = _preRevealImageURI;
        emit PreRevealImageUriUpdate(msg.sender, _preRevealImageURI);

        if (bytes(baseURI).length == 0) {
            emit BatchMetadataUpdate(0, maxSupply);
        }
    }

    function setBaseURI(string calldata baseURI_) external onlyOwner {
        baseURI = baseURI_;
        emit BaseUriUpdate(msg.sender, baseURI_);
        emit BatchMetadataUpdate(0, maxSupply);
    }

    function tokenURI(uint256 tokenId_) public view override returns (string memory) {
        require(_exists(tokenId_), "NA");
        return IronballStorage.generateTokenURI(
            tokenId_,
            baseURI,
            preRevealImageURI,
            _tokenName,
            locks[tokenId_].value,
            locks[tokenId_].lockPeriod,
            upgradedAt[tokenId_],
            address(this)
        );
    }

    function ownerMint(address _recipient, uint128 _mintPrice, uint64 _lockPeriod, uint24 _quantity, uint64 destinationChainSelector, address receiver) external payable onlyOwner {
        _mint(_recipient, _mintPrice, _lockPeriod, _quantity, uint128(msg.value), 'owner',destinationChainSelector, receiver);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, ERC721EnumerableUpgradeable) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    // Initializes the minimal proxy contract
    function initialize(
        address _ownerAddress,
        address _storageAddress,
        address _factoryAddress,
        string memory name_, 
        string memory symbol_, 
        uint256 _maxSupply,
        string memory baseURI_, // Do not use if _preRevealImageURI is used
        string memory _preRevealImageURI, // Do not use if baseURI_ is used
        address _referrer,
        address _whitelistSigner,
        IronballLibrary.MintConfig memory _publicMintConfig,
        IronballLibrary.MintConfig memory _privateMintConfig) public initializer {
        // Revert if clone contract already initialized
        if (initialized) revert AlreadyInitialized();
        if (_maxSupply < 1) revert IncorrectMaxSupply();
        initialized = true;

        // Transfer ownership to the creator
        __Ownable_init();
        transferOwnership(_ownerAddress);
        __ReentrancyGuard_init();
        __ERC721_init(name_, symbol_);
        // Set the initial values
        IronballStorage = IIronballStorage(_storageAddress);
        factoryAddress = _factoryAddress;
        _tokenName = name_;
        _tokenSymbol = symbol_;
        maxSupply = _maxSupply;
        baseURI = baseURI_;
        preRevealImageURI = _preRevealImageURI;
        referrer = _referrer;
        whitelistSigner = _whitelistSigner;
        publicMintConfig = _publicMintConfig;
        privateMintConfig = _privateMintConfig;
    }

    function name() public view virtual override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view virtual override returns (string memory) {
        return _tokenSymbol;
    }

    function claimableYield() public view returns (uint256) {
        return IERC20(IronballStorage.stETH()).balanceOf(address(this)) - tvl;
    }

    function tokensOwnedBy(address _ownerAddress) public view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(_ownerAddress);
        uint256[] memory result = new uint256[](tokenCount); // Always initialized, might be empty
        
        for (uint256 index = 0; index < tokenCount; index++) {
            result[index] = tokenOfOwnerByIndex(_ownerAddress, index);
        }
        
        return result;
    }

    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal virtual override(ERC721EnumerableUpgradeable) {
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
        require(upgradedAt[firstTokenId] == 0 || block.timestamp - upgradedAt[firstTokenId] > 86400 * 7, "Lock");
    }

    function _mint(address _recipient, uint128 _mintPrice, uint64 _lockPeriod, uint24 _quantity, uint128 _msgValue, string memory mintType, uint64 destinationChainSelector, address receiver) private {
        require(_quantity > 0, "0");
        require(totalSupply() + _quantity <= maxSupply, "Max");
        require(_msgValue >= _mintPrice * _quantity, "Fund");
        uint256[] memory mintedTokens = new uint256[](_quantity);
        IERC20 stETH = IERC20(IronballStorage.stETH());
        for (uint256 i = 0; i < _quantity; i++) {
            uint256 tokenId = _findAvailableTokenId();
            mintedTokens[i] = tokenId;
            uint256 valueBefore = stETH.balanceOf(address(this));
            STETH(IronballStorage.stETH()).submit{value:_mintPrice}(IronballStorage.feeCollector());
            uint256 stethvalue = stETH.balanceOf(address(this)) - valueBefore;
            tvl += stethvalue;
            locks[tokenId] = Lock({
                value: stethvalue,
                lockPeriod: _lockPeriod,
                lockedAt: uint64(block.timestamp)
            });
            
            if(destinationChainSelector != 0)
            {
                isCrossChainMinted[tokenId] = true;
            }
            else
            {
                _mint(_recipient, tokenId);
            }
        }
        if (destinationChainSelector != 0) {
            CollectionData memory data = CollectionData({
                owner: owner(),
                collectionAddress: address(this),
                collectionImplementation: address(this),
                name: _tokenName,
                symbol: _tokenSymbol,
                maxSupply: maxSupply,
                baseUri: baseURI,
                preRevealImageURI: preRevealImageURI,
                referrer: referrer,
                whitelistSigner: whitelistSigner,
                publicMintConfig: publicMintConfig,
                privateMintConfig: privateMintConfig,
                minter: msg.sender,
                quantity: _quantity,
                mintedTokens: mintedTokens,
                tokenColor: new Color[](0)
            });
            ICCIP(IronballStorage.ccipSender())
            .sendMessage{value:msg.value - _mintPrice * _quantity}
            (destinationChainSelector, receiver, data);
        } 

        emit Mint(mintedTokens, msg.sender, _recipient, _msgValue, _quantity, _lockPeriod, mintType);
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
}   