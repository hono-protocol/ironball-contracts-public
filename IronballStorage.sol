// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./lib/IIronballNFT.sol";

contract IronballStorage is OwnableUpgradeable {
    using Strings for uint256;
    using ECDSA for bytes32;

    address public ccipSender;
    address public ccipReceiver;
    address public feeCollector;
    uint256 public protocolFee; // bips
    uint256 public protocolFeeMarketPlace; // bips
    uint256 public referrerFee; // bips
    uint256 public boostPrice;
    address public NFTContractAddress;
    uint256 public maxBoostsPerAddressPerCollection;
    address public stETH;
    address public whitelistSigner;
    uint256 public keyHolderPriorityTime;
    mapping(address => bool) public isCollection;
    mapping(address => bool) public isFactory;
    mapping(address => bool) public allowedOperator;
    bool public keyBenefit;

    error ZeroAddress();
    error InvalidFee();
    error NotFactory();
    error NFTContractAddressAlreadyInitialized();

    event FeeCollectorUpdate(address feeCollector);
    event ProtocolFeeUpdate(uint256 protocolFee);
    event ReferrerFeeUpdate(uint256 referrerFee);
    event BoostPriceUpdate(uint256 boostPrice);
    event NFTContractAddressUpdate(address NFTContractAddress);
    event MaxBoostsPerAddressPerCollectionUpdate(uint256 maxBoostsPerAddressPerCollection);
    event FactoryAdd(address factoryAddress);
    event CollectionAdd(address collectionAddress);
    uint256 public keyHolderfeeDiscountFactor;
    address public refunderOperator;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor()  {
       _disableInitializers();
    }
    function initialize( address _feeCollector,
        uint256 _protocolFee,
        uint256 _referrerFee,
        uint256 _boostPrice,
        uint256 _maxBoostsPerAddressPerCollection,
        address _stETH,
        uint256 _keyHolderPriorityTime) public initializer {
        if (_feeCollector == address(0)) revert ZeroAddress();
        OwnableUpgradeable.__Ownable_init();
        feeCollector = _feeCollector;
        protocolFee = _protocolFee;
        referrerFee = _referrerFee;
        boostPrice = _boostPrice;
        maxBoostsPerAddressPerCollection = _maxBoostsPerAddressPerCollection;
        stETH = _stETH;
        keyHolderPriorityTime = _keyHolderPriorityTime;
        whitelistSigner = 0x91e5f8BF0F3572f0547Ea5c483D84127326A8ee1;
    }
    function addCollection(address _collectionAddress) external {

        if (_collectionAddress == address(0)) revert ZeroAddress();
        if (!isFactory[msg.sender]) revert NotFactory();
        isCollection[_collectionAddress] = true;
        emit CollectionAdd(_collectionAddress);
    }

    function verify(
        address minter,
        bytes32 messageId,
        uint256[] calldata ids,
        bytes calldata signature
    ) external view returns (bool) {
        address recoveredAddress = keccak256(abi.encodePacked(minter,messageId,ids)).toEthSignedMessageHash().recover(signature);
        return recoveredAddress == refunderOperator;
    }

    function verify2(
        bytes32 messageId,
        uint256[] calldata ids,
        bytes calldata signature
    ) external view returns (address) {
        
        address recoveredAddress = 
            keccak256(abi.encodePacked(messageId,ids))
            .toEthSignedMessageHash().recover(signature);
        return recoveredAddress;
    }

    function updateRefundOverator(address _newOperator) external onlyOwner {
        refunderOperator = _newOperator;
    }

    function setAllowedOperator(address _operator, bool _allowed) external onlyOwner {
        allowedOperator[_operator] = _allowed;
    }

    function addFactory(address _factoryAddress) external onlyOwner {
        if (_factoryAddress == address(0)) revert ZeroAddress();
        isFactory[_factoryAddress] = true;
        emit FactoryAdd(_factoryAddress);
    }

    function updateprotocolFeeMarketPlace(uint256 _protocolFeeMarketPlace) external onlyOwner {
        protocolFeeMarketPlace = _protocolFeeMarketPlace;
    }
    
    function updateStETH(address _stETH) external onlyOwner {
        stETH = _stETH;
    }
    function updateKeyHolderFeeDiscountFactor(uint256 _keyHolderfeeDiscountFactor) external onlyOwner {
        keyHolderfeeDiscountFactor = _keyHolderfeeDiscountFactor;
    }
    function updateKeyBenefit(bool _keyBenefit) external onlyOwner {
        keyBenefit = _keyBenefit;
    }

    function updateFeeCollector(address _feeCollector) external onlyOwner {
        if (_feeCollector == address(0)) revert ZeroAddress();
        feeCollector = _feeCollector;
        emit FeeCollectorUpdate(_feeCollector);
    }

    function updateSigner(address _signer) external onlyOwner {
        whitelistSigner = _signer;
    }

    function validateTransfer(address caller, address from, address to) external view returns (bool) {
        return true;
        //return allowedOperator[caller] || caller == to || caller == from;
    }

    function updateProtocolFee(uint256 _protocolFee) external onlyOwner {
        if (_protocolFee < 0 || _protocolFee > 1000) revert InvalidFee(); // _protocolFee should be between 0 and 10%
        protocolFee = _protocolFee;
        emit ProtocolFeeUpdate(_protocolFee);
    }

    function updateCcipSender(address _ccip) external onlyOwner()
    {
        ccipSender = _ccip;
    }

    function updateCCIPReceiver(address _ccip) external onlyOwner()
    {
        ccipReceiver = _ccip;
    }

    function updateKeyHolderPriorityTime(uint256 _keyHolderPriorityTime) external onlyOwner {
        keyHolderPriorityTime = _keyHolderPriorityTime;
    }

    function updateReferrerFee(uint256 _referrerFee) external onlyOwner {
        if (_referrerFee < 0 || _referrerFee > 5000) revert InvalidFee(); // _referrerFee should be between 0 and 50%
        referrerFee = _referrerFee;
        emit ReferrerFeeUpdate(_referrerFee);
    }

    function updateBoostPrice(uint256 _boostPrice) external onlyOwner {
        boostPrice = _boostPrice;
        emit BoostPriceUpdate(_boostPrice);
    }

    function updateNFTContractAddress(address _NFTContractAddress) external onlyOwner {
        NFTContractAddress = _NFTContractAddress;
        emit NFTContractAddressUpdate(_NFTContractAddress);
    }

    function updateMaxBoostsPerAddressPerCollection(uint256 _maxBoostsPerAddressPerCollection) external onlyOwner {
        maxBoostsPerAddressPerCollection = _maxBoostsPerAddressPerCollection;
        emit MaxBoostsPerAddressPerCollectionUpdate(_maxBoostsPerAddressPerCollection);
    }

    function tokenURIForKey(address collectionAddress, 
        uint256 id, 
        string memory baseURI, 
        bool upgradedAt, 
        uint256 lockValue,
        uint256 lockAt,
        uint256 lockPeriod,
        string memory keyImg,
        string memory color) external view returns (string memory) {
        string memory image = string.concat(baseURI,keyImg,'.gif');
        string memory upgradedString = upgradedAt ? "Yes" : "No";

        string memory externalUrl = string(
                abi.encodePacked(
                    "https://ironball.xyz/",
                    Strings.toHexString(uint160(address(this)), 20),
                    "/",
                    id.toString()
                )
            );

            return string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(
                        bytes(
                            string(
                                abi.encodePacked(
                                    '{',
                                        '"id": "', Strings.toString(id), '",',
                                        '"name": "Ironball Key #', Strings.toString(id), '",',
                                        '"image": "', image, '",',
                                        '"external_url": "', externalUrl, '",',
                                        '"attributes": [',
                                            '{',
                                                '"trait_type": "Color",',
                                                '"value": "', color,'"',
                                            '},',
                                            '{',    
                                                '"display_type": "numeric",',
                                                '"trait_type": "Value locked (xHONO)",',
                                                '"value": "', toDisplayString(lockValue),'"',
                                            '},',
                                            '{',
                                                '"display_type": "date",',
                                                '"trait_type": "Refundable Date",',
                                                '"value": ', Strings.toString(lockAt + lockPeriod),
                                            '},',
                                            '{',
                                                '"trait_type": "Upgraded",',
                                                '"value": "', upgradedString, '"',
                                            '}',
                                        ']',
                                    '}'
                                )
                            )
                        )
                    )
                )
            );
    }
    function generateTokenURI(
        uint256 tokenId,
        string memory baseURI,
        string memory preRevealImageURI,
        string memory name,
        uint256 lockValue,
        uint256 lockPeriod,
        uint256 upgradedAtTime,
        address contractAddress
    ) external view returns (string memory) {
        IIronballNFT nft = IIronballNFT(contractAddress);
        (, , uint256 lockAt)  = nft.locks(tokenId);
        // Check if baseURI is provided
        if (bytes(baseURI).length > 0) {
            return string(abi.encodePacked(baseURI, tokenId.toString()));
        } else {
            // Generate custom tokenURI
            string memory upgradedString = upgradedAtTime != 0 ? "Yes" : "No";
            string memory externalUrl = string(
                abi.encodePacked(
                    "https://ironball.xyz/",
                    Strings.toHexString(uint160(contractAddress), 20),
                    "/",
                    tokenId.toString()
                )
            );

            return string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(
                        bytes(
                            string(
                                abi.encodePacked(
                                    '{',
                                        '"id": "', Strings.toString(tokenId), '",',
                                        '"name": "', name, ' #', Strings.toString(tokenId), '",',
                                        '"image": "', preRevealImageURI, '",',
                                        '"external_url": "', externalUrl, '",',
                                        '"attributes": [',
                                            '{',
                                                '"display_type": "numeric",',
                                                '"trait_type": "Value locked (stETH)",',
                                                '"value": ', toDisplayString(lockValue),
                                            '},',
                                            '{',
                                                '"display_type": "date",',
                                                '"trait_type": "Refundable Date",',
                                                '"value": ', Strings.toString(lockAt + lockPeriod),
                                            '},',
                                            '{',
                                                '"trait_type": "Upgraded",',
                                                '"value": "', upgradedString, '"',
                                            '}'
                                        ']',
                                    '}'
                                )
                            )
                        )
                    )
                )
            );
        }
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

        // Return the formatted string
        return string(abi.encodePacked(integerStr, ".", fractionalStr));
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
}