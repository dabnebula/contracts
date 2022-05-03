// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./libs/IERC20.sol";
import "./libs/SafeERC20.sol";
import "./libs/IReferralSystem.sol";
import "./libs/IStrategy.sol";
import "./access/Ownable.sol";
import "./security/ReentrancyGuard.sol";

import "./CaptainAhab.sol";

contract MasterChefV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;             // Address of LP token contract.
        IStrategy strategy;         // Strategy address that will earnings compound want tokens
        uint256 allocPoint;         // How many allocation points assigned to this pool. Revolution to distribute per block.
        uint256 lastRewardBlock;    // Last block number that Revolution distribution occurs.
        uint256 accRevolutionPerShare;   // Accumulated Revolution per share, times 1e12. See below.
        uint256 lpSupply;
        uint16 depositFeeBP;        // Deposit fee in basis points
    }

    uint256 public constant RevolutionMaximumSupply = 1000000 * 1e18;

    RevolutionToken public immutable revolution;
    uint16 public constant referralCommissionRate = 300; // 3%

    // tokens created per block.
    uint256 public revolutionPerBlock = 1 * 1e18;
    // Deposit Fee address
    address public feeAddress;

    IReferralSystem public revolutionReferral;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    uint256 public startBlock; // The block number when Revolution mining starts.
    uint256 public emissionEndBlock; // The block number when Revolution mining ends.

    event AddPool(uint256 indexed pid, address lpToken, address strategy, uint256 allocPoint, uint256 depositFeeBP);
    event SetPool(uint256 indexed pid, address lpToken, uint256 allocPoint, uint256 depositFeeBP);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event UpdateStartBlock(uint256 newStartBlock);
    event SetRevolutionReferral(address referralAddress);
    event StuckTokenRemoval(address token, uint256 amount);

    constructor(
        RevolutionToken _revolution,
        address _feeAddress,
        uint256 _startBlock
    ) public {
        require(_startBlock >= block.number && _startBlock < 14500000, "invalid startBlock"); //14500000 = Estimated Target Date: Wed Jan 19 2022 10:54:32 GMT+0100 (Central European Standard Time)
        revolution = _revolution;
        feeAddress = _feeAddress;
        startBlock = _startBlock;
        emissionEndBlock = _startBlock + 403200; //Farm ends in 2 weeks
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken, IStrategy _strategy, uint16 _depositFeeBP, bool _withUpdate) external onlyOwner nonDuplicated(_lpToken) {
        // Make sure the provided token is ERC20
        _lpToken.balanceOf(address(this));
        require(_strategy.wantLockedTotal() >= 0, "add: invalid strategy");
        require(_allocPoint <= 1e6, "add: invalid allocPoint");
        require(_depositFeeBP <= 601, "add: invalid deposit fee basis points");
        require(address(_lpToken) != address(revolution), "add: no native token pool");

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolExistence[_lpToken] = true;

        poolInfo.push(PoolInfo({
        lpToken : _lpToken,
        allocPoint : _allocPoint,
        lastRewardBlock : lastRewardBlock,
        strategy: _strategy,
        accRevolutionPerShare : 0,
        depositFeeBP : _depositFeeBP,
        lpSupply: 0
        }));

        emit AddPool(poolInfo.length - 1, address(_lpToken), address(_strategy), _allocPoint, _depositFeeBP);
    }

    // Update the given pool's Revolution allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) external onlyOwner {
        require(_allocPoint <= 1e6, "set: invalid allocPoint");
        require(_depositFeeBP <= 601, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;

        emit SetPool(_pid, address(poolInfo[_pid].lpToken), _allocPoint, _depositFeeBP);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        // As we set the multiplier to 0 here after emissionEndBlock
        // deposits aren't blocked after farming ends.
        if (_from > emissionEndBlock)
            return 0;
        if (_to > emissionEndBlock)
            return emissionEndBlock - _from;
        else
            return _to - _from;
    }

    // View function to see pending Revolution on frontend.
    function pendingRevolution(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRevolutionPerShare = pool.accRevolutionPerShare;
        if (block.number > pool.lastRewardBlock && pool.lpSupply != 0 && totalAllocPoint > 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 revolutionReward = (multiplier * revolutionPerBlock * pool.allocPoint) / totalAllocPoint;
            accRevolutionPerShare = accRevolutionPerShare + (( revolutionReward * 1e12) / pool.lpSupply);
        }

        return ((user.amount * accRevolutionPerShare) /  1e12) - user.rewardDebt;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        if (pool.lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 revolutionReward = (multiplier * revolutionPerBlock * pool.allocPoint) / totalAllocPoint;

        // This shouldn't happen, but just in case we stop rewards.
        uint256 totalSupply = revolution.totalSupply();
        if (totalSupply > RevolutionMaximumSupply)
            revolutionReward = 0;
        else if ((totalSupply + revolutionReward) > RevolutionMaximumSupply)
            revolutionReward = RevolutionMaximumSupply - totalSupply;

        if (revolutionReward > 0)
            revolution.mint(address(this), revolutionReward);

        // The first time we reach revolution max supply we solidify the end of farming.
        if (revolution.totalSupply() >= RevolutionMaximumSupply && emissionEndBlock > block.number)
            emissionEndBlock = block.number;

        pool.accRevolutionPerShare = pool.accRevolutionPerShare + ((revolutionReward * 1e12) / pool.lpSupply);
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for Revolution allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        if (_amount > 0 && address(revolutionReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            revolutionReferral.recordReferral(msg.sender, _referrer);
        }

        if (user.amount > 0) {
            uint256 pending = ((user.amount * pool.accRevolutionPerShare) / 1e12) - user.rewardDebt;
            if (pending > 0) {
                safeRevolutionTransfer(msg.sender, pending);
                payReferralCommission(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            uint256 wantBalAfter = pool.lpToken.balanceOf(address(this));
            _amount = wantBalAfter - balanceBefore;
            require(_amount > 0, "we dont accept deposits of 0 size");

            uint256 amountToDepositStrat = _amount;
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = (_amount * pool.depositFeeBP) / 10000;
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                amountToDepositStrat = _amount - depositFee;
            }

            pool.lpToken.safeIncreaseAllowance(address(pool.strategy), amountToDepositStrat);
            uint256 amountDeposit = pool.strategy.deposit(amountToDepositStrat);
            user.amount = user.amount + amountDeposit;
            pool.lpSupply = pool.lpSupply + amountDeposit;

        }
        user.rewardDebt = (user.amount * pool.accRevolutionPerShare) / 1e12;

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);

        uint256 total = pool.strategy.wantLockedTotal();
        require(total > 0, "Total is 0");

        uint256 pending = ((user.amount * pool.accRevolutionPerShare) / 1e12) - user.rewardDebt;
        if (pending > 0) {
            safeRevolutionTransfer(msg.sender, pending);
            payReferralCommission(msg.sender, pending);
        }
        if (_amount > 0) {
            uint256 lpAmountBefore = pool.lpToken.balanceOf(address(this));
            pool.strategy.withdraw(_amount);
            uint256 lpAmountAfter = pool.lpToken.balanceOf(address(this));
            uint256 amountRemoved = lpAmountAfter - lpAmountBefore;

            if (amountRemoved > user.amount) {
                user.amount = 0;
            } else {
                user.amount = user.amount - _amount;
            }

            //            if (amountRemoved < _amount) {
            //                _amount = amountRemoved;
            //            }

            pool.lpToken.safeTransfer(msg.sender, amountRemoved);

            if (pool.lpSupply >= _amount)
                pool.lpSupply = pool.lpSupply - _amount;
            else
                pool.lpSupply = 0;

        }
        user.rewardDebt = (user.amount * pool.accRevolutionPerShare) / 1e12;
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 amount = user.amount;

        uint256 lpAmountBefore = pool.lpToken.balanceOf(address(this));
        pool.strategy.withdraw(amount);
        uint256 lpAmountAfter = pool.lpToken.balanceOf(address(this));
        uint256 amountRemoved = lpAmountAfter - lpAmountBefore;

        user.amount = 0;
        user.rewardDebt = 0;

        //        uint256 wantBal = pool.lpToken.balanceOf(address(this));
        pool.lpToken.safeTransfer(msg.sender, amountRemoved);

        // In the case of an accounting error, we choose to let the user emergency withdraw anyway
        if (pool.lpSupply >= amount)
            pool.lpSupply = pool.lpSupply - amount;
        else
            pool.lpSupply = 0;

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe revolution transfer function, just in case if rounding error causes pool to not have enough Revolutions.
    function safeRevolutionTransfer(address _to, uint256 _amount) internal {
        uint256 revolutionBal = revolution.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > revolutionBal) {
            transferSuccess = revolution.transfer(_to, revolutionBal);
        } else {
            transferSuccess = revolution.transfer(_to, _amount);
        }
        require(transferSuccess, "safeRevolutionTransfer: transfer failed");
    }

    function setFeeAddress(address _feeAddress) external {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "!nonzero");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    function setStartBlock(uint256 _newStartBlock) external onlyOwner {
        require(poolInfo.length == 0);
        require(block.number < startBlock, "farm has already started");
        require(block.number < _newStartBlock, "cannot set start block in the past");
        require(_newStartBlock < 14500000, "invalid startBlock"); //14500000 = Estimated Target Date: Wed Jan 19 2022 10:54:32 GMT+0100 (Central European Standard Time)
        startBlock = _newStartBlock;
        emissionEndBlock = _newStartBlock + 403200; //Farm ends in 2 weeks

        emit UpdateStartBlock(startBlock);
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(revolution), "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
        emit StuckTokenRemoval(_token, _amount);
    }

    // Update the Revolution referral contract address by the owner
    function setRevolutionReferral(IReferralSystem _revolutionReferral) external onlyOwner {
        require(address(_revolutionReferral) != address(0), "revolutionReferral cannot be the 0 address");
        revolutionReferral = _revolutionReferral;

        emit SetRevolutionReferral(address(revolutionReferral));
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(revolutionReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = revolutionReferral.getReferrer(_user);
            uint256 commissionAmount = ((_pending * referralCommissionRate) / 10000);

            if (referrer != address(0) && commissionAmount > 0 && revolution.totalSupply() + commissionAmount <= RevolutionMaximumSupply) {
                revolution.mint(referrer, commissionAmount);
                revolutionReferral.recordReferralCommission(referrer, commissionAmount);
            }
        }
    }
}