// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "hardhat/console.sol";
import {IGame} from "./IGame.sol";
import {Property} from "./Property.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency, CurrencyLibrary} from "../Uniswap/V4-Core/types/Currency.sol";
import {PoolKey} from "../Uniswap/V4-Core/types/PoolKey.sol";
import {MyHook} from "../MyHook.sol";
import {IHooks} from "../Uniswap/V4-Core/interfaces/IHooks.sol";
import {TickMath} from "../Uniswap/V4-Core/libraries/TickMath.sol";

contract Game is IGame /*, VRFConsumerBaseV2*/ {
    //Below is for chainlink
    bytes32 internal keyHash;
    uint256 internal fee;
    uint256 public randomResult;

    address public immutable poolManager;
    MyHook public immutable mainHook;

    //Below is for the game
    uint256 gameID;
    mapping(address => uint256) public playerToGame;
    mapping(uint256 => GameState) public idToGameState;
    mapping(address => bool) public userRoll; //User can roll
    mapping(address => uint256) public userRollsRow; //# of rolls in a row

    string[] usualNamesAndSymbols;
    uint256 constant MAX_STEPS = 40;
    mapping(address => uint256) addressToGame;

    mapping(address => TokenInfo) getCurrencyInfo;

    struct TokenInfo {
        uint8[4] priceStarts;
        uint8[4] priceChanges;
    }

    constructor(
        address _poolManager,
        address _mainHook // address vrfCoordinator
    ) /*VRFConsumerBaseV2(vrfCoordinator)*/ {
        require(
            _poolManager != address(0),
            "Pool manager address cannot be zero."
        );
        poolManager = _poolManager;
        mainHook = MyHook(_mainHook);
        // You can use console.log for debugging purposes
        console.log("Game contract deployed by:", msg.sender);
        console.log("Pool Manager set to:", poolManager);
    }

    //Function for testing
    function reclaimTokens(address token) external {
        IERC20(token).transfer(
            msg.sender,
            IERC20(token).balanceOf(address(this))
        );
    }

    // Implementing the start function from IGame
    function setUp(address selectedToken, uint256 bankStart) external {
        SafeERC20.safeTransferFrom(
            IERC20(selectedToken),
            msg.sender,
            address(this),
            bankStart
        );
        idToGameState[gameID].players.push(msg.sender);
        addressToGame[msg.sender] = gameID;
        idToGameState[gameID].numberOfPlayers++;
        idToGameState[gameID].chosenCurrency = selectedToken;

        //Mint 8 ERC20s with a balance of 4 for each
        _createAndAssignProperties(gameID);
        _prepareProperties(idToGameState[gameID].propertyList, selectedToken);

        //Open up a game for other users to join
        //Add liquidity with the pools

        gameID++;
    }

    function _prepareProperties(
        Property[] memory propertyList,
        address selectedToken
    ) internal {
        for (uint256 i = 0; i < propertyList.length; i++) {
            Property property = propertyList[i];
            _preparePoolProperty(property, selectedToken);
        }
    }

    function _preparePoolProperty(Property property, address token) internal {
        //First we need to initalize the pool
        address token0 = address(property);
        address token1 = token;
        if (token1 < token0) {
            address temp = token0;
            token0 = token1;
            token1 = temp;
        }
        Currency currency_property = Currency.wrap(token0);
        Currency currency_token = Currency.wrap(token1);

        uint24 _fee = 0;
        int24 tickSpacing = 60;
        address hookAddy = address(mainHook);
        IHooks hooks = IHooks(hookAddy);

        PoolKey memory key = PoolKey(
            currency_property,
            currency_token,
            _fee,
            tickSpacing,
            hooks
        );
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(0);

        mainHook.startPool(key, sqrtPrice, "0x", block.timestamp + 10);
        // console.log("Pool started");
        uint256 totalTokenNumber = 4 *
            property.getPriceStart() +
            6 *
            property.getPriceIncrease();
        //Then we need to add liquidity
        SafeERC20.safeTransferFrom(
            IERC20(token),
            msg.sender,
            address(this),
            totalTokenNumber
        );
        SafeERC20.safeTransfer(
            IERC20(token),
            address(mainHook),
            totalTokenNumber
        );
        // mainHook.addProperty(property);
    }

    function _createAndAssignProperties(uint256 _gameID) internal {
        uint8[4] memory usualList = [1, 6, 11, 16]; // These are the positions that all of the properties start on
        uint8[4] memory priceStarts;
        uint8[4] memory priceChanges;
        TokenInfo memory tInfo = getCurrencyInfo[
            idToGameState[gameID].chosenCurrency
        ];

        if (tInfo.priceStarts.length > 0) {
            priceStarts = tInfo.priceStarts;
            priceChanges = tInfo.priceChanges;
        } else {
            priceStarts = [60, 120, 160, 250];
            priceChanges = [5, 10, 20, 50];
        }

        for (uint256 i = 0; i < usualNamesAndSymbols.length; i++) {
            Property property = new Property(
                usualNamesAndSymbols[i],
                usualNamesAndSymbols[i + 1],
                4,
                usualList[i / 2],
                priceStarts[i / 2],
                priceChanges[i / 2]
            );
            // console.log(usualNamesAndSymbols[i], usualNamesAndSymbols[i + 1]);
            //Add all of the ERC20s to the game state
            idToGameState[_gameID].propertyList.push(property);
            i++;
        }
    }

    function joinGame() external {
        if (gameID == 0) {
            revert("No games exist");
        }
        uint256 curentGame = gameID - 1;
        idToGameState[curentGame].players.push(msg.sender);
        addressToGame[msg.sender] = gameID;
        idToGameState[curentGame].numberOfPlayers++;
    }

    function startGame() external {
        //This just starts the most recently made game
        //This will begin the game for all players, and begin a move for the first player.
        if (gameID == 0) {
            revert("A game has not been setUp() yet");
        }
        uint256 curentGameID = gameID - 1;
        userRoll[msg.sender] = true;
        idToGameState[curentGameID].currentPlayer = msg.sender;
        emit GameStarted(msg.sender, gameID);
    }

    function _rollDice(
        address user
    ) public returns (bool snake, uint256 total) {
        //Upon implementation add chainlink here
        uint256 dice1 = (uint256(
            keccak256(
                abi.encodePacked(block.timestamp, block.prevrandao, msg.sender)
            )
        ) % 6) + 1;

        uint256 dice2 = (uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    msg.sender,
                    dice1
                )
            )
        ) % 6) + 1;
        total = dice1 + dice2;
        emit RolledDice(user, dice1, dice2);
        if (dice1 == dice1) {
            snake = true;
        }
    }

    function beginMove() external {
        require(gameID > 0, "No Game Created");
        uint256 currentGameID = addressToGame[msg.sender];

        require(
            idToGameState[currentGameID].currentPlayer == msg.sender,
            "Must be current Player"
        );

        require(userRoll[msg.sender], "User cannot roll");
        userRoll[msg.sender] = false;
        (bool rollAgain, uint256 stepsFoward) = _rollDice(msg.sender); //We would stop here and wait for chainlink to respnd if using it
        if (userInJail[msg.sender]) {
            if (rollAgain) {
                //User leaves jail
                userInJail[msg.sender] = false;
            }
            return; //No matter what, just sit there
        }

        if (rollAgain) {
            userRoll[msg.sender] = true;
            userRollsRow[msg.sender]++;
            if (userRollsRow[msg.sender] > 3) {
                sendUserToJail(msg.sender);
            }
        }

        _updatePlayerPosition(currentGameID, msg.sender, stepsFoward);
    }

    function _incrementGameState(address newPlayer, uint256 _gameID) internal {
        address oldCurrentPlayer = idToGameState[_gameID].currentPlayer;
        require(
            userRoll[oldCurrentPlayer],
            "can not change while a user can still roll"
        );
        //Change current player
        //Reset their total number of rolls in a  row
        userRollsRow[oldCurrentPlayer] = 0;

        idToGameState[_gameID].currentPlayer = newPlayer;
        userRoll[newPlayer] = true;
    }

    function _getNextPlayer(
        uint256 _gameID
    ) internal returns (address newPlayer) {
        address oldCurrentPlayer = idToGameState[_gameID].currentPlayer;
        uint i = 0;
        for (i = 0; i < idToGameState[_gameID].players.length; i++) {
            if (idToGameState[_gameID].players[i] == oldCurrentPlayer) {
                break;
            }
        }
        uint256 nextIndex = (i + 1) % idToGameState[_gameID].players.length;
        //Lets say there are 3 players
        // 3 % 3
        return idToGameState[_gameID].players[nextIndex];
    }

    function testMove(uint256 stepsFoward, bool rollAgain) external {
        require(gameID > 0, "No Game Created");
        uint256 currentGameID = addressToGame[msg.sender];

        require(
            idToGameState[currentGameID].currentPlayer == msg.sender,
            "Must be current Player"
        );

        require(userRoll[msg.sender], "User cannot roll");
        userRoll[msg.sender] = false;
        // (bool rollAgain, uint256 steps)//We would stop here and wait for chainlink to respnd if using it
        if (userInJail[msg.sender]) {
            if (rollAgain) {
                //User leaves jail
                userInJail[msg.sender] = false;
            }
            return; //No matter what, just sit there
        }

        if (rollAgain) {
            userRoll[msg.sender] = true;
            userRollsRow[msg.sender]++;
            if (userRollsRow[msg.sender] > 3) {
                sendUserToJail(msg.sender);
            }
        }

        _updatePlayerPosition(currentGameID, msg.sender, stepsFoward);
    }

    // function fulfillRandomness(
    //     bytes32 requestId,
    //     uint256 randomness
    // ) internal override {
    //     randomResult = randomness;
    //     // Add additional logic to handle randomness
    // _updatePlayerPosition(currentGameID, msg.sender, stepsFoward);
    // }

    function _updatePlayerPosition(
        uint256 _gameID,
        address player,
        uint256 stepsFoward
    ) internal {
        idToGameState[_gameID].playerPosition[player] += stepsFoward;
        if (stepsFoward >= MAX_STEPS) {
            emit CrossedGo(player);
            //Need to give the player moneys here!
            //User arrived at the start
            idToGameState[_gameID].playerPosition[player] -= MAX_STEPS;
        }
        uint256 finalPosition = idToGameState[_gameID].playerPosition[player];
        if (finalPosition == 5) {
            //They are visiitng jail
            emit VisitJail(player);
        }
        if (finalPosition == 10) {
            //They are getting an air drop
            //Deposit their total number of steps up until that point
            if (block.timestamp % 5 == 0) {
                emit FoundAsSybil(player);
            } else {
                emit ReceivingAirdrop(player);
            }
        }
    }

    function addNames(string[] memory list) public {
        require(list.length % 2 == 0, "Must be even");
        require(list.length > 0, "Must have stuff ");
        usualNamesAndSymbols = list;
    }

    function purchaseProperty() public returns (uint256) {}

    function sellProperty() public returns (uint256) {}

    mapping(address => uint256) public daysInJail;
    mapping(address => bool) public userInJail;

    function sendUserToJail(address user) public {
        userInJail[user] = true;
    }

    function getMyPosition() public view returns (uint256) {}

    function getMyProperties() public view returns (uint256) {}

    function getAllProperties() public view returns (string[] memory list) {
        return usualNamesAndSymbols;
    }

    function getPropertyValue() public view returns (uint256) {}

    //These are all of the helper fucntions for a game
    function getActiveNumberOfPlayers() public view returns (uint256) {
        if (gameID == 0) {
            return 0;
        }
        uint256 currentGameID = gameID - 1;
        return idToGameState[currentGameID].numberOfPlayers;
    }

    function getActiveGameID() public view returns (uint256) {
        if (gameID == 0) {
            return 0;
        }
        uint256 currentGameID = gameID - 1;
        return currentGameID;
    }

    function getActivePlayers() public view returns (address[] memory) {
        if (gameID == 0) {
            address[] memory list;
            return list;
        }
        uint256 currentGameID = gameID - 1;
        return idToGameState[currentGameID].players;
    }

    function getCurrentChosenCurrency() public view returns (address) {
        if (gameID == 0) {
            return address(0);
        }
        uint256 currentGameID = gameID - 1;
        return idToGameState[currentGameID].chosenCurrency;
    }

    function getCurrentPlayer() public view returns (address player) {
        if (gameID == 0) {
            return address(0);
        }
        uint256 currentGameID = gameID - 1;
        return idToGameState[currentGameID].currentPlayer;
    }

    function getPlayerPosition(
        address user
    ) public view returns (uint256 position) {
        if (gameID == 0) {
            return 0;
        }
        uint256 currentGameID = gameID - 1;
        return idToGameState[currentGameID].playerPosition[user];
    }

    function getBankBalance() public view returns (uint256 balance) {
        if (gameID == 0) {
            return 0;
        }
        uint256 currentGameID = gameID - 1;
        return
            IERC20(idToGameState[currentGameID].chosenCurrency).balanceOf(
                address(this)
            );
    }
}

//Idea for how game is going to work
//There are 8 different property groups
// There are railways
//Community Chests & Chance Cards
//Free Parking
//Jail
//Go

//The struct will contain all of the players
//Lets say there are four players

//We use ChainLink for getting Dice
