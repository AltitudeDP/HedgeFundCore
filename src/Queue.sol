// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC721Enumerable, ERC721} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @dev ERC721 queue token used to track pending actions. Owned by the HedgeFund.
contract Queue is ERC721Enumerable, Ownable {
    uint256 private _nextId = 1;

    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) Ownable(msg.sender) {}

    function mint(address to) external onlyOwner returns (uint256 tokenId) {
        tokenId = _nextId++;
        _safeMint(to, tokenId);
    }

    function burn(uint256 tokenId) external onlyOwner {
        _burn(tokenId);
    }
}
