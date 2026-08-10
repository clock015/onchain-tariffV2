# Onchain Tariff Market

This context names the economic and governance identities used by the market so
their responsibilities remain distinct across settlement and voting code.

## Language

**Merchant**:
The address whose deposit, net trade balance, collected tariff, and active state
are tracked independently by the Market.
_Avoid_: Seller account, business owner

**Rights Owner**:
The address selected on first registration to receive seller rights. It is
immutable while that merchant exists; a kick deletes it with the merchant.
_Avoid_: Beneficiary, delegatee

**Payer**:
The address funding a trade; it may differ from the buyer but has no authority
over the merchant's rights owner.
_Avoid_: Buyer
