pragma solidity ^0.8.0;

import "./libs/ERC20.sol";

// RevolutionPresaleToken Token
contract RevolutionPresaleToken is ERC20('PreRevolution', 'PREV'){

    mapping(address => bool) public allowedAddresses;
    mapping(address => bool) public masters;

    constructor() {
        addMaster(address(msg.sender));
    }

    modifier eligibleForTransfer(address _to) {
        require(allowedAddresses[_to], "Unauthorized transfer");
        _;
    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);
        require(_validRecipient(to), "ERC20WithSafeTransfer: invalid recipient");
    }

    function addMaster(address _master) public onlyOwner {
        masters[_master] = true;
    }

    function addAllowedAddress(address _allowedAddress) public onlyOwner {
        allowedAddresses[_allowedAddress] = true;
    }

    function _validRecipient(address to) private view returns (bool) {
        // If a master, allow sending
        if (masters[msg.sender]){
            return true;
        }

        if (allowedAddresses[to]){
            return true;
        }

        return false;
    }

}