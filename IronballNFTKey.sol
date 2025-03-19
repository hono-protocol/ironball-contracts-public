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
import "hardhat/console.sol";
interface ICCIP
{
    function sendMessage(
        uint64 destinationChainSelector,
        address receiver,
        CollectionData calldata data 
    ) external payable returns (bytes32 messageId);
}
interface IERC20 {
    /**s
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

/// @author Ironball team
/// @title Refundable NFTs implementation
contract IronballNFTKey is Initializable, ERC721EnumerableUpgradeable, IERC4906, OwnableUpgradeable, ReentrancyGuardUpgradeable {

    using ECDSA for bytes32;
    using Counters for Counters.Counter;
    using Strings for uint256;
    struct KeyMintConfig {
        uint256 mintPrice;
        uint64 lockPeriod;
        uint24 maxMintsPerTransaction;
        uint24 maxMintsPerWallet;
        bool active;
    }

    struct Lock {
        uint256 value;
        uint64 lockPeriod;
        uint64 lockedAt;
    }
    Counters.Counter private _tokenId;
    Counters.Counter private _keyHoldersMints;
    mapping(uint256 => Color) public color;
    string private _tokenName;
    string private _tokenSymbol;
    string private _description;

    uint256 public tvl;
    uint256 public maxSupply;
    uint256 public publicMintStartTime;
    address public factoryAddress;
    address public xHONO;
    address public referrer;
    address public whitelistSigner;
    address public ccipsender;
    string public baseURI;
    string public preRevealImageURI;
    bool public initialized;
    IIronballStorage public IronballStorage;

    uint256[] public refundedTokens;

    KeyMintConfig public publicMintConfig;

    mapping(uint256 => Lock) public locks; // tokenId -> Lock
    mapping(uint256 => uint256) public upgradedAt; // tokenId -> upgradedAt
    mapping(address => uint256) private _publicMintsPerWallet; // address -> nb tokens minted
    mapping(address => uint256) private _privateMintsPerWallet; // address -> nb tokens minted
    mapping(uint256 => uint256) private _keyHoldersMintsPerToken; // tokenId -> nb tokens minted
    mapping(uint256 => bool) public isCrossChainMinted; // tokenId -> index in tickets array

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
        uint256 mintPrice,
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
        require(_isNull(publicMintConfig.maxMintsPerTransaction) || _quantity <= publicMintConfig.maxMintsPerTransaction, "Exceeds max mints per transaction");
        require(_isNull(publicMintConfig.maxMintsPerWallet) || _publicMintsPerWallet[msg.sender] + _quantity <= publicMintConfig.maxMintsPerWallet, "Exceeds max mints per wallet");
        _publicMintsPerWallet[msg.sender] += _quantity;
        _mint(msg.sender, publicMintConfig.mintPrice, publicMintConfig.lockPeriod, _quantity, uint128(msg.value), 'public', destinationChainSelector, receiver, 9);
    }

    function _refund(uint256 tokenId_, address ownerOf, bool isSideChainError) internal
    {
        Lock memory lock = locks[tokenId_];
        require(lock.value > 0, "Nothing to refund");

        require(block.timestamp >= lock.lockedAt + lock.lockPeriod || isSideChainError, "Lock period not expired");

        emit Refund(tokenId_, msg.sender, lock.value);
        emit MetadataUpdate(tokenId_);

        if(isCrossChainMinted[tokenId_])
        {
            isCrossChainMinted[tokenId_] = false;
        }
        else
        {
            _burn(tokenId_);
        }

        sendHONO(msg.sender, lock.value);
        delete locks[tokenId_];
        refundedTokens.push(tokenId_);
        tvl -= lock.value;
    }

    function updateDescription(string memory description) external onlyOwner {
        _description = description;
    }

    function refundFromSideChain(uint256 tokenId_, address tokenOwner) external  onlyCCIPReceiver returns(bool){
        require(_exists(tokenId_), "Token ID");
        require(isCrossChainMinted[tokenId_] == true, "Not cross chain minted");
        _refund(tokenId_, tokenOwner, false);
        return true;
    }
    function refundFromSideChainError(address minter, uint256[] memory tokenIds, bytes32 messageId, bytes calldata signature) external  returns(bool){
        require(IronballStorage.verify(minter, messageId, tokenIds, signature), "Invalid signature");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(isCrossChainMinted[tokenIds[i]] == true, "CRS");
            _refund(tokenIds[i], msg.sender, true);
        }
        emit CrossMintRefunded(messageId, msg.sender, address(this));
        return true;
    }
    function refund(uint256[] memory tokenId_) external nonReentrant {
        for (uint256 i = 0; i < tokenId_.length; i++) {
            require(isCrossChainMinted[tokenId_[i]] == false, "CRS");
            require(ownerOf(tokenId_[i]) == msg.sender, "Own");
            _refund(tokenId_[i], msg.sender, false);
        }
    }

    function setPublicMintConfig(KeyMintConfig memory _publicMintConfig) external onlyOwner {
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

    function setXHonoAddress(address _xhono) external onlyOwner {
        xHONO = _xhono;
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

    function setWhitelistSigner(address _whitelistSigner) external onlyOwner {
        whitelistSigner = _whitelistSigner;
        emit WhitelistSignerUpdate(msg.sender, _whitelistSigner);
    }

    function ownerMint(address _recipient, uint128 _mintPrice, uint64 _lockPeriod, uint24 _quantity, uint64 destinationChainSelector, address receiver, uint8 adminColor) external payable onlyOwner {
        _mint(_recipient, _mintPrice, _lockPeriod, _quantity, uint128(msg.value), 'owner',destinationChainSelector, receiver, adminColor);
    }
    /* Public functions */  

    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, ERC721EnumerableUpgradeable) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    // Initializes the minimal proxy contract
    function initialize(
        uint256 _maxSupply,
        string memory baseURI_,
        KeyMintConfig memory _publicMintConfig,
        address _ironballStorage
    ) public initializer {
        // Revert if clone contract already initialized
        if (initialized) revert AlreadyInitialized();
        if (_maxSupply < 1) revert IncorrectMaxSupply();
        initialized = true;
        __Ownable_init();

        _tokenName = "IronballNFTKEY";
        _tokenSymbol = "IronballNFTKEY";
        maxSupply = _maxSupply;
        baseURI = baseURI_;
        publicMintConfig = _publicMintConfig;
        IronballStorage = IIronballStorage(_ironballStorage);
    }
    
    function setOwner(address _owner) external {
        _transferOwnership(_owner);
    }
    function name() public view virtual override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view virtual override returns (string memory) {
        return _tokenSymbol;
    }


    function tokensOwnedBy(address _ownerAddress) public view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(_ownerAddress);
        uint256[] memory result = new uint256[](tokenCount); // Always initialized, might be empty
        
        for (uint256 index = 0; index < tokenCount; index++) {
            result[index] = tokenOfOwnerByIndex(_ownerAddress, index);
        }
        
        return result;
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

    function batchUpgradeFromSideChain(uint256[] calldata tokenIds, address tokenOwner) external  onlyCCIPReceiver {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(upgradedAt[tokenIds[i]] == 0, "NU");
            require(isCrossChainMinted[tokenIds[i]], "NU");
            Lock memory lock = locks[tokenIds[i]];

            emit Upgrade(tokenIds[i], tokenOwner, lock.value);
            emit MetadataUpdate(tokenIds[i]);

            // Transfer locked ether to the owner
            IERC20 xHonoToken = IERC20(xHONO);
            xHonoToken.transfer(owner(), lock.value);

            // Delete the Lock from the mapping
            delete locks[tokenIds[i]];

            // Update TVL
            tvl -= lock.value;

            // Register the upgrade
            upgradedAt[tokenIds[i]] = block.timestamp;
        }
    }

    function batchUpgrade(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _upgrade(tokenIds[i]);
        }
    }

    // Caution: this method will release the funds that have been locked during the mint for a specific NFT to the owner
    function _upgrade(uint256 tokenId_) internal {
        require(_exists(tokenId_), "Token ID does not exist");
        require(upgradedAt[tokenId_] == 0, "Already upgraded");
        require(ownerOf(tokenId_) == msg.sender, "Not the NFT owner");

        Lock memory lock = locks[tokenId_];

        emit Upgrade(tokenId_, msg.sender, lock.value);
        emit MetadataUpdate(tokenId_);

        // Transfer locked ether to the owner
        IERC20(xHONO).transfer(owner(), lock.value);
        // Delete the Lock from the mapping
        delete locks[tokenId_];

        // Update TVL
        tvl -= lock.value;

        // Register the upgrade
        upgradedAt[tokenId_] = block.timestamp;
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
    
    function tokenURI(uint256 id) public view override returns (string memory) {
        return IronballStorage.tokenURIForKey(address(this), 
        id, 
        _baseURI(), 
        upgradedAt[id] > 0, 
        locks[id].value, 
        locks[id].lockedAt, 
        locks[id].lockPeriod, 
        getColorImage(id), getColor(id));
    }


    function _mint(address _recipient, 
                    uint256 _mintPrice, 
                    uint64 _lockPeriod, 
                    uint24 _quantity, 
                    uint128 _msgValue, 
                    string memory mintType, 
                    uint64 destinationChainSelector, 
                    address receiver,
                    uint8 admincolor) private {
        require(_quantity > 0, "Quantity cannot be zero");
        require(totalSupply() + _quantity <= maxSupply, "Max supply exceeded");
        //require(_msgValue >= _mintPrice * _quantity, "Incorrect mint price");
        IERC20(xHONO).transferFrom(msg.sender, address(this), _mintPrice * _quantity);
        uint256[] memory mintedTokens = new uint256[](_quantity);
        Color[] memory mintedTokenColors = new Color[](_quantity);
        for (uint256 i = 0; i < _quantity; i++) {
            uint256 tokenId = _findAvailableTokenId();
            mintedTokens[i] = tokenId;
            locks[tokenId] = Lock({
                value: _mintPrice,
                lockPeriod: _lockPeriod,
                lockedAt: uint64(block.timestamp)
            });
            tvl += _mintPrice;

            if(destinationChainSelector != 0)
            {
                isCrossChainMinted[tokenId] = true;
                //_mint(IronballStorage.ccipSender(), tokenId);
            }
            else
            {
                _mint(_recipient, tokenId);
            }
               
            bytes32 blockHash = blockhash(block.number - 1);
            uint256 colorseed = uint256(keccak256(abi.encodePacked(blockHash, tokenId))) % 1000;
            if(colorseed < 25)
            {
                color[tokenId] = Color.DIAMOND;
            }
            else if(colorseed < 100) //+7.5%
            {
                color[tokenId] = Color.GOLD;
            }
            else if(colorseed < 250) //+15%
            {
                color[tokenId] = Color.SILVER;
            }
            else if(colorseed < 500) //+25%
            {
                color[tokenId] = Color.BRONZE;
            }
            else
            {
                color[tokenId] = Color.IRON;
            }
            if(admincolor != 9)
            {
                color[tokenId] = intToColor(admincolor);
            }
            mintedTokenColors[i] = color[tokenId];
        }
        if (destinationChainSelector != 0) {
        IronballLibrary.MintConfig memory crossMint = IronballLibrary.MintConfig({
            mintPrice: uint128(publicMintConfig.mintPrice),
            lockPeriod: _lockPeriod,
            maxMintsPerTransaction: publicMintConfig.maxMintsPerTransaction,
            maxMintsPerWallet: publicMintConfig.maxMintsPerWallet,
            active: true
        });
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
            publicMintConfig: crossMint,
            privateMintConfig: crossMint,
            minter: msg.sender,
            quantity: _quantity,
            mintedTokens: mintedTokens,
            tokenColor: mintedTokenColors
        });
        ICCIP(IronballStorage.ccipSender()).sendMessage{value:msg.value}(destinationChainSelector, receiver, data);
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

    function intToColor(uint8 id) internal pure returns (Color) {
        if (id == 0) return Color.DIAMOND;
        if (id == 1) return Color.GOLD;
        if (id == 2) return Color.SILVER;
        if (id == 3) return Color.BRONZE;
        if (id == 4) return Color.IRON;
        return Color.IRON;
    }

    // Checks if the variable is 0
    function _isNull(uint256 variable) private pure returns (bool) {
        return variable == 0;
    }

    function sendHONO(address _address, uint256 _value) internal {
        IERC20(xHONO).transfer(_address, _value);
    }

    function rescuseERC20(address tokenToRescuse, uint256 amount) public onlyOwner {
        IERC20(tokenToRescuse).transfer(owner(), amount);
    }

    function rescuseNFT(address nftToRecuse, address spender, bool status) public onlyOwner {
        IERC721(nftToRecuse).setApprovalForAll(spender, status);
    }

    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function toDisplayString(uint256 value) internal pure returns (string memory) {
        uint256 integerPart = value / 1e18;
        uint256 fractionalPart = value % 1e18;

        // Convert integer and fractional parts to strings
        string memory integerStr = uintToString(integerPart);
        string memory fractionalStr = uintToString(fractionalPart);

        // Ensure the fractional part has 18 digits
        while (bytes(fractionalStr).length < 18) {
            fractionalStr = string(abi.encodePacked("0", fractionalStr));
        }

        // Trim trailing zeros in the fractional part
        bytes memory fractionalBytes = bytes(fractionalStr);
        uint256 trimmedLength = fractionalBytes.length;

        // Find the correct trimmed length
        while (trimmedLength > 0 && fractionalBytes[trimmedLength - 1] == "0") {
            trimmedLength--;
        }

        // Create a new `bytes` array for the trimmed fractional part
        bytes memory trimmedFractionalBytes = new bytes(trimmedLength);
        for (uint256 i = 0; i < trimmedLength; i++) {
            trimmedFractionalBytes[i] = fractionalBytes[i];
        }

        // Convert the trimmed `bytes` to a string
        fractionalStr = string(trimmedFractionalBytes);
        if(bytes(fractionalStr).length == 0)
        {
            fractionalStr = "0";
        }
        // Return the formatted string
        return string(abi.encodePacked(integerStr, ".", fractionalStr));
    }

}