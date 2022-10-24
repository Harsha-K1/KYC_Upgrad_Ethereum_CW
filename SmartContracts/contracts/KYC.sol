// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.5.22 <0.9.0;

/// @title An implementation of a Decentralized KYC system.
/// @author Sri Harsha K.
/// @notice All functionality is accompanied by relevant comments that (mostly) adhere to Ethereum NatSpec.

contract KYC{

    address admin;
    uint256 totalBanks; /// @dev For lone variables, uint256 is cheaper than uint8 due to EVM downscaling. Hence using it here.

    struct Customer {
        uint16 upvotes; /// @dev These get packed, so can use a (reasonably) lower value than uint256 to save some gas.
        uint16 downvotes;
        bool kycStatus;
        address initiatingBank;
        bytes32 userName;   
        bytes32 kycDataHash;  /// @dev Assuming keccak256 hash as input.
    }
    
    struct Bank {
        uint16 complaintsReported;
        uint16 kycReqCount;
        bool isAllowedToVote;
        address ethAddress;
        bytes32 name;
        bytes32 regNumber;
    }

    struct KYCRequest {
        bytes32 kycCustUserName;     
        bytes32 kycCustData;
        address kycBankAddr;
    }

    address[] allBankAddresses; /// @dev An array is unavoidable to achieve duplicate voting prevention. Because we need to reset votedUponCustomersList.

    /// Setting contract deployer as admin.
    constructor() public {
        admin = msg.sender;
    }

    mapping(bytes32 => Customer) customersList; /// customerUserName => Customer
    mapping(address => Bank) banksList; /// bankAddress => Bank 
    mapping(bytes32 => KYCRequest) kycRequestsList; /// customerUserName => KycRequest 

    /// Below mappings are to prevent duplicate voting of Customers & duplicate reporting of Banks.
    mapping(bytes32 => mapping(address => bool)) votedUponCustomersList; /// customerUserName => (bankAddress => isVotedUpon)
    mapping(address => mapping(address => bool)) reportedUponBanksList;/// reportReceivingBankAddress => (reportingBankAddress => isReportedUpon)

   /// Modifiers
    modifier adminOnly() {
        require(msg.sender == admin, "Only Admin can perform this action.");
        _;
    }

    modifier customerExists(bytes32 _userName) {
        require(customersList[_userName].initiatingBank != address(0), "No customer found with this Username.");
        _;
    }

  
    /// Bank Interface
    /******************************************************************************************************************
        @notice addCustomer : Adds a Customer to the customersList. 
        @param {bytes32} _userName : Username of the Customer.
        @param {bytes32} _customerData : Hashed KYC data of the Customer.
     ******************************************************************************************************************/
     function addCustomer(bytes32 _userName, bytes32 _customerData) public {
        require(banksList[msg.sender].ethAddress != address(0), "No Bank found with this address.");
        require(banksList[msg.sender].isAllowedToVote, "This Bank is no longer allowed to do KYC.");
        require(customersList[_userName].initiatingBank == address(0), "A Customer already exists with this userName.");
        customersList[_userName].userName = _userName;
        customersList[_userName].kycDataHash = _customerData;
        customersList[_userName].initiatingBank = msg.sender;
        customersList[_userName].kycStatus = false;
        customersList[_userName].upvotes = 0;
        customersList[_userName].downvotes = 0;
    }

     /******************************************************************************************************************
        @notice viewCustomer : Fetches details of a Customer. 
        @param {bytes32} _userName : Username of the Customer.
     ******************************************************************************************************************/
    function viewCustomer(bytes32 _userName) public view customerExists(_userName) returns (bytes32, bytes32, address, bool, uint256, uint256) {
        require(banksList[msg.sender].ethAddress != address(0), "No Bank found with this address.");
        require(banksList[msg.sender].isAllowedToVote, "This Bank is no longer allowed to do KYC.");
        return (customersList[_userName].userName, customersList[_userName].kycDataHash, customersList[_userName].initiatingBank, customersList[_userName].kycStatus, customersList[_userName].upvotes, customersList[_userName].downvotes);
    }
    
    /******************************************************************************************************************
        @notice modifyCustomer : Replaces customer KYC data. Resets upvotes and downvotes. Deletes current KYC request.
        @param {bytes32} _userName : Username of the Customer.
        @param {bytes32} _newcustomerData : Hashed KYC data of the Customer.
     ******************************************************************************************************************/
    function modifyCustomer(bytes32 _userName, bytes32 _newcustomerData) public customerExists(_userName) {
        require(banksList[msg.sender].ethAddress != address(0), "No Bank found with this address.");
        require(banksList[msg.sender].isAllowedToVote, "This Bank is no longer allowed to do KYC.");
        customersList[_userName].kycDataHash = _newcustomerData;
        customersList[_userName].upvotes = 0;
        customersList[_userName].downvotes = 0;
        if(kycRequestsList[_userName].kycBankAddr != address(0)){
            delete kycRequestsList[_userName];
        }
        //delete votedUponCustomersList[_userName];
        resetVotedUponCustomersList(_userName);
    }    

    /******************************************************************************************************************
        @notice upvoteCustomerKyc : Upvotes customer's KYC data as valid. 
        @param {bytes32} _userName : Username of the Customer.
        @dev In this function, we call addToVotedUponCustomersList function which adds the current Customer entry 
        into votedUponCustomersList. This is to prevent double voting of the Cusomter by same Bank which would defeat
        the purpose of KYC in the first place.
     ******************************************************************************************************************/
    function upvoteCustomerKyc(bytes32 _userName) public customerExists(_userName) {
        require(banksList[msg.sender].ethAddress != address(0), "No Bank found with this address.");
        require(banksList[msg.sender].isAllowedToVote, "This Bank is no longer allowed to vote.");
        require(!votedUponCustomersList[_userName][msg.sender], "This Bank already voted for this customer.");
        require(kycRequestsList[_userName].kycBankAddr != address(0), "Can't vote as there's no KYC request for this customer.");
        customersList[_userName].upvotes += 1;
        customersList[_userName].kycStatus = (customersList[_userName].downvotes < totalBanks/3 && customersList[_userName].upvotes > customersList[_userName].downvotes);
        addToVotedUponCustomersList(msg.sender, _userName);
    }

    /******************************************************************************************************************
        @notice downvoteCustomerKyc : Downvotes customer's KYC data as invalid. 
        @param {bytes32} _userName  : Username of the Customer.
        @dev If a customer gets downvoted by one-third (our threshold) of the banks, then the kycStatus of the customer is set to 
        false even if the number of upvotes is more than that of downvotes. 
     ******************************************************************************************************************/
    function downvoteCustomerKyc(bytes32 _userName) public customerExists(_userName) {
        require(banksList[msg.sender].ethAddress != address(0), "No Bank found with this address.");
        require(banksList[msg.sender].isAllowedToVote, "This Bank is no longer allowed to vote.");
        require(!votedUponCustomersList[_userName][msg.sender], "This Bank already voted for this customer.");
        require(kycRequestsList[_userName].kycBankAddr != address(0), "Can't vote as there's no KYC request for this customer.");
        customersList[_userName].downvotes += 1;
        customersList[_userName].kycStatus = (customersList[_userName].downvotes < totalBanks/3 && customersList[_userName].upvotes > customersList[_userName].downvotes);
        banksList[customersList[_userName].initiatingBank].isAllowedToVote = false;
        addToVotedUponCustomersList(msg.sender, _userName);
    }
    
    /******************************************************************************************************************
        @notice addKycRequest : Adds a customer's KYC data to the request list to be picked and verified. 
        @param {bytes32} _userName : Username of the Customer.
        @param {bytes32} _customerData : Hashed KYC data of the Customer.
     ******************************************************************************************************************/
    function addKycRequest(bytes32 _userName, bytes32 _customerData) public customerExists(_userName) {
        require(banksList[msg.sender].ethAddress != address(0), "No Bank found with this address.");
        require(banksList[msg.sender].isAllowedToVote, "This Bank is no longer allowed to do KYC.");
        require(kycRequestsList[_userName].kycBankAddr == address(0), "A KYC request already exists for this Customer.");
        kycRequestsList[_userName].kycCustUserName = _userName;
        kycRequestsList[_userName].kycCustData = _customerData;
        kycRequestsList[_userName].kycBankAddr = msg.sender;
        banksList[msg.sender].kycReqCount += 1;
    }
    
    /******************************************************************************************************************
        @notice removeKycRequest    : Removes a customer's KYC data from the request list. 
        @param {bytes32} _userName  : Username of the Customer.
     ******************************************************************************************************************/
    function removeKycRequest(bytes32 _userName) public {
        require(banksList[msg.sender].ethAddress != address(0), "No Bank found with this address.");
        require(banksList[msg.sender].isAllowedToVote, "This Bank is no longer allowed to do KYC.");
        require(kycRequestsList[_userName].kycBankAddr != address(0), "No KYC request exists for this customer.");
        delete kycRequestsList[_userName];
    }

    /******************************************************************************************************************
        @notice viewBankDetails     : Fetches the Bank variable from banksList. 
        @param {address} _bankAddr  : Address of the Bank to be fetched.
     ******************************************************************************************************************/
    function viewBankDetails(address _bankAddr) public view returns(Bank memory){
        require(banksList[_bankAddr].ethAddress != address(0), "No Bank found with this address.");
        require(banksList[msg.sender].isAllowedToVote, "This Bank is no longer allowed to do KYC.");
        return banksList[_bankAddr];
    }
    
    /******************************************************************************************************************
        @notice getBankComplaintsCount : Fetches the number of complaints reported against a Bank. 
        @param {address} _bankAddr : Address of the Bank whose complaints count is to be fetched.
     ******************************************************************************************************************/
    function getBankComplaintsCount(address _bankAddr) public view returns(uint){
        require(banksList[_bankAddr].ethAddress != address(0), "No Bank found with this address.");
        return banksList[_bankAddr].complaintsReported;
    }

    /******************************************************************************************************************
        @notice reportBank : Reports a Bank as faulty. 
        @param {address} _bankAddr : Address of the Bank being reported against.
        @dev We also check number of reports against the Bank. If they're more than 1/3 (our threshold) of total Banks.
        If yes, we set the Bank's isAllowedToVote to false. We also add the Bank to reportedUponBanksList which keeps 
        a map of all reported Banks and their reporters, to prevent duplicate reporting.
     ******************************************************************************************************************/
    function reportBank(address _bankAddr) public {
        require(banksList[_bankAddr].ethAddress != address(0), "No Bank found with this address.");
        require(banksList[msg.sender].isAllowedToVote, "This Bank is no longer allowed to do KYC.");
        require(!reportedUponBanksList[_bankAddr][msg.sender], "Reporting Bank already registered complaint against recipient Bank.");
        banksList[_bankAddr].complaintsReported += 1;
        banksList[_bankAddr].isAllowedToVote = (banksList[_bankAddr].complaintsReported < totalBanks/3);
        reportedUponBanksList[_bankAddr][msg.sender] = true; 
    } 

    /******************************************************************************************************************
        @notice addToVotedUponCustomersList : Internal function to add a Customer to votedUponCustomersList. This
        list keeps track of customers & banks that voted them respectively and used to prevent duplicate voting.
        @param {address} _bankAddr : Address of the Bank voting.
        @param {bytes32} _userName : Username of the Customer.
     ******************************************************************************************************************/
    function addToVotedUponCustomersList(address _bankAddr, bytes32 _userName) internal {
        votedUponCustomersList[_userName][_bankAddr] = true; 
    }

    /******************************************************************************************************************
        @notice resetVotedUponCustomersList : Resets votedUponCustomersList. To be called when modifyCustomer executes.
        @param {bytes32} _userName : Username of the Customer.
     ******************************************************************************************************************/
    function resetVotedUponCustomersList(bytes32 _userName) internal {
        for(uint i=0; i<allBankAddresses.length; i++){
            votedUponCustomersList[_userName][allBankAddresses[i]] = false;
        }
    }

    /******************************************************************************************************************
        @notice resetReportedUponBanksList : Resets votedUponCustomersList. To be called when admin calls 
        modifyBankVotingRights with True.
        @param {address} _reportedUponBankAddr : Address of Bank reported on.
     ******************************************************************************************************************/
    function resetReportedUponBanksList(address _reportedUponBankAddr) internal {
        for(uint i=0; i<allBankAddresses.length; i++){
            reportedUponBanksList[_reportedUponBankAddr][allBankAddresses[i]] = false;
        }
    }

    /// Admin Interface 
    /******************************************************************************************************************
        @notice addBank : Adds a Bank to the KYC contract. Can only be called by Admin.
        @param {bytes32} _bankName  : Name of the Bank.
        @param {bytes32} _bankRegNo : Registration number of the Bank.
        @param {address} _bankAddr  : Address of the Bank.
        @dev This function increments the totalBanks counter by 1. We use totalBanks to keep track of number of 
        Banks in the system and to calculate thresholds for downvotes and reports.
     ******************************************************************************************************************/
    function addBank(bytes32 _bankName, bytes32 _bankRegNo, address _bankAddr) public adminOnly {
        require(banksList[_bankAddr].ethAddress == address(0), "A Bank with this address already exists.");
        banksList[_bankAddr].name =  _bankName;
        banksList[_bankAddr].regNumber =  _bankRegNo;
        banksList[_bankAddr].ethAddress =  _bankAddr;
        banksList[_bankAddr].isAllowedToVote =  true;
        banksList[_bankAddr].complaintsReported =  0;
        banksList[_bankAddr].kycReqCount =  0;
        totalBanks++;
        allBankAddresses.push(_bankAddr);
    }

    /******************************************************************************************************************
        @notice modifyBankVotingRights  : Sets a Bank's isAllowedToVote value. Can only be called by Admin.
        @param {address} _bankAddr      : Address of the Bank.
        @param {bool} _isAllowedToVote  : True or False value to be set.
        @dev We also call resetReportedUponBanksList to remove the Bank's reports from the reported Banks list.
     ******************************************************************************************************************/
    function modifyBankVotingRights(address _bankAddr, bool _isAllowedToVote) public adminOnly {
        require(banksList[_bankAddr].ethAddress != address(0), "No Bank found with this address.");
        banksList[_bankAddr].isAllowedToVote =  _isAllowedToVote;
        if(_isAllowedToVote){
            resetReportedUponBanksList(_bankAddr);
        }
    }

    /******************************************************************************************************************
        @notice removeBank  : Removes a Bank from the KYC contract. Can only be called by Admin.
        @param {address} _bankAddr      : Address of the Bank.
        @param {bool} _isAllowedToVote  : True or False value to be set.
        @dev This function decrements the totalBanks counter by 1.
     ******************************************************************************************************************/
    function removeBank(address _bankAddr) public adminOnly {
        require(banksList[_bankAddr].ethAddress != address(0), "No Bank found with this address.");
        delete banksList[_bankAddr];
        totalBanks--;
    }
}    