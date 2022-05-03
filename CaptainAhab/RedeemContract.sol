pragma solidity ^0.8.0;

import "./access/Ownable.sol";
import "./security/ReentrancyGuard.sol";
import "./libs/IERC20.sol";

contract RevolutionRedeem is Ownable, ReentrancyGuard {

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    IERC20 public constant PreRevolutionToken = IERC20(0x66690407FbA0141721BA2736D308D9C4bdd406eC);
    IERC20 public immutable RevolutionToken;
    bool public hasRevolutionStarted = false;

    event revSwap(address sender, uint256 amount);

    constructor(IERC20 _revolutionToken) {
        RevolutionToken  = _revolutionToken;
    }

    function swapPrevForRev(uint256 swapAmount) external nonReentrant {
        require(hasRevolutionStarted, "Ahoy, The Captain has not arrived yet!");
        require(RevolutionToken.balanceOf(address(this)) >= swapAmount, "Not Enough tokens in contract for swap");
        require(PreRevolutionToken.transferFrom(msg.sender, BURN_ADDRESS, swapAmount));
        RevolutionToken.transfer(msg.sender, swapAmount);

        emit revSwap(msg.sender, swapAmount);
    }

    function startRevolution() external onlyOwner {
        hasRevolutionStarted = true;
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount, address _to) public onlyOwner {
        IERC20(_token).transfer(_to, _amount);
    }
}