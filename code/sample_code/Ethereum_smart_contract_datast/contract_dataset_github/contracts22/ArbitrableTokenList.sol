/**
 *  @authors: [@mtsalenc, @clesaege]
 *  @reviewers: [@clesaege, @unknownunknown1, @ferittuncer]
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 *  @tools: [MythX]
 */
/* solium-disable max-len*/
pragma solidity ^0.4.24;

import "../arbitration/Arbitrable.sol";
import "./PermissionInterface.sol";
import "../../libraries/CappedMath.sol";

/**
 *  @title ArbitrableTokenList
 *  This contract is an arbitrable token curated registry for tokens, sometimes referred to as a Token² Curated Registry. Users can send requests to register or remove tokens from the registry, which can in turn, be challenged by parties that disagree with them.
 *  A crowdsourced insurance system allows parties to contribute to arbitration fees and win rewards if the side they backed ultimately wins a dispute.
 *  NOTE: This contract trusts that the Arbitrator is honest and will not reenter or modify its costs during a call. This contract is only to be used with an arbitrator returning appealPeriod and having non-zero fees. The governor contract (which will be a DAO) is also to be trusted.
 */
contract ArbitrableTokenList is PermissionInterface, Arbitrable {
    using CappedMath for uint; // Operations bounded between 0 and 2**256 - 1.

    /* Enums */

    enum TokenStatus {
        Absent, // The token is not in the registry.
        Registered, // The token is in the registry.
        RegistrationRequested, // The token has a request to be added to the registry.
        ClearingRequested // The token has a request to be removed from the registry.
    }

    enum Party {
        None,      // Party per default when there is no challenger or requester. Also used for unconclusive ruling.
        Requester, // Party that made the request to change a token status.
        Challenger // Party that challenges the request to change a token status.
    }

    // ************************ //
    // *  Request Life Cycle  * //
    // ************************ //
    // Changes to the token status are made via requests for either listing or removing a token from the Token² Curated Registry.
    // To make or challenge a request, a party must pay a deposit. This value will be rewarded to the party that ultimately wins a dispute. If no one challenges the request, the value will be reimbursed to the requester.
    // Additionally to the challenge reward, in the case a party challenges a request, both sides must fully pay the amount of arbitration fees required to raise a dispute. The party that ultimately wins the case will be reimbursed.
    // Finally, arbitration fees can be crowdsourced. To incentivise insurers, an additional fee stake must be deposited. Contributors that fund the side that ultimately wins a dispute will be reimbursed and rewarded with the other side's fee stake proportionally to their contribution.
    // In summary, costs for placing or challenging a request are the following:
    // - A challenge reward given to the party that wins a potential dispute.
    // - Arbitration fees used to pay jurors.
    // - A fee stake that is distributed among insurers of the side that ultimately wins a dispute.

    /* Structs */

    struct Token {
        string name; // The token name (e.g. Pinakion).
        string ticker; // The token ticker (e.g. PNK).
        address addr; // The Ethereum address of the token.
        string symbolMultihash; // The multihash of the token symbol.
        TokenStatus status; // The status of the token.
        Request[] requests; // List of status change requests made for the token.
    }

    // Some arrays below have 3 elements to map with the Party enums for better readability:
    // - 0: is unused, matches `Party.None`.
    // - 1: for `Party.Requester`.
    // - 2: for `Party.Challenger`.
    struct Request {
        bool disputed; // True if a dispute was raised.
        uint disputeID; // ID of the dispute, if any.
        uint submissionTime; // Time when the request was made. Used to track when the challenge period ends.
        bool resolved; // True if the request was executed and/or any disputes raised were resolved.
        address[3] parties; // Address of requester and challenger, if any.
        Round[] rounds; // Tracks each round of a dispute.
        Party ruling; // The final ruling given, if any.
        Arbitrator arbitrator; // The arbitrator trusted to solve disputes for this request.
        bytes arbitratorExtraData; // The extra data for the trusted arbitrator of this request.
    }

    struct Round {
        uint[3] paidFees; // Tracks the fees paid by each side on this round.
        bool[3] hasPaid; // True when the side has fully paid its fee. False otherwise.
        uint feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint[3]) contributions; // Maps contributors to their contributions for each side.
    }

    /* Storage */
    
    // Constants
    
    uint RULING_OPTIONS = 2; // The amount of non 0 choices the arbitrator can give.

    // Settings
    address public governor; // The address that can make governance changes to the parameters of the Token² Curated Registry.
    uint public requesterBaseDeposit; // The base deposit to make a request.
    uint public challengerBaseDeposit; // The base deposit to challenge a request.
    uint public challengePeriodDuration; // The time before a request becomes executable if not challenged.
    uint public metaEvidenceUpdates; // The number of times the meta evidence has been updated. Used to track the latest meta evidence ID.

    // The required fee stake that a party must pay depends on who won the previous round and is proportional to the arbitration cost such that the fee stake for a round is stake multiplier * arbitration cost for that round.
    // Multipliers are in basis points.
    uint public winnerStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that won the previous round.
    uint public loserStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that lost the previous round.
    uint public sharedStakeMultiplier; // Multiplier for calculating the fee stake that must be paid in the case where there isn't a winner and loser (e.g. when it's the first round or the arbitrator ruled "refused to rule"/"could not rule").
    uint public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    // Registry data.
    mapping(bytes32 => Token) public tokens; // Maps the token ID to the token data.
    mapping(address => mapping(uint => bytes32)) public arbitratorDisputeIDToTokenID; // Maps a dispute ID to the ID of the token with the disputed request. On the form arbitratorDisputeIDToTokenID[arbitrator][disputeID].
    bytes32[] public tokensList; // List of IDs of submitted tokens.

    // Token list
    mapping(address => bytes32[]) public addressToSubmissions; // Maps addresses to submitted token IDs.

    /* Modifiers */

    modifier onlyGovernor {require(msg.sender == governor, "The caller must be the governor."); _;}

    /* Events */

    /**
     *  @dev Emitted when a party submits a new token.
     *  @param _name The token name (e.g. Pinakion).
     *  @param _ticker The token ticker (e.g. PNK).
     *  @param _symbolMultihash The keccak256 multihash of the token symbol image.
     *  @param _address The token address.
     */
    event TokenSubmitted(string _name, string _ticker, string _symbolMultihash, address indexed _address);

    /** @dev Emitted when a party makes a request to change a token status.
     *  @param _tokenID The ID of the affected token.
     *  @param _registrationRequest Whether the request is a registration request. False means it is a clearing request.
     */
    event RequestSubmitted(bytes32 indexed _tokenID, bool _registrationRequest);

    /**
     *  @dev Emitted when a party makes a request, dispute or appeals are raised, or when a request is resolved.
     *  @param _requester Address of the party that submitted the request.
     *  @param _challenger Address of the party that has challenged the request, if any.
     *  @param _tokenID The token ID. It is the keccak256 hash of it's data.
     *  @param _status The status of the token.
     *  @param _disputed Whether the token is disputed.
     *  @param _appealed Whether the current round was appealed.
     */
    event TokenStatusChange(
        address indexed _requester,
        address indexed _challenger,
        bytes32 indexed _tokenID,
        TokenStatus _status,
        bool _disputed,
        bool _appealed
    );

    /** @dev Emitted when a reimbursements and/or contribution rewards are withdrawn.
     *  @param _tokenID The ID of the token from which the withdrawal was made.
     *  @param _contributor The address that sent the contribution.
     *  @param _request The request from which the withdrawal was made.
     *  @param _round The round from which the reward was taken.
     *  @param _value The value of the reward.
     */
    event RewardWithdrawal(bytes32 indexed _tokenID, address indexed _contributor, uint indexed _request, uint _round, uint _value);

    
    /* Constructor */

    /**
     *  @dev Constructs the arbitrable token curated registry.
     *  @param _arbitrator The trusted arbitrator to resolve potential disputes.
     *  @param _arbitratorExtraData Extra data for the trusted arbitrator contract.
     *  @param _registrationMetaEvidence The URI of the meta evidence object for registration requests.
     *  @param _clearingMetaEvidence The URI of the meta evidence object for clearing requests.
     *  @param _governor The trusted governor of this contract.
     *  @param _requesterBaseDeposit The base deposit to make a request.
     *  @param _challengerBaseDeposit The base deposit to challenge a request.
     *  @param _challengePeriodDuration The time in seconds, parties have to challenge a request.
     *  @param _sharedStakeMultiplier Multiplier of the arbitration cost that each party must pay as fee stake for a round when there isn't a winner/loser in the previous round (e.g. when it's the first round or the arbitrator refused to or did not rule). In basis points.
     *  @param _winnerStakeMultiplier Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points.
     *  @param _loserStakeMultiplier Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points.
     */
    constructor(
        Arbitrator _arbitrator,
        bytes _arbitratorExtraData,
        string _registrationMetaEvidence,
        string _clearingMetaEvidence,
        address _governor,
        uint _requesterBaseDeposit,
        uint _challengerBaseDeposit,
        uint _challengePeriodDuration,
        uint _sharedStakeMultiplier,
        uint _winnerStakeMultiplier,
        uint _loserStakeMultiplier
    ) Arbitrable(_arbitrator, _arbitratorExtraData) public {
        emit MetaEvidence(0, _registrationMetaEvidence);
        emit MetaEvidence(1, _clearingMetaEvidence);

        governor = _governor;
        requesterBaseDeposit = _requesterBaseDeposit;
        challengerBaseDeposit = _challengerBaseDeposit;
        challengePeriodDuration = _challengePeriodDuration;
        sharedStakeMultiplier = _sharedStakeMultiplier;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    
    /* External and Public */
    
    // ************************ //
    // *       Requests       * //
    // ************************ //

    /** @dev Submits a request to change a token status. Accepts enough ETH to fund a potential dispute considering the current required amount and reimburses the rest. TRUSTED.
     *  @param _name The token name (e.g. Pinakion).
     *  @param _ticker The token ticker (e.g. PNK).
     *  @param _addr The Ethereum address of the token.
     *  @param _symbolMultihash The multihash of the token symbol.
     */
    function requestStatusChange(
        string _name,
        string _ticker,
        address _addr,
        string _symbolMultihash
    )
        external
        payable
    {
        bytes32 tokenID = keccak256(
            abi.encodePacked(
                _name,
                _ticker,
                _addr,
                _symbolMultihash
            )
        );

        Token storage token = tokens[tokenID];
        if (token.requests.length == 0) {
            // Initial token registration.
            token.name = _name;
            token.ticker = _ticker;
            token.addr = _addr;
            token.symbolMultihash = _symbolMultihash;
            tokensList.push(tokenID);
            addressToSubmissions[_addr].push(tokenID);
            emit TokenSubmitted(_name, _ticker, _symbolMultihash, _addr);
        }

        // Update token status.
        if (token.status == TokenStatus.Absent)
            token.status = TokenStatus.RegistrationRequested;
        else if (token.status == TokenStatus.Registered)
            token.status = TokenStatus.ClearingRequested;
        else
            revert("Token already has a pending request.");

        // Setup request.
        Request storage request = token.requests[token.requests.length++];
        request.parties[uint(Party.Requester)] = msg.sender;
        request.submissionTime = now;
        request.arbitrator = arbitrator;
        request.arbitratorExtraData = arbitratorExtraData;
        Round storage round = request.rounds[request.rounds.length++];

        emit RequestSubmitted(tokenID, token.status == TokenStatus.RegistrationRequested);

        // Amount required to fully fund each side: requesterBaseDeposit + arbitration cost + (arbitration cost * multiplier).
        uint arbitrationCost = request.arbitrator.arbitrationCost(request.arbitratorExtraData);
        uint totalCost = arbitrationCost.addCap((arbitrationCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_DIVISOR).addCap(requesterBaseDeposit);
        contribute(round, Party.Requester, msg.sender, msg.value, totalCost);
        require(round.paidFees[uint(Party.Requester)] >= totalCost, "You must fully fund your side.");
        round.hasPaid[uint(Party.Requester)] = true;
        
        emit TokenStatusChange(
            request.parties[uint(Party.Requester)],
            address(0x0),
            tokenID,
            token.status,
            false,
            false
        );
    }

    /** @dev Challenges the latest request of a token. Accepts enough ETH to fund a potential dispute considering the current required amount. Reimburses unused ETH. TRUSTED.
     *  @param _tokenID The ID of the token with the request to challenge.
     *  @param _evidence A link to an evidence using its URI. Ignored if not provided or if not enough funds were provided to create a dispute.
     */
    function challengeRequest(bytes32 _tokenID, string _evidence) external payable {
        Token storage token = tokens[_tokenID];
        require(
            token.status == TokenStatus.RegistrationRequested || token.status == TokenStatus.ClearingRequested,
            "The token must have a pending request."
        );
        Request storage request = token.requests[token.requests.length - 1];
        require(now - request.submissionTime <= challengePeriodDuration, "Challenges must occur during the challenge period.");
        require(!request.disputed, "The request should not have already been disputed.");

        // Take the deposit and save the challenger's address.
        request.parties[uint(Party.Challenger)] = msg.sender;

        Round storage round = request.rounds[request.rounds.length - 1];
        uint arbitrationCost = request.arbitrator.arbitrationCost(request.arbitratorExtraData);
        uint totalCost = arbitrationCost.addCap((arbitrationCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_DIVISOR).addCap(challengerBaseDeposit);
        contribute(round, Party.Challenger, msg.sender, msg.value, totalCost);
        require(round.paidFees[uint(Party.Challenger)] >= totalCost, "You must fully fund your side.");
        round.hasPaid[uint(Party.Challenger)] = true;
        
        // Raise a dispute.
        request.disputeID = request.arbitrator.createDispute.value(arbitrationCost)(RULING_OPTIONS, request.arbitratorExtraData);
        arbitratorDisputeIDToTokenID[request.arbitrator][request.disputeID] = _tokenID;
        request.disputed = true;
        request.rounds.length++;
        round.feeRewards = round.feeRewards.subCap(arbitrationCost);
        
        emit Dispute(
            request.arbitrator,
            request.disputeID,
            token.status == TokenStatus.RegistrationRequested
                ? 2 * metaEvidenceUpdates
                : 2 * metaEvidenceUpdates + 1,
            uint(keccak256(abi.encodePacked(_tokenID,token.requests.length - 1)))
        );
        emit TokenStatusChange(
            request.parties[uint(Party.Requester)],
            request.parties[uint(Party.Challenger)],
            _tokenID,
            token.status,
            true,
            false
        );
        if (bytes(_evidence).length > 0)
            emit Evidence(request.arbitrator, uint(keccak256(abi.encodePacked(_tokenID,token.requests.length - 1))), msg.sender, _evidence);
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if both sides are fully funded. TRUSTED.
     *  @param _tokenID The ID of the token with the request to fund.
     *  @param _side The recipient of the contribution.
     */
    function fundAppeal(bytes32 _tokenID, Party _side) external payable {
        // Recipient must be either the requester or challenger.
        require(_side == Party.Requester || _side == Party.Challenger); // solium-disable-line error-reason
        Token storage token = tokens[_tokenID];
        require(
            token.status == TokenStatus.RegistrationRequested || token.status == TokenStatus.ClearingRequested,
            "The token must have a pending request."
        );
        Request storage request = token.requests[token.requests.length - 1];
        require(request.disputed, "A dispute must have been raised to fund an appeal.");
        (uint appealPeriodStart, uint appealPeriodEnd) = request.arbitrator.appealPeriod(request.disputeID);
        require(
            now >= appealPeriodStart && now < appealPeriodEnd,
            "Contributions must be made within the appeal period."
        );
        

        // Amount required to fully fund each side: arbitration cost + (arbitration cost * multiplier)
        Round storage round = request.rounds[request.rounds.length - 1];
        Party winner = Party(request.arbitrator.currentRuling(request.disputeID));
        Party loser;
        if (winner == Party.Requester)
            loser = Party.Challenger;
        else if (winner == Party.Challenger)
            loser = Party.Requester;
        require(!(_side==loser) || (now-appealPeriodStart < (appealPeriodEnd-appealPeriodStart)/2), "The loser must contribute during the first half of the appeal period.");
        
        uint multiplier;
        if (_side == winner)
            multiplier = winnerStakeMultiplier;
        else if (_side == loser)
            multiplier = loserStakeMultiplier;
        else
            multiplier = sharedStakeMultiplier;
        uint appealCost = request.arbitrator.appealCost(request.disputeID, request.arbitratorExtraData);
        uint totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);
        contribute(round, _side, msg.sender, msg.value, totalCost);
        if (round.paidFees[uint(_side)] >= totalCost)
            round.hasPaid[uint(_side)] = true;

        // Raise appeal if both sides are fully funded.
        if (round.hasPaid[uint(Party.Challenger)] && round.hasPaid[uint(Party.Requester)]) {
            request.arbitrator.appeal.value(appealCost)(request.disputeID, request.arbitratorExtraData);
            request.rounds.length++;
            round.feeRewards = round.feeRewards.subCap(appealCost);
            emit TokenStatusChange(
                request.parties[uint(Party.Requester)],
                request.parties[uint(Party.Challenger)],
                _tokenID,
                token.status,
                true,
                true
            );
        }
    }

    /** @dev Reimburses contributions if no disputes were raised. If a dispute was raised, sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     *  @param _beneficiary The address that made contributions to a request.
     *  @param _tokenID The ID of the token submission with the request from which to withdraw.
     *  @param _request The request from which to withdraw.
     *  @param _round The round from which to withdraw.
     */
    function withdrawFeesAndRewards(address _beneficiary, bytes32 _tokenID, uint _request, uint _round) public {
        Token storage token = tokens[_tokenID];
        Request storage request = token.requests[_request];
        Round storage round = request.rounds[_round];
        // The request must be resolved and there can be no disputes pending resolution.
        require(request.resolved); // solium-disable-line error-reason

        uint reward;
        if (!request.disputed || request.ruling == Party.None) {
            // No disputes were raised, or there isn't a winner and loser. Reimburse unspent fees proportionally.
            uint rewardRequester = round.paidFees[uint(Party.Requester)] > 0
                ? (round.contributions[_beneficiary][uint(Party.Requester)] * round.feeRewards) / (round.paidFees[uint(Party.Challenger)] + round.paidFees[uint(Party.Requester)])
                : 0;
            uint rewardChallenger = round.paidFees[uint(Party.Challenger)] > 0
                ? (round.contributions[_beneficiary][uint(Party.Challenger)] * round.feeRewards) / (round.paidFees[uint(Party.Challenger)] + round.paidFees[uint(Party.Requester)])
                : 0;

            reward = rewardRequester + rewardChallenger;
            round.contributions[_beneficiary][uint(Party.Requester)] = 0;
            round.contributions[_beneficiary][uint(Party.Challenger)] = 0;
        } else {
            // Reward the winner.
            reward = round.paidFees[uint(request.ruling)] > 0
                ? (round.contributions[_beneficiary][uint(request.ruling)] * round.feeRewards) / round.paidFees[uint(request.ruling)]
                : 0;

            round.contributions[_beneficiary][uint(request.ruling)] = 0;
        }

        emit RewardWithdrawal(_tokenID, _beneficiary, _request, _round,  reward);
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    /** @dev Withdraws rewards and reimbursements of multiple rounds at once. This function is O(n) where n is the number of rounds. This could exceed gas limits, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _beneficiary The address that made contributions to the request.
     *  @param _tokenID The token ID with funds to be withdrawn.
     *  @param _request The request from which to withdraw contributions.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count Rounds greater or equal to this value won't be withdrawn. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     */
    function batchRoundWithdraw(address _beneficiary, bytes32 _tokenID, uint _request, uint _cursor, uint _count) public {
        Token storage token = tokens[_tokenID];
        Request storage request = token.requests[_request];
        for (uint i = _cursor; i<request.rounds.length && (_count==0 || i<_count); i++)
            withdrawFeesAndRewards(_beneficiary, _tokenID, _request, i);
    }

    /** @dev Withdraws rewards and reimbursements of multiple requests at once. This function is O(n*m) where n is the number of requests and m is the number of rounds to withdraw per request. This could exceed gas limits, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _beneficiary The address that made contributions to the request.
     *  @param _tokenID The token ID with funds to be withdrawn.
     *  @param _cursor The request from which to start withdrawing.
     *  @param _count Requests greater or equal to this value won't be withdrawn. If set to 0 or a value larger than the number of request, iterates until the last request.
     *  @param _roundCursor The round of each request from where to start withdrawing.
     *  @param _roundCount Rounds greater or equal to this value won't be withdrawn. If set to 0 or a value larger than the number of rounds a request has, iteration for that request will stop at the last round.
     */
    function batchRequestWithdraw(
        address _beneficiary,
        bytes32 _tokenID,
        uint _cursor,
        uint _count,
        uint _roundCursor,
        uint _roundCount
    ) external {
        Token storage token = tokens[_tokenID];
        for (uint i = _cursor; i<token.requests.length && (_count==0 || i<_count); i++)
            batchRoundWithdraw(_beneficiary, _tokenID, i, _roundCursor, _roundCount);
    }

    /** @dev Executes a request if the challenge period passed and no one challenged the request.
     *  @param _tokenID The ID of the token with the request to execute.
     */
    function executeRequest(bytes32 _tokenID) external {
        Token storage token = tokens[_tokenID];
        Request storage request = token.requests[token.requests.length - 1];
        require(
            now - request.submissionTime > challengePeriodDuration,
            "Time to challenge the request must have passed."
        );
        require(!request.disputed, "The request should not be disputed.");

        if (token.status == TokenStatus.RegistrationRequested)
            token.status = TokenStatus.Registered;
        else if (token.status == TokenStatus.ClearingRequested)
            token.status = TokenStatus.Absent;
        else
            revert("There must be a request.");

        request.resolved = true;
        withdrawFeesAndRewards(request.parties[uint(Party.Requester)], _tokenID, token.requests.length - 1, 0); // Automatically withdraw for the requester.

        emit TokenStatusChange(
            request.parties[uint(Party.Requester)],
            address(0x0),
            _tokenID,
            token.status,
            false,
            false
        );
    }

    /** @dev Give a ruling for a dispute. Can only be called by the arbitrator. TRUSTED.
     *  Overrides parent function to account for the situation where the winner loses a case due to paying less appeal fees than expected.
     *  @param _disputeID ID of the dispute in the arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint _disputeID, uint _ruling) public {
        Party resultRuling = Party(_ruling);
        bytes32 tokenID = arbitratorDisputeIDToTokenID[msg.sender][_disputeID];
        Token storage token = tokens[tokenID];
        Request storage request = token.requests[token.requests.length - 1];
        Round storage round = request.rounds[request.rounds.length - 1];
        require(_ruling <= RULING_OPTIONS); // solium-disable-line error-reason
        require(request.arbitrator == msg.sender); // solium-disable-line error-reason
        require(!request.resolved); // solium-disable-line error-reason

        // The ruling is inverted if the loser paid its fees.
        if (round.hasPaid[uint(Party.Requester)] == true) // If one side paid its fees, the ruling is in its favor. Note that if the other side had also paid, an appeal would have been created.
            resultRuling = Party.Requester;
        else if (round.hasPaid[uint(Party.Challenger)] == true)
            resultRuling = Party.Challenger;
        
        emit Ruling(Arbitrator(msg.sender), _disputeID, uint(resultRuling));
        executeRuling(_disputeID, uint(resultRuling));
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(bytes32 _tokenID, string _evidence) external {
        Token storage token = tokens[_tokenID];
        Request storage request = token.requests[token.requests.length - 1];
        require(!request.resolved, "The dispute must not already be resolved.");

        emit Evidence(request.arbitrator, uint(keccak256(abi.encodePacked(_tokenID,token.requests.length - 1))), msg.sender, _evidence);
    }

    // ************************ //
    // *      Governance      * //
    // ************************ //

    /** @dev Change the duration of the challenge period.
     *  @param _challengePeriodDuration The new duration of the challenge period.
     */
    function changeTimeToChallenge(uint _challengePeriodDuration) external onlyGovernor {
        challengePeriodDuration = _challengePeriodDuration;
    }

    /** @dev Change the base amount required as a deposit to make a request.
     *  @param _requesterBaseDeposit The new base amount of wei required to make a request.
     */
    function changeRequesterBaseDeposit(uint _requesterBaseDeposit) external onlyGovernor {
        requesterBaseDeposit = _requesterBaseDeposit;
    }
    
    /** @dev Change the base amount required as a deposit to challenge a request.
     *  @param _challengerBaseDeposit The new base amount of wei required to challenge a request.
     */
    function changeChallengerBaseDeposit(uint _challengerBaseDeposit) external onlyGovernor {
        challengerBaseDeposit = _challengerBaseDeposit;
    }

    /** @dev Change the governor of the token curated registry.
     *  @param _governor The address of the new governor.
     */
    function changeGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    /** @dev Change the percentage of arbitration fees that must be paid as fee stake by parties when there isn't a winner or loser.
     *  @param _sharedStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeSharedStakeMultiplier(uint _sharedStakeMultiplier) external onlyGovernor {
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /** @dev Change the percentage of arbitration fees that must be paid as fee stake by the winner of the previous round.
     *  @param _winnerStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeWinnerStakeMultiplier(uint _winnerStakeMultiplier) external onlyGovernor {
        winnerStakeMultiplier = _winnerStakeMultiplier;
    }

    /** @dev Change the percentage of arbitration fees that must be paid as fee stake by the party that lost the previous round.
     *  @param _loserStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeLoserStakeMultiplier(uint _loserStakeMultiplier) external onlyGovernor {
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    /** @dev Change the arbitrator to be used for disputes that may be raised in the next requests. The arbitrator is trusted to support appeal periods and not reenter.
     *  @param _arbitrator The new trusted arbitrator to be used in the next requests.
     *  @param _arbitratorExtraData The extra data used by the new arbitrator.
     */
    function changeArbitrator(Arbitrator _arbitrator, bytes _arbitratorExtraData) external onlyGovernor {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
    }

    /** @dev Update the meta evidence used for disputes.
     *  @param _registrationMetaEvidence The meta evidence to be used for future registration request disputes.
     *  @param _clearingMetaEvidence The meta evidence to be used for future clearing request disputes.
     */
    function changeMetaEvidence(string _registrationMetaEvidence, string _clearingMetaEvidence) external onlyGovernor {
        metaEvidenceUpdates++;
        emit MetaEvidence(2 * metaEvidenceUpdates, _registrationMetaEvidence);
        emit MetaEvidence(2 * metaEvidenceUpdates + 1, _clearingMetaEvidence);
    }

    
    /* Internal */

    /** @dev Returns the contribution value and remainder from available ETH and required amount.
     *  @param _available The amount of ETH available for the contribution.
     *  @param _requiredAmount The amount of ETH required for the contribution.
     *  @return taken The amount of ETH taken.
     *  @return remainder The amount of ETH left from the contribution.
     */
    function calculateContribution(uint _available, uint _requiredAmount)
        internal
        pure
        returns(uint taken, uint remainder)
    {
        if (_requiredAmount > _available)
            return (_available, 0); // Take whatever is available, return 0 as leftover ETH.

        remainder = _available - _requiredAmount;
        return (_requiredAmount, remainder);
    }
    
    /** @dev Make a fee contribution.
     *  @param _round The round to contribute.
     *  @param _side The side for which to contribute.
     *  @param _contributor The contributor.
     *  @param _amount The amount contributed.
     *  @param _totalRequired The total amount required for this side.
     */
    function contribute(Round storage _round, Party _side, address _contributor, uint _amount, uint _totalRequired) internal {
        // Take up to the amount necessary to fund the current round at the current costs.
        uint contribution; // Amount contributed.
        uint remainingETH; // Remaining ETH to send back.
        (contribution, remainingETH) = calculateContribution(_amount, _totalRequired.subCap(_round.paidFees[uint(_side)]));
        _round.contributions[_contributor][uint(_side)] += contribution;
        _round.paidFees[uint(_side)] += contribution;
        _round.feeRewards += contribution;

        // Reimburse leftover ETH.
        _contributor.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.
    }
    
    /** @dev Execute the ruling of a dispute.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function executeRuling(uint _disputeID, uint _ruling) internal {
        bytes32 tokenID = arbitratorDisputeIDToTokenID[msg.sender][_disputeID];
        Token storage token = tokens[tokenID];
        Request storage request = token.requests[token.requests.length - 1];

        Party winner = Party(_ruling);

        // Update token state
        if (winner == Party.Requester) { // Execute Request
            if (token.status == TokenStatus.RegistrationRequested)
                token.status = TokenStatus.Registered;
            else
                token.status = TokenStatus.Absent;
        } else { // Revert to previous state.
            if (token.status == TokenStatus.RegistrationRequested)
                token.status = TokenStatus.Absent;
            else if (token.status == TokenStatus.ClearingRequested)
                token.status = TokenStatus.Registered;
        }

        request.resolved = true;
        request.ruling = Party(_ruling);
        // Automatically withdraw.
        if (winner == Party.None) {
            withdrawFeesAndRewards(request.parties[uint(Party.Requester)], tokenID, token.requests.length-1, 0);
            withdrawFeesAndRewards(request.parties[uint(Party.Challenger)], tokenID, token.requests.length-1, 0);
        } else {
            withdrawFeesAndRewards(request.parties[uint(winner)], tokenID, token.requests.length-1, 0); 
        }

        emit TokenStatusChange(
            request.parties[uint(Party.Requester)],
            request.parties[uint(Party.Challenger)],
            tokenID,
            token.status,
            request.disputed,
            false
        );
    }
    
    
    /* Views */

    /** @dev Return true if the token is on the list.
     *  @param _tokenID The ID of the token to be queried.
     *  @return allowed True if the token is allowed, false otherwise.
     */
    function isPermitted(bytes32 _tokenID) external view returns (bool allowed) {
        Token storage token = tokens[_tokenID];
        return token.status == TokenStatus.Registered || token.status == TokenStatus.ClearingRequested;
    }

    
    /* Interface Views */

    /** @dev Return the sum of withdrawable wei of a request an account is entitled to. This function is O(n), where n is the number of rounds of the request. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _tokenID The ID of the token to query.
     *  @param _beneficiary The contributor for which to query.
     *  @param _request The request from which to query for.
     *  @return The total amount of wei available to withdraw.
     */
    function amountWithdrawable(bytes32 _tokenID, address _beneficiary, uint _request) external view returns (uint total){
        Request storage request = tokens[_tokenID].requests[_request];
        if (!request.resolved) return total;

        for (uint i = 0; i < request.rounds.length; i++) {
            Round storage round = request.rounds[i];
            if (!request.disputed || request.ruling == Party.None) {
                uint rewardRequester = round.paidFees[uint(Party.Requester)] > 0
                    ? (round.contributions[_beneficiary][uint(Party.Requester)] * round.feeRewards) / (round.paidFees[uint(Party.Requester)] + round.paidFees[uint(Party.Challenger)])
                    : 0;
                uint rewardChallenger = round.paidFees[uint(Party.Challenger)] > 0
                    ? (round.contributions[_beneficiary][uint(Party.Challenger)] * round.feeRewards) / (round.paidFees[uint(Party.Requester)] + round.paidFees[uint(Party.Challenger)])
                    : 0;

                total += rewardRequester + rewardChallenger;
            } else {
                total += round.paidFees[uint(request.ruling)] > 0
                    ? (round.contributions[_beneficiary][uint(request.ruling)] * round.feeRewards) / round.paidFees[uint(request.ruling)]
                    : 0;
            }
        }

        return total;
    }
    
    /** @dev Return the numbers of tokens that were submitted. Includes tokens that never made it to the list or were later removed.
     *  @return count The numbers of tokens in the list.
     */
    function tokenCount() external view returns (uint count) {
        return tokensList.length;
    }
    
    /** @dev Return the numbers of tokens with each status. This function is O(n), where n is the number of tokens. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @return The numbers of tokens in the list per status.
     */
    function countByStatus()
        external
        view
        returns (
            uint absent,
            uint registered,
            uint registrationRequest,
            uint clearingRequest,
            uint challengedRegistrationRequest,
            uint challengedClearingRequest
        )
    {
        for (uint i = 0; i < tokensList.length; i++) {
            Token storage token = tokens[tokensList[i]];
            Request storage request = token.requests[token.requests.length - 1];

            if (token.status == TokenStatus.Absent) absent++;
            else if (token.status == TokenStatus.Registered) registered++;
            else if (token.status == TokenStatus.RegistrationRequested && !request.disputed) registrationRequest++;
            else if (token.status == TokenStatus.ClearingRequested && !request.disputed) clearingRequest++;
            else if (token.status == TokenStatus.RegistrationRequested && request.disputed) challengedRegistrationRequest++;
            else if (token.status == TokenStatus.ClearingRequested && request.disputed) challengedClearingRequest++;
        }
    }

    /** @dev Return the values of the tokens the query finds. This function is O(n), where n is the number of tokens. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _cursor The ID of the token from which to start iterating. To start from either the oldest or newest item.
     *  @param _count The number of tokens to return.
     *  @param _filter The filter to use. Each element of the array in sequence means:
     *  - Include absent tokens in result.
     *  - Include registered tokens in result.
     *  - Include tokens with registration requests that are not disputed in result.
     *  - Include tokens with clearing requests that are not disputed in result.
     *  - Include disputed tokens with registration requests in result.
     *  - Include disputed tokens with clearing requests in result.
     *  - Include tokens submitted by the caller.
     *  - Include tokens challenged by the caller.
     *  @param _oldestFirst Whether to sort from oldest to the newest item.
     *  @param _tokenAddr A token address to filter submissions by address (optional).
     *  @return The values of the tokens found and whether there are more tokens for the current filter and sort.
     */
    function queryTokens(bytes32 _cursor, uint _count, bool[8] _filter, bool _oldestFirst, address _tokenAddr)
        external
        view
        returns (bytes32[] values, bool hasMore)
    {
        uint cursorIndex;
        values = new bytes32[](_count);
        uint index = 0;

        bytes32[] storage list = _tokenAddr == address(0x0)
            ? tokensList
            : addressToSubmissions[_tokenAddr];

        if (_cursor == 0)
            cursorIndex = 0;
        else {
            for (uint j = 0; j < list.length; j++) {
                if (list[j] == _cursor) {
                    cursorIndex = j;
                    break;
                }
            }
            require(cursorIndex  != 0, "The cursor is invalid.");
        }

        for (
                uint i = cursorIndex == 0 ? (_oldestFirst ? 0 : 1) : (_oldestFirst ? cursorIndex + 1 : list.length - cursorIndex + 1);
                _oldestFirst ? i < list.length : i <= list.length;
                i++
            ) { // Oldest or newest first.
            bytes32 tokenID = list[_oldestFirst ? i : list.length - i];
            Token storage token = tokens[tokenID];
            Request storage request = token.requests[token.requests.length - 1];
            if (
                /* solium-disable operator-whitespace */
                (_filter[0] && token.status == TokenStatus.Absent) ||
                (_filter[1] && token.status == TokenStatus.Registered) ||
                (_filter[2] && token.status == TokenStatus.RegistrationRequested && !request.disputed) ||
                (_filter[3] && token.status == TokenStatus.ClearingRequested && !request.disputed) ||
                (_filter[4] && token.status == TokenStatus.RegistrationRequested && request.disputed) ||
                (_filter[5] && token.status == TokenStatus.ClearingRequested && request.disputed) ||
                (_filter[6] && request.parties[uint(Party.Requester)] == msg.sender) || // My Submissions.
                (_filter[7] && request.parties[uint(Party.Challenger)] == msg.sender) // My Challenges.
                /* solium-enable operator-whitespace */
            ) {
                if (index < _count) {
                    values[index] = list[_oldestFirst ? i : list.length - i];
                    index++;
                } else {
                    hasMore = true;
                    break;
                }
            }
        }
    }
    
    /** @dev Gets the contributions made by a party for a given round of a request.
     *  @param _tokenID The ID of the token.
     *  @param _request The position of the request.
     *  @param _round The position of the round.
     *  @param _contributor The address of the contributor.
     *  @return The contributions.
     */
    function getContributions(
        bytes32 _tokenID,
        uint _request,
        uint _round,
        address _contributor
    ) external view returns(uint[3] contributions) {
        Token storage token = tokens[_tokenID];
        Request storage request = token.requests[_request];
        Round storage round = request.rounds[_round];
        contributions = round.contributions[_contributor];
    }
    
    /** @dev Returns token information. Includes length of requests array.
     *  @param _tokenID The ID of the queried token.
     *  @return The token information.
     */
    function getTokenInfo(bytes32 _tokenID)
        external
        view
        returns (
            string name,
            string ticker,
            address addr,
            string symbolMultihash,
            TokenStatus status,
            uint numberOfRequests
        )
    {
        Token storage token = tokens[_tokenID];
        return (
            token.name,
            token.ticker,
            token.addr,
            token.symbolMultihash,
            token.status,
            token.requests.length
        );
    }

    /** @dev Gets information on a request made for a token.
     *  @param _tokenID The ID of the queried token.
     *  @param _request The request to be queried.
     *  @return The request information.
     */
    function getRequestInfo(bytes32 _tokenID, uint _request)
        external
        view
        returns (
            bool disputed,
            uint disputeID,
            uint submissionTime,
            bool resolved,
            address[3] parties,
            uint numberOfRounds,
            Party ruling,
            Arbitrator arbitrator,
            bytes arbitratorExtraData
        )
    {
        Request storage request = tokens[_tokenID].requests[_request];
        return (
            request.disputed,
            request.disputeID,
            request.submissionTime,
            request.resolved,
            request.parties,
            request.rounds.length,
            request.ruling,
            request.arbitrator,
            request.arbitratorExtraData
        );
    }

    /** @dev Gets the information on a round of a request.
     *  @param _tokenID The ID of the queried token.
     *  @param _request The request to be queried.
     *  @param _round The round to be queried.
     *  @return The round information.
     */
    function getRoundInfo(bytes32 _tokenID, uint _request, uint _round)
        external
        view
        returns (
            bool appealed,
            uint[3] paidFees,
            bool[3] hasPaid,
            uint feeRewards
        )
    {
        Token storage token = tokens[_tokenID];
        Request storage request = token.requests[_request];
        Round storage round = request.rounds[_round];
        return (
            _round != (request.rounds.length-1),
            round.paidFees,
            round.hasPaid,
            round.feeRewards
        );
    }
}
