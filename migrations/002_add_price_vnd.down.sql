-- Undo the expand. Safe while only v1/v2 are serving: both still read and write `price`.
-- Loses whatever is in price_vnd (it can be rebuilt by the backfill).
ALTER TABLE menu_items DROP COLUMN price_vnd;
