# Onchain Tariff Market

This context names the economic and governance identities used by the market so
their responsibilities remain distinct across settlement and voting code.

## Language

**Market Account**:
A lightweight, non-transferable numeric ID for one immutable Account
Owner–Merchant pair. Its deposit, capacity multiplier, net trade balance,
collected tariff, refund quota, and active state are tracked independently.
_Avoid_: Merchant ID, NFT

**Account Owner**:
The address that creates a Market Account, controls its capacity multiplier,
and receives that account's rights tokens. It does not automatically have
authority to spend tariff held for a different Merchant.
_Avoid_: Beneficiary, delegatee

**Merchant**:
The address that receives the account's trade settlement and is the only caller
that may use the account's refundable tariff when buying for its Account Owner.
One Merchant may participate in multiple Market Accounts with different Account
Owners and may reject unsupported owners during its trade callback.
_Avoid_: Account Owner, seller account

**Default Buyer Account**:
The lazily created Market Account where Account Owner and Merchant both equal
the external buyer. It starts inactive, with no deposit or capacity multiplier,
and records that buyer's deficit without restricting external capital. Its ID is
reused if the same pair is later activated as a Merchant.
_Avoid_: Unregistered merchant

**Payer**:
The `msg.sender` funding a trade. A Payer may fund either a Default Buyer Account
or an explicitly selected Market Account, but can use its refund quota only when
the Payer is also that account's Merchant and the declared buyer is its Account
Owner.
_Avoid_: Buyer

**Deposit Increase**:
A permissionless, fully funded increase to a Market Account's deposit. It never
revalues or reduces collected tariff; changes in theoretical tax are released
later through the normal trade refund path and remain subject to refund quota.
_Avoid_: Deposit credit

**Capacity Multiplier**:
A per-account capacity parameter expressed in basis points. It may only move
down while the Market Account exists, and cannot be below 10,000. Funds booked
to an active buyer account may only flow to a seller account with an equal or
lower multiplier; Default Buyer Accounts represent unrestricted external funds.
_Avoid_: Global capacity
