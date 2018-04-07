pragma solidity ^0.4.19;

import "zeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "zeppelin-solidity/contracts/math/SafeMath.sol";

contract ParsecBridge {
  using SafeMath for uint256;
  
  /*
   *  an epoch describes a sections in block height. 
   *
   *       genesis/archive epoch             payout epoch                consensus window
   *                ↓                             ↓                              ↓               
   *    0*EL ->    ...    -> 1*EL-1   2*EL ->    ...    -> 3*EL-1    3*EL ->    ...    -> 4*EL-x 
   *  |-----------------------------|------------------------------|-----------------------------
   *  |                             |                              |
   *  |                             |                              |      /-> b[3*EL+y]
   *  | l[0] ->  ...  -> l[1*EL-1] -> b[2*EL] -> ... -> b[3*EL-1] -> b[3*EL] ->  ...    -> b[4*EL-x]
   *  |                             |                              |               \-> b[3*EL+z]
   *  |                             |                              |
   *  |-----------------------------|------------------------------|-----------------------------
   *  EL = epoch-length, l[height] = logEntry, b[height] = block, 0 < x/y/z < EL
   *
   * Consensus Window: This is a sliding window with the size of epoch-length blocks spanning back
   * ---------------- from the chain tip. Blocks in this window can be challenged and invalidated.
   *                  In this window the tree can branch, and competing branches can be clipped.
   *                  Blocks can be submitted at chain-height or height + 1. The block submission
   *                  prunes all branches at (height - epoch-length), leving only a trunk of blocks
   *                  on the valid chain in storage after the consensus window.
   * 
   * Payout Epoch: This epoch starts at a distance of x * EL from the genesis block. It is the youngest 
   * ------------ epoch that has more than epoch-length distance from the tip. Hence, it contains 
   *              a trunk of epoch-length blocks. Operators claim rewards from blocks in the payout
   *              epoch. The blocks in the payout epoch are on the longest chain and final, determined
   *              by pruning and clipping during the consensus window.
   *
   * Archive Epochs: These epochs also start at distances of x * EL from the genesis block and span
   * -------------- until the payout epoch. In these epochs the block data is not needed any more.
   *                Blocks are archived by deletion and replaced by log-entlies of block-hash and height.
   */
  
  bytes32 constant genesis = 0x4920616d207665727920616e6772792c20627574206974207761732066756e21; // "I am very angry, but it was fun!" @victor
  ERC20 public token;

  event NewHeight(uint256 blockNumber, bytes32 indexed root);
  event ArchiveBlock(uint256 indexed blockNumber, bytes32 root);
  event OperatorJoin(address indexed signerAddr, uint256 blockNumber);
  event OperatorLeave(address indexed signerAddr, uint256 blockNumber);

  struct Block {
    bytes32 parent; // the id of the parent node
    uint64 height;  // the hight this block is stored at
    uint32 parentIndex; //  the position of this node in the Parent's children list
    address operator; // the operator that submitted the block
    bytes32[] children; // unordered list of children below this node
    // more node attributes here
  }
  mapping(bytes32 => Block) public chain;

  uint32 public parentBlockInterval; // how often plasma blocks can be submitted max
  uint64 public lastParentBlock; // last ethereum block when plasma block submitted
  uint32 public operatorCount; // number of staked operators
  uint32 public epochLength; // length of 1 epoche in child blocks
  uint64 public blockReward; // reward per single block
  uint32 public stakePeriod;
  bytes32 public tipHash;    // hash of first block that has extended chain to some hight

  struct Operator {
    // joinedAt is unix timestamp while operator active.
    // once operator requested leave joinedAt set to block height when requested exit
    uint64 joinedAt; 
    uint64 claimedUntil; // the epoche until which all reward claims have been processed
    uint256 stakeAmount; // amount of staken tokens
  }
  mapping(address => Operator) public operators;


  function ParsecBridge(ERC20 _token, uint32 _parentBlockInterval, uint32 _epochLength, uint64 _blockReward, uint32 _stakePeriod) public {
    require(_token != address(0));
    token = _token;
    Block memory genBlock;
    genBlock.operator = msg.sender;
    genBlock.parent = genesis; 
    tipHash = keccak256(genesis, uint64(0), bytes32(0));
    chain[tipHash] = genBlock;
    parentBlockInterval = _parentBlockInterval;
    epochLength = _epochLength;
    lastParentBlock = uint64(block.number);
    blockReward = _blockReward;
    stakePeriod = _stakePeriod;
  }
  
  modifier mint() {
    // todo: mine some tokens, if needed
    _;
  }

  /*
   * Add an operator
   */
  function join(uint256 amount) public {
    require(operators[msg.sender].stakeAmount + amount <= token.totalSupply().div(epochLength).mul(5));
    require(amount >= token.totalSupply().div(epochLength));
    require(token.allowance(msg.sender, this) >= amount);
    require(operatorCount < epochLength);

    token.transferFrom(msg.sender, this, amount);
    operatorCount++;
    
    operators[msg.sender] = Operator({
      joinedAt: uint32(now),
      claimedUntil: ((chain[tipHash].height / epochLength) * epochLength), // most recent epoche
      stakeAmount: amount
    });
    OperatorJoin(msg.sender, chain[tipHash].height);
  }

  function createTx(uint64 _height, bytes32[] _coinbase, address _op) pure returns (bytes32) {
    uint8 txType = 0;
    uint8 txInNum = uint8(_coinbase.length);
    uint8 txOutNum = 1;
    return keccak256(txType, _height, txInNum, _coinbase, txOutNum, uint256(0), _op);
  }

  /*
   * operator submits coinbase with prove of inclusion in longest chain
   * tx structure
   * type 4b
   * b# 8b
   * #txin 1b
   * in0 1 - 129
   * #txout 1b
   * txOut 20
   * 
   * type4 in
   * #prevClaims 1b
   * claimx 32b  <- hash of block in same claim epoch
   * claimy 32b
   * 
   * type4 out
   * value 32b
   * address 20b
   *
   *          pe     cw
   *  0 - 7 8 - 15 16 - 23
   *
   *  ae(0-1) pe      cw(17-25)
   *  0 - 7 8 - 15 16 - 23 24 - 25  
   *
   *  ae(0-6) pe      cw(23-30)
   *  0 - 7 8 - 15 16 - 23 24 - 30  
   *
   *    ae(e-7)      pe   cw(24-31)
   *  0 - 7 8 - 15 16 - 23 24 - 31  
   */  
  function claimReward(bytes32 _hash, bytes32[] _coinbase, bytes32[] _proof, uint8 v) public {
    // receive up to 5 hashes of blocks
    // first one to hold references to all previous ones
    Block memory node = chain[_hash];
    // claim epoche must have passed challenge period
    uint256 payoutEpoch = uint256(node.height).div(epochLength).mul(epochLength);
    require(payoutEpoch >= chain[tipHash].height - (3 * epochLength));
    require(payoutEpoch < uint256(chain[tipHash].height - epochLength).div(epochLength).mul(epochLength));
    // check operator
    if (operators[msg.sender].claimedUntil > 0) {
      require(operators[msg.sender].claimedUntil < payoutEpoch);
    }
    uint256 claimCount = (operators[msg.sender].stakeAmount * epochLength) / token.totalSupply();
    require(_coinbase.length < claimCount);
    // all 5 must have been mined by operator in same claim epoche
    require(node.height >= payoutEpoch);
    require(node.height < payoutEpoch + epochLength);
    require(node.operator == msg.sender);
    for (uint256 i = 0; i < _coinbase.length; i++) {
      Block memory coinbase = chain[_coinbase[i]];
      require(coinbase.height >= payoutEpoch);
      require(coinbase.height < payoutEpoch + epochLength);
      require(coinbase.operator == msg.sender);
    }
    // reconstruct tx and check tx proof
    bytes32 hash = createTx(node.height, _coinbase, msg.sender);
    // check proof
    for (i = 2; i < _proof.length; i++) {
      hash = keccak256(hash, _proof[i]);
    }
    require(_hash == keccak256(node.parent, node.height, hash, v, _proof[0], _proof[1]));

    // reward calculated and payed
    token.transfer(msg.sender, (_coinbase.length + 1).mul(blockReward));
    // epoch marked as claimed
    operators[msg.sender].claimedUntil = uint64(payoutEpoch + epochLength);
  }

  /*
   * operator requests to leave
   */
  function requestLeave() public {
    require(operators[msg.sender].stakeAmount > 0);
    require(operators[msg.sender].joinedAt < now - (stakePeriod));
    operators[msg.sender].joinedAt = chain[tipHash].height;
    // now the operator will have to wait another 2 epochs
    // before being able to get a pay-out
  }

  /*
   * operator is returned the stake and removed
   */
  function payout(address signerAddr) public {
    Operator memory op = operators[signerAddr];
    // avoid operations for empty fields
    require(op.joinedAt > 0);
    // empty operator
    if (op.stakeAmount > 0) {
      // operator that has requested leave
      require(op.joinedAt <= chain[tipHash].height - (2 * epochLength));
      token.transfer(signerAddr, op.stakeAmount);
    }
    delete operators[signerAddr];
    operatorCount--;
    OperatorLeave(signerAddr, chain[tipHash].height);
  }

  function submitBlockAndPrune(bytes32 prevHash, bytes32 root, uint8 v, bytes32 r, bytes32 s, bytes32[] orphans) public {
    submitBlock(prevHash, root, v, r, s);
    // delete all blocks that have non-existing parent
    for (uint256 i = 0; i < orphans.length; i++) {
      Block memory orphan = chain[orphans[i]];
      // if orphan exists
      if (orphan.parent > 0) {
        uint256 tmp = chain[tipHash].height;
        // if block is behind archive horizon
        if (tmp >= (3 * epochLength) && orphan.height <= tmp  - (3 * epochLength)) {
          ArchiveBlock(orphan.height, orphans[i]);
          tmp = 0; // mark delete
        }
        // if block is orphaned
        else if (chain[orphan.parent].parent == 0) {          
          tmp = 0; // mark delete
        }
        // if marked, then delete
        if (tmp == 0) {
          delete chain[orphans[i]];
        }
      }
    }
  }

  /*
   * submit a new block on top or next to the tip
   *
   * block hash process:
   * 1. block generated: prevHash, height, root
   * 2. sigHash: keccak256(prevHash, height, root) + priv => v, r, s
   * 3. block hash: keccak256(prevHash, height, root, v, r, s)
   */
  function submitBlock(bytes32 prevHash, bytes32 root, uint8 v, bytes32 r, bytes32 s) public {
    // check parent node exists
    require(chain[prevHash].parent > 0);
    // calculate height
    uint64 newHeight = chain[prevHash].height + 1;
    // TODO recover operator address and check membership
    bytes32 sigHash = keccak256(prevHash, newHeight, root);
    address operatorAddr = ecrecover(sigHash, v, r, s);
    require(operators[operatorAddr].stakeAmount > 0);
    // make sure block is placed in consensus window
    uint256 maxDepth = (chain[tipHash].height < epochLength) ? 0 : chain[tipHash].height - epochLength;
    require(maxDepth <= newHeight && newHeight <= chain[tipHash].height + 1);
    // make hash of new block
    bytes32 newHash = keccak256(prevHash, newHeight, root, v, r, s);
    // check this block has not been submitted yet
    require(chain[newHash].parent == 0);
    // do some magic if chain extended
    if (newHeight > chain[tipHash].height) {
      // new blocks can only be submitted every x Ethereum blocks
      require(block.number >= lastParentBlock + parentBlockInterval);
      tipHash = newHash;
      if (newHeight > epochLength) {
        // prune some blocks
        // iterate backwards for 1 epoche
        bytes32 nextParent = chain[prevHash].parent;
        while(chain[nextParent].height > newHeight - epochLength) {
          nextParent = chain[nextParent].parent;        
        }
        // prune chain 
        prune(nextParent);
      }
      lastParentBlock = uint64(block.number);
      NewHeight(newHeight, root);
    }
    // store the block 
    Block memory newBlock;
    newBlock.parent = prevHash;
    newBlock.height = newHeight;
    newBlock.operator = operatorAddr;
    newBlock.parentIndex = uint32(chain[prevHash].children.push(newHash) - 1);
    chain[newHash] = newBlock;
  }

  /*
   * sets a block as the only branch in parent block
   * and deletes all other branches
   */
  function prune(bytes32 hash) internal {
    Block storage parent = chain[chain[hash].parent];
    uint256 i = chain[hash].parentIndex;
    if (i > 0) {
      // swap with child 0
      parent.children[i] = parent.children[0];
      parent.children[0] = hash;
      chain[hash].parentIndex = 0;
    }
    // delete other blocks
    for (i = parent.children.length - 1; i > 0; i--) {
      delete chain[parent.children[i]];
    }
    parent.children.length = 1;
  }
  
  function getBranchCount(bytes32 nodeId) public constant returns(uint childCount) {
    return(chain[nodeId].children.length);
  }

  function getBranchAtIndex(bytes32 nodeId, uint index) public constant returns(bytes32 childId) {
    return chain[nodeId].children[index];
  }

  /*
   * todo
   */    
  function getHighest() public constant returns (bytes32, uint64, uint32, address) {
    return (chain[tipHash].parent, chain[tipHash].height, chain[tipHash].parentIndex, chain[tipHash].operator);
  }

  // data = [winnerHash, claimCountTotal, operator, operator ...]
  // operator: 1b claimCountByOperator - 10b 0x - 1b stake - 20b address
  function dfs(bytes32[] _data, bytes32 _nodeHash) internal constant returns(bytes32[] data) {
    Block memory node = chain[_nodeHash];
    // visit this node
    data = new bytes32[](_data.length);
    for (uint256 i = 1; i < _data.length; i++) {
      data[i] = _data[i];
    }
    // find the operator that mined this block
    i = 2;
    while(address(data[i]) != node.operator) {
      require(i++ < data.length);
    }
    // parse operator stake and claim status
    uint256 claimCountByOperator = uint256(data[i]) >> 248;
    uint256 stakeByOperator = uint168(data[i]) >> 160;
    // if operator can claim rewards, assign
    if (claimCountByOperator < stakeByOperator) {
      data[i] = bytes32(claimCountByOperator + 1 << 248) | bytes32(uint248(data[i]));
      data[1] = bytes32(uint256(data[1]) + (1 << 128));
      data[0] = _nodeHash;
    }
    // more of tree to walk
    if (node.children.length > 0) {
      bytes32[][] memory options = new bytes32[][](data.length);
      for (i = 0; i < node.children.length; i++) {
        options[i] = dfs(data, node.children[i]);
      }
      for (i = 0; i < node.children.length; i++) {
        // compare options, return the best
        if (uint256(options[i][1]) > uint256(data[1])) {
          data[0] = options[i][0];
          data[1] = options[i][1];
        }
      }
    }
    else {
      data[0] = _nodeHash;
      data[1] = bytes32(uint256(data[1]) + 1);
    }
    // else - reached a tip
    // return data
  }

  function getTip(address[] _operators) public constant returns (bytes32, uint256) {
    // find consensus horizon
    bytes32 consensusHorizon = chain[tipHash].parent;
    uint256 depth = (chain[tipHash].height < epochLength) ? 0 : chain[tipHash].height - epochLength;
    while(chain[consensusHorizon].height > depth) {
      consensusHorizon = chain[consensusHorizon].parent;        
    }

    // create data structure for depth first search
    bytes32[] memory data = new bytes32[](_operators.length + 2);
    for (uint i = 2; i < _operators.length + 2; i++) {
      data[i] = bytes32(((operators[_operators[i-2]].stakeAmount * epochLength) / token.totalSupply()) << 160) | bytes32(_operators[i-2]);
    }
    // run search
    bytes32[] memory rsp = dfs(data, consensusHorizon);
    // return result
    return (rsp[0], uint256(rsp[1]) >> 128);
  }
  
  /*
   * todo
   */  
  function getBlock(uint256 height) public view returns (bytes32 root, address operator) {
    require(height <= chain[tipHash].height);
    return (bytes32(height),0);
  }

}
