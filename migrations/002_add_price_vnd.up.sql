-- Expand: the new column, in dong, as an integer. Nullable on purpose:
-- v1 keeps inserting rows without it, and the backfill fills it later.
-- No CHECK here: positivity is validated in the API (priceVnd must be a positive integer).
ALTER TABLE menu_items ADD COLUMN price_vnd INTEGER;
